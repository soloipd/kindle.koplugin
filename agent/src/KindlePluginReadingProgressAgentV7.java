import com.amazon.ebook.booklet.reader.sdk.ReaderContentSDK;
import com.amazon.ebook.booklet.reader.sdk.ReaderSDK;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.AnnotationSyncClientProxy;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.KSDKBookDataWrapper;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.SaveReadingProgressRequest;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.SaveReadingProgressResponse;
import com.amazon.ebook.booklet.reader.sdk.content.Book;
import com.amazon.ebook.booklet.reader.sdk.content.LastPageRead;
import com.amazon.ebook.booklet.reader.sdk.content.LprSidecarAdapter;
import com.amazon.ebook.booklet.reader.sdk.content.Position;
import com.amazon.ebook.booklet.reader.impl.todo.ContentCatalogLprUtils;
import com.amazon.kindle.content.catalog.CatalogService;
import com.amazon.kindle.content.catalog.MutableItem;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.Optional;
import java.util.Properties;
import java.util.concurrent.atomic.AtomicBoolean;

/** Persists one exact KOReader position and reports text-free stage timings. */
public final class KindlePluginReadingProgressAgentV7 {
    // ReaderSDK accepts and persists the request well within this window on
    // supported firmware. The previous 30-second value left KOReader's open
    // and close lifecycle visibly unresponsive even after local durability
    // had already been proven.
    private static final int DEFAULT_SYNC_TIMEOUT_MS = 3000;
    private static final int MIN_SYNC_TIMEOUT_MS = 500;
    private static final int MAX_SYNC_TIMEOUT_MS = 30000;
    private static final int DEFAULT_REQUEST_TIMEOUT_MS = 10000;
    private static final AtomicBoolean AGENT_RUNNING = new AtomicBoolean(false);

    private KindlePluginReadingProgressAgentV7() {}

