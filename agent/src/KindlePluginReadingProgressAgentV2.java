import com.amazon.ebook.booklet.reader.sdk.ReaderContentSDK;
import com.amazon.ebook.booklet.reader.sdk.ReaderSDK;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.AnnotationSyncClientProxy;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.KSDKBookDataWrapper;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.SaveReadingProgressRequest;
import com.amazon.ebook.booklet.reader.sdk.annotation.sync.SaveReadingProgressResponse;
import com.amazon.ebook.booklet.reader.sdk.content.Book;
import com.amazon.ebook.booklet.reader.sdk.content.LastPageRead;
import com.amazon.ebook.booklet.reader.sdk.content.Position;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.Optional;
import java.util.Properties;

/** Persists an exact KOReader location using Kindle's authoritative reader API. */
public final class KindlePluginReadingProgressAgentV2 {
    private KindlePluginReadingProgressAgentV2() {}

    public static void agentmain(String payloadPath, Instrumentation ignored) {
        PrintWriter out = null;
        Book book = null;
        String stage = "validate_payload";
        try {
            if (payloadPath == null || !payloadPath.matches("^/tmp/kindle-progress-[0-9]+\\.properties$"))
                throw new IllegalArgumentException("invalid payload path");
            Properties payload = new Properties();
            File payloadFile = new File(payloadPath);
            try (FileInputStream input = new FileInputStream(payloadFile)) { payload.load(input); }
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
            out = new PrintWriter(new FileWriter("/tmp/kindle-progress-result-" + requestId + ".log", false));
            out.println("request_id=" + requestId);
            out.println("asin=" + asin);

            stage = "resolve_reader_sdk";
            Class<?> framework = Class.forName("com.amazon.kindle.restricted.runtime.Framework");
            ReaderSDK sdk = (ReaderSDK) framework.getMethod("getService", Class.class)
                .invoke(null, ReaderSDK.class);
            ReaderContentSDK content = sdk.jE();

            stage = "open_book";
            book = content.dt(nativePath);
            if ("read".equals(operation)) {
                stage = "read_local_lpr";
                LastPageRead current = book.Ud();
                Position currentPosition = current == null ? null : current.nz();
                if (currentPosition == null) throw new IllegalStateException("native position unavailable");
                out.println("saved_short=" + currentPosition.nR());
                out.println("long_position=" + currentPosition.nX());
                out.println("success=true");
                return;
            }

            String longPosition = requireLongPosition(payload.getProperty("long_position"));
            int expectedShort = Integer.parseInt(requireDigits(payload, "short_position"));
            stage = "translate_position";
            Position position = content.E(book).a(longPosition, book);
            int actualShort = position.nR();
            if (actualShort != expectedShort) throw new IllegalStateException("short position mismatch");

            stage = "save_local_lpr";
            LastPageRead lpr = book.Ud();
            if (lpr == null) lpr = new LastPageRead(content);
            lpr.a(position, new Date());
            book.Ue();
            out.println("local_progress_saved=true");
            out.flush();

            stage = "save_native_progress";
            Optional<KSDKBookDataWrapper> wrapped = KSDKBookDataWrapper.a(book.jg());
            if (!wrapped.isPresent()) throw new IllegalStateException("book data unavailable");
            AnnotationSyncClientProxy proxy = sdk.yl();
            SaveReadingProgressRequest request = new SaveReadingProgressRequest(
                wrapped.get(), actualShort, position.nX(), 30000L);
            Optional<SaveReadingProgressResponse> response = proxy.a(request);
            boolean accepted = response.isPresent() && response.get().cuY;
            out.println("saved_short=" + actualShort);
            out.println("native_progress_accepted=" + accepted);
            out.println("success=" + accepted);
        } catch (Throwable error) {
            if (out != null) {
                out.println("failed_stage=" + stage);
                out.println("error_class=" + root(error).getClass().getName());
                out.println("success=false");
            }
        } finally {
            if (book != null) try { book.close(); } catch (Throwable ignoredClose) {}
            if (out != null) out.close();
        }
    }

    private static String requireDigits(Properties values, String key) {
        String value = values.getProperty(key, "");
        if (!value.matches("^[0-9]+$")) throw new IllegalArgumentException("invalid " + key);
        return value;
    }
    private static String requireAsin(String value) {
        if (value == null || !value.matches("^B[A-Z0-9]{9}$")) throw new IllegalArgumentException("invalid ASIN");
        return value;
    }
    private static String requireLongPosition(String value) {
        if (value == null || !value.matches("^[A-Za-z0-9+/]{12}$")) throw new IllegalArgumentException("invalid long position");
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