    public static void agentmain(String payloadPath, Instrumentation ignored) {
        final long startedAt = System.nanoTime();
        if (!AGENT_RUNNING.compareAndSet(false, true)) {
            writeBusyResult(payloadPath, startedAt);
            return;
        }
        final RequestLease lease = new RequestLease(
            startedAt, DEFAULT_REQUEST_TIMEOUT_MS);
        final Thread worker = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    lease.bind(Thread.currentThread());
                    Thread watchdog = new Thread(new Runnable() {
                        @Override
                        public void run() {
                            lease.interruptAtDeadline();
                        }
                    }, "kindle-reading-progress-watchdog");
                    watchdog.setDaemon(true);
                    watchdog.start();
                    KindlePluginReadingProgressAgentV7.run(
                        payloadPath, startedAt, lease);
                } finally {
                    lease.complete();
                    releaseAgentGuard();
                }
            }
        }, "kindle-reading-progress-agent");
        worker.setDaemon(true);
        try {
            worker.start();
        } catch (RuntimeException error) {
            lease.complete();
            releaseAgentGuard();
            throw error;
        } catch (Error error) {
            lease.complete();
            releaseAgentGuard();
            throw error;
        }
    }

    private static void run(
        String payloadPath, long startedAt, RequestLease lease
    ) {
        PrintWriter out = null;
        Book book = null;
        String stage = "validate_payload";
        try {
            ensureActive(lease);
            if (payloadPath == null || !payloadPath.matches("^/tmp/kindle-progress-[0-9]+\\.properties$"))
                throw new IllegalArgumentException("invalid payload path");
            Properties payload = new Properties();
            File payloadFile = new File(payloadPath);
            try (FileInputStream input = new FileInputStream(payloadFile)) { payload.load(input); }
            ensureActive(lease);
            if (!payloadFile.delete()) throw new IllegalStateException("cannot remove consumed payload");
            if (!"1".equals(payload.getProperty("version"))) throw new IllegalArgumentException("unsupported payload");
            String requestId = requireDigits(payload, "request_id");
            if (!payloadPath.equals("/tmp/kindle-progress-" + requestId + ".properties"))
                throw new IllegalArgumentException("request ID mismatch");
            String asin = requireAsin(payload.getProperty("asin"));
            String nativePath = decodeHex(payload.getProperty("native_path_hex"));
            String operation = payload.getProperty("operation", "save");
            if (!"save".equals(operation) && !"read".equals(operation))
                throw new IllegalArgumentException("invalid operation");
            int syncTimeoutMs = optionalBoundedInt(
                payload, "sync_timeout_ms", DEFAULT_SYNC_TIMEOUT_MS,
                MIN_SYNC_TIMEOUT_MS, MAX_SYNC_TIMEOUT_MS);
            out = new PrintWriter(new FileWriter("/tmp/kindle-progress-result-" + requestId + ".log", false));
            out.println("request_id=" + requestId);
            out.println("asin=" + asin);
            out.println("sync_timeout_ms=" + syncTimeoutMs);
            out.println("request_timeout_ms=" + DEFAULT_REQUEST_TIMEOUT_MS);
            mark(out, "validate_payload", startedAt);

            stage = "resolve_reader_sdk";
            ensureActive(lease);
            Class<?> framework = Class.forName("com.amazon.kindle.restricted.runtime.Framework");
            ReaderSDK sdk = (ReaderSDK) framework.getMethod("getService", Class.class)
                .invoke(null, ReaderSDK.class);
            ensureActive(lease);
            ReaderContentSDK content = sdk.jE();
            ensureActive(lease);
            mark(out, stage, startedAt);

            stage = "open_book";
            ensureActive(lease);
            book = content.dt(nativePath);
            ensureActive(lease);
            mark(out, stage, startedAt);
            if ("read".equals(operation)) {
                writeCurrentPosition(out, book, lease);
                ensureActive(lease);
                mark(out, "read_current_position", startedAt);
                return;
            }

            String longPosition = requireLongPosition(payload.getProperty("long_position"));
            int expectedShort = Integer.parseInt(requireDigits(payload, "short_position"));
            stage = "translate_position";
            ensureActive(lease);
            Position position = content.E(book).a(longPosition, book);
            ensureActive(lease);
            int actualShort = position.nR();
            if (actualShort != expectedShort) throw new IllegalStateException("short position mismatch");
            mark(out, stage, startedAt);

            stage = "save_local_lpr";
            LprSidecarAdapter adapter = new LprSidecarAdapter(book, content);
            ensureActive(lease);
            LastPageRead lpr = adapter.cA(false);
            ensureActive(lease);
            if (lpr == null) lpr = new LastPageRead(content);
            lpr.a(position, new Date());
            ensureActive(lease);
            if (!adapter.a(lpr)) throw new IllegalStateException("local LPR was not staged");
            ensureActive(lease);
            book.Ue();
            ensureActive(lease);
            mark(out, stage, startedAt);

            ensureActive(lease);
            book.close();
            book = null;
            ensureActive(lease);
            stage = "verify_local_lpr";
            book = content.dt(nativePath);
            ensureActive(lease);
            LastPageRead persisted = book.Ud();
            ensureActive(lease);
            Position persistedPosition = persisted == null ? null : persisted.nz();
            if (persistedPosition == null
                    || persistedPosition.nR() != actualShort
                    || !position.nX().equals(persistedPosition.nX()))
                throw new IllegalStateException("local LPR durability check failed");
            out.println("local_progress_saved=true");
            out.println("local_progress_verified=true");
            mark(out, stage, startedAt);

            stage = "save_native_progress";
            ensureActive(lease);
            Optional<KSDKBookDataWrapper> wrapped = KSDKBookDataWrapper.a(book.jg());
            ensureActive(lease);
            if (!wrapped.isPresent()) throw new IllegalStateException("book data unavailable");
            AnnotationSyncClientProxy proxy = sdk.yl();
            SaveReadingProgressRequest request = new SaveReadingProgressRequest(
                wrapped.get(), actualShort, position.nX(), (long) syncTimeoutMs);
            Optional<SaveReadingProgressResponse> response = proxy.a(request);
            ensureActive(lease);
            boolean accepted = response.isPresent() && response.get().cuY;
            mark(out, stage, startedAt);

            double renderedPercent = nativePercent(persistedPosition);
            boolean catalogSaved = false;
            if (accepted) {
                stage = "refresh_reader_progress";
                ensureActive(lease);
                sdk.xQ();
                ensureActive(lease);
                mark(out, stage, startedAt);
                stage = "save_catalog_progress";
                ensureActive(lease);
                CatalogService catalog = (CatalogService) sdk.getService(CatalogService.class);
                ensureActive(lease);
                MutableItem item = ContentCatalogLprUtils.a(catalog, nativePath);
                ensureActive(lease);
                if (item == null) throw new IllegalStateException("native catalog item unavailable");
                item.setProperty("percentFinished", Float.valueOf((float) renderedPercent));
                ensureActive(lease);
                catalogSaved = ContentCatalogLprUtils.a(sdk, catalog, item);
                ensureActive(lease);
                mark(out, stage, startedAt);
            }
            ensureActive(lease);
            out.println("saved_short=" + actualShort);
            out.println("long_position=" + position.nX());
            out.println("native_percent=" + renderedPercent);
            out.println("native_progress_accepted=" + accepted);
            out.println("catalog_progress_saved=" + catalogSaved);
            out.println("success=" + (accepted && catalogSaved));
        } catch (Throwable error) {
            if (out != null) {
                out.println("failed_stage=" + stage);
                out.println("error_class=" + (
                    lease.isExpired()
                        ? "request expired"
                        : root(error).getClass().getName()));
                mark(out, "failure", startedAt);
                out.println("success=false");
            }
        } finally {
            if (book != null) try { book.close(); } catch (Throwable ignoredClose) {}
            if (out != null) out.close();
        }
    }

    private static void writeBusyResult(String payloadPath, long startedAt) {
        PrintWriter out = null;
        try {
            if (payloadPath == null || !payloadPath.matches("^/tmp/kindle-progress-[0-9]+\\.properties$"))
                throw new IllegalArgumentException("invalid payload path");
            Properties payload = new Properties();
            File payloadFile = new File(payloadPath);
            try (FileInputStream input = new FileInputStream(payloadFile)) { payload.load(input); }
            if (!payloadFile.delete()) throw new IllegalStateException("cannot remove consumed payload");
            if (!"1".equals(payload.getProperty("version")))
                throw new IllegalArgumentException("unsupported payload");
            String requestId = requireDigits(payload, "request_id");
            if (!payloadPath.equals("/tmp/kindle-progress-" + requestId + ".properties"))
                throw new IllegalArgumentException("request ID mismatch");
            String asin = requireAsin(payload.getProperty("asin"));
            out = new PrintWriter(new FileWriter(
                "/tmp/kindle-progress-result-" + requestId + ".log", false));
            out.println("request_id=" + requestId);
            out.println("asin=" + asin);
            out.println("failed_stage=single_flight");
            out.println("error_class=agent already running");
            mark(out, "single_flight", startedAt);
            out.println("success=false");
        } catch (Throwable error) {
            if (out != null) {
                out.println("failed_stage=single_flight");
                out.println("error_class=" + root(error).getClass().getName());
                mark(out, "failure", startedAt);
                out.println("success=false");
            }
        } finally {
            if (out != null) out.close();
        }
    }

    private static void releaseAgentGuard() {
        AGENT_RUNNING.set(false);
    }

    private static void ensureActive(RequestLease lease) {
        lease.ensureActive();
    }

    private static void writeCurrentPosition(
        PrintWriter out, Book book, RequestLease lease
    ) {
        ensureActive(lease);
        LastPageRead current = book.Ud();
        ensureActive(lease);
        Position currentPosition = current == null ? null : current.nz();
        if (currentPosition == null) throw new IllegalStateException("native position unavailable");
        out.println("saved_short=" + currentPosition.nR());
        out.println("long_position=" + currentPosition.nX());
        out.println("native_percent=" + nativePercent(currentPosition));
        ensureActive(lease);
        out.println("success=true");
    }

    private static final class RequestLease {
        private final long deadlineNanos;
        private final AtomicBoolean completed = new AtomicBoolean(false);
        private final AtomicBoolean expired = new AtomicBoolean(false);
        private volatile Thread worker;

        RequestLease(long startedAt, int timeoutMs) {
            deadlineNanos = startedAt + timeoutMs * 1000000L;
        }

        void bind(Thread value) {
            worker = value;
        }

        void complete() {
            completed.set(true);
        }

        boolean isExpired() {
            return expired.get();
        }

        void ensureActive() {
            if (expired.get() || System.nanoTime() >= deadlineNanos) {
                expired.set(true);
                throw new RequestExpiredException();
            }
        }

        void interruptAtDeadline() {
            while (!completed.get()) {
                long remainingNanos = deadlineNanos - System.nanoTime();
                if (remainingNanos <= 0L) break;
                long sleepMs = Math.max(
                    1L, Math.min(1000L, remainingNanos / 1000000L));
                try {
                    Thread.sleep(sleepMs);
                } catch (InterruptedException ignored) {
                    return;
                }
            }
            if (completed.get()) return;
            expired.set(true);
            if (worker != null) worker.interrupt();
        }
    }

    private static final class RequestExpiredException
        extends RuntimeException
    {
        RequestExpiredException() {
            super("request expired");
        }
    }

    private static void mark(PrintWriter out, String name, long startedAt) {
        long elapsedMs = (System.nanoTime() - startedAt) / 1000000L;
        out.println("elapsed_" + name + "_ms=" + elapsedMs);
        out.flush();
    }

    private static double nativePercent(Position position) {
        double percent = position.UG() * 100.0;
        if (!Double.isFinite(percent))
            throw new IllegalStateException("native rendered percentage unavailable");
        return Math.max(0.0, Math.min(100.0, percent));
    }

    private static int optionalBoundedInt(
        Properties values, String key, int defaultValue, int minimum, int maximum
    ) {
        String raw = values.getProperty(key);
        if (raw == null || raw.isEmpty()) return defaultValue;
        if (!raw.matches("^[0-9]+$")) throw new IllegalArgumentException("invalid " + key);
        int value = Integer.parseInt(raw);
        if (value < minimum || value > maximum)
            throw new IllegalArgumentException("out-of-range " + key);
        return value;
    }

    private static String requireDigits(Properties values, String key) {
        String value = values.getProperty(key, "");
        if (!value.matches("^[0-9]+$")) throw new IllegalArgumentException("invalid " + key);
        return value;
    }

    private static String requireAsin(String value) {
        if (value == null || !value.matches("^B[A-Z0-9]{9}$"))
            throw new IllegalArgumentException("invalid ASIN");
        return value;
    }

    private static String requireLongPosition(String value) {
        if (value == null || !value.matches("^[A-Za-z0-9+/]{12}$"))
            throw new IllegalArgumentException("invalid long position");
        return value;
    }

    private static String decodeHex(String value) {
        if (value == null || (value.length() & 1) != 0 || !value.matches("^[0-9A-Fa-f]+$"))
            throw new IllegalArgumentException("invalid native path");
        byte[] bytes = new byte[value.length() / 2];
        for (int i = 0; i < bytes.length; i++)
            bytes[i] = (byte) Integer.parseInt(value.substring(i * 2, i * 2 + 2), 16);
        String result = new String(bytes, StandardCharsets.UTF_8);
        if (!result.startsWith("/mnt/us/documents/") || !result.endsWith(".kfx"))
            throw new IllegalArgumentException("unsafe native path");
        return result;
    }

    private static Throwable root(Throwable error) {
        Throwable current = error;
        while (current.getCause() != null) current = current.getCause();
        return current;
    }
}
