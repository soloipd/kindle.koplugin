"""Durable close-time KOReader -> Kindle reading-position delivery.

The foreground plugin only enqueues a root-private, checksummed snapshot.  A
detached worker translates the XPointer, reconciles it against the last exact
receipt, and invokes Kindle's ReaderSDK bridge after KOReader may have exited.
Successful receipts intentionally contain coordinates and percentages only.
"""

import contextlib
import errno
import fcntl
import hashlib
import os
import re
import stat
import subprocess
import time

from epub_position import translate_pair


DEFAULT_STATE_DIR = "/var/local/kindle-koplugin"
DEFAULT_DEBUG_PATH = "/mnt/us/koreader/settings/kindle_native_progress_queue_debug.log"
ASIN_RE = re.compile(r"^B[A-Z0-9]{9}$")
LONG_RE = re.compile(r"^A[A-Za-z0-9+/]{11}$")
DIGITS_RE = re.compile(r"^[0-9]{1,18}$")
MAX_STATE_FILE = 256 * 1024


class ProgressOutboxError(RuntimeError):
    """A permanent malformed-request or local-state failure."""


class ProgressOutboxTransient(ProgressOutboxError):
    """A delivery failure for which the durable request should be retained."""


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _hex(value):
    if not isinstance(value, str):
        raise ProgressOutboxError("invalid text field")
    return value.encode("utf-8").hex()


def _unhex(value, field, maximum=65536):
    if not isinstance(value, str) or len(value) > maximum * 2 \
            or len(value) % 2 or not re.fullmatch(r"[0-9a-f]*", value):
        raise ProgressOutboxError("invalid encoded " + field)
    try:
        decoded = bytes.fromhex(value).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ProgressOutboxError("invalid encoded " + field) from error
    if "\x00" in decoded or "\n" in decoded or "\r" in decoded:
        raise ProgressOutboxError("invalid encoded " + field)
    return decoded


def _ensure_directory(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ProgressOutboxError("invalid private state directory")
    os.chmod(path, 0o700)


def _require_existing_directory(path):
    try:
        info = os.lstat(path)
    except OSError as error:
        raise ProgressOutboxError("state parent directory is unavailable") from error
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ProgressOutboxError("invalid state parent directory")


def _fsync_directory(path):
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        try:
            os.fsync(descriptor)
        except OSError as error:
            # Some Kindle/FUSE directory handles do not implement fsync. The
            # private /var/local queue does, while the optional published
            # diagnostic must remain best-effort on every supported firmware.
            if error.errno not in (errno.EINVAL, errno.ENOTSUP, errno.EOPNOTSUPP):
                raise
    finally:
        os.close(descriptor)


def _read_regular(path, maximum=MAX_STATE_FILE):
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ProgressOutboxError("cannot read private state") from error
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ProgressOutboxError("invalid private state file")
        chunks = []
        remaining = maximum + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > maximum:
            raise ProgressOutboxError("private state file is too large")
        return data
    finally:
        os.close(descriptor)


def _parse_checksummed(data, allowed):
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise ProgressOutboxError("private state is not ASCII") from error
    match = re.fullmatch(r"(?s)(.*\n)checksum=([0-9a-f]{64})\n?", text)
    if not match:
        raise ProgressOutboxError("private state checksum is missing")
    body = match.group(1).encode("ascii")
    if _sha256(body) != match.group(2):
        raise ProgressOutboxError("private state checksum mismatch")
    fields = {}
    for line in match.group(1).splitlines():
        if "=" not in line:
            raise ProgressOutboxError("invalid private state field")
        key, value = line.split("=", 1)
        if key not in allowed or key in fields:
            raise ProgressOutboxError("unexpected private state field")
        fields[key] = value
    if set(fields) != set(allowed):
        raise ProgressOutboxError("incomplete private state")
    return fields, match.group(2)


def _serialize(fields):
    body = "".join("{}={}\n".format(key, value) for key, value in fields)
    encoded = body.encode("ascii")
    return encoded + ("checksum={}\n".format(_sha256(encoded))).encode("ascii")


def _atomic_write(path, data, private_parent=True):
    directory = os.path.dirname(path)
    if private_parent:
        _ensure_directory(directory)
    else:
        # Never chmod or create KOReader's shared settings directory merely to
        # publish a text-free diagnostic file.
        _require_existing_directory(directory)
    temporary = os.path.join(
        directory, ".{}.{}.{}.tmp".format(
            os.path.basename(path), os.getpid(), time.time_ns()))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(temporary, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            offset = 0
            while offset < len(data):
                offset += os.write(descriptor, data[offset:])
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        os.replace(temporary, path)
        _fsync_directory(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


@contextlib.contextmanager
def _book_lock(state_dir, asin):
    lock_dir = os.path.join(state_dir, "locks")
    _ensure_directory(lock_dir)
    path = os.path.join(lock_dir, asin + ".lock")
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ProgressOutboxError("invalid progress lock")
        os.fchmod(descriptor, 0o600)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


REQUEST_KEYS_V1 = (
    "queue_version", "asin", "sequence", "native_path_hex",
    "epub_path_hex", "xpointer_hex", "koreader_percent", "status_hex",
    "closed_at", "previous_long", "previous_short",
)
REQUEST_KEYS_V2 = REQUEST_KEYS_V1 + (
    "open_native_long", "open_native_short",
    "open_local_long", "open_local_short",
)


def _validate_asin(value):
    if not isinstance(value, str) or not ASIN_RE.fullmatch(value):
        raise ProgressOutboxError("invalid ASIN")
    return value


def _validate_long(value, optional=False):
    if optional and value == "":
        return ""
    if not isinstance(value, str) or not LONG_RE.fullmatch(value):
        raise ProgressOutboxError("invalid native coordinate")
    return value


def _validate_short(value, optional=False):
    if optional and value == "":
        return ""
    try:
        number = int(value)
    except (TypeError, ValueError) as error:
        raise ProgressOutboxError("invalid native offset") from error
    if number < 0 or number > 2147483647 or str(number) != str(value):
        raise ProgressOutboxError("invalid native offset")
    return number


def _bounded_percent(value):
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise ProgressOutboxError("invalid progress percentage") from error
    if not 0 <= number <= 100 or number != number:
        raise ProgressOutboxError("invalid progress percentage")
    return number


def _validate_request(fields):
    if fields["queue_version"] not in ("1", "2"):
        raise ProgressOutboxError("unsupported progress request")
    if fields["queue_version"] == "2" and any(
        key not in fields for key in REQUEST_KEYS_V2[len(REQUEST_KEYS_V1):]
    ):
        raise ProgressOutboxError("incomplete version-2 progress request")
    asin = _validate_asin(fields["asin"])
    sequence = fields["sequence"]
    if not DIGITS_RE.fullmatch(sequence):
        raise ProgressOutboxError("invalid progress sequence")
    native_path = _unhex(fields["native_path_hex"], "native path", 4096)
    epub_path = _unhex(fields["epub_path_hex"], "EPUB path", 4096)
    xpointer = _unhex(fields["xpointer_hex"], "XPointer")
    status = _unhex(fields["status_hex"], "status", 64)
    if not native_path.startswith("/mnt/us/documents/") \
            or not native_path.endswith(".kfx") \
            or os.path.normpath(native_path) != native_path:
        raise ProgressOutboxError("invalid native book path")
    if not epub_path.startswith("/mnt/us/") or not epub_path.endswith(".epub") \
            or os.path.normpath(epub_path) != epub_path:
        raise ProgressOutboxError("invalid converted EPUB path")
    if not xpointer.startswith("/") or len(xpointer) > 65536:
        raise ProgressOutboxError("invalid XPointer")
    if not re.fullmatch(r"[a-z-]{0,32}", status):
        raise ProgressOutboxError("invalid reading status")
    percent = _bounded_percent(fields["koreader_percent"])
    if not DIGITS_RE.fullmatch(fields["closed_at"]):
        raise ProgressOutboxError("invalid close timestamp")
    closed_at = int(fields["closed_at"])
    previous_long = _validate_long(fields["previous_long"], optional=True)
    previous_short = _validate_short(fields["previous_short"], optional=True)
    if bool(previous_long) != (previous_short != ""):
        raise ProgressOutboxError("incomplete previous receipt")
    open_native_long = _validate_long(
        fields.get("open_native_long", ""), optional=True)
    open_native_short = _validate_short(
        fields.get("open_native_short", ""), optional=True)
    open_local_long = _validate_long(
        fields.get("open_local_long", ""), optional=True)
    open_local_short = _validate_short(
        fields.get("open_local_short", ""), optional=True)
    if bool(open_native_long) != (open_native_short != "") \
            or bool(open_local_long) != (open_local_short != "") \
            or bool(open_native_long) != bool(open_local_long):
        raise ProgressOutboxError("incomplete open-session baseline")
    session_baseline = None
    if open_native_long:
        session_baseline = {
            "native": {
                "long": open_native_long,
                "pid": open_native_short,
            },
            "local": {
                "long": open_local_long,
                "pid": open_local_short,
            },
        }
    return {
        "asin": asin,
        "sequence": sequence,
        "native_path": native_path,
        "epub_path": epub_path,
        "xpointer": xpointer,
        "koreader_percent": percent,
        "status": status or "reading",
        "closed_at": closed_at,
        "previous_long": previous_long,
        "previous_short": previous_short,
        "session_baseline": session_baseline,
    }


def parse_request(path):
    data = _read_regular(path)
    try:
        fields, checksum = _parse_checksummed(data, REQUEST_KEYS_V2)
    except ProgressOutboxError:
        # Upgrade compatibility: a v0.0.9 worker may inherit a version-1
        # snapshot that was committed immediately before the plugin update.
        fields, checksum = _parse_checksummed(data, REQUEST_KEYS_V1)
    request = _validate_request(fields)
    request["checksum"] = checksum
    return request


def start_watcher(plugin_dir, state_dir=DEFAULT_STATE_DIR):
    plugin_dir = os.path.abspath(plugin_dir)
    watcher = os.path.join(plugin_dir, "bin", "watch-close-progress")
    if not os.path.isfile(watcher):
        raise ProgressOutboxError("progress watcher is unavailable")
    environment = {}
    for name in (
        "PATH", "LD_LIBRARY_PATH", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE",
        "KINDLE_HELPER_BASE",
    ):
        if name in os.environ:
            environment[name] = os.environ[name]
    environment["KINDLE_PLUGIN_DIR"] = plugin_dir
    environment["KINDLE_PROGRESS_STATE_DIR"] = os.path.abspath(state_dir)
    with open(os.devnull, "rb") as null_in, open(os.devnull, "ab") as null_out:
        subprocess.Popen(
            ["/bin/sh", watcher], stdin=null_in, stdout=null_out, stderr=null_out,
            close_fds=True, start_new_session=True, env=environment)
    return True


def enqueue(request, state_dir=DEFAULT_STATE_DIR, plugin_dir=None,
            launch=True):
    asin = _validate_asin(request.get("asin"))
    sequence = str(request.get("sequence", ""))
    if not DIGITS_RE.fullmatch(sequence):
        raise ProgressOutboxError("invalid progress sequence")
    previous = request.get("previous") or {}
    session = request.get("session_baseline") or {}
    open_native = session.get("native") or {}
    open_local = session.get("local") or {}
    fields = (
        ("queue_version", "2"),
        ("asin", asin),
        ("sequence", sequence),
        ("native_path_hex", _hex(request.get("native_path", ""))),
        ("epub_path_hex", _hex(request.get("epub_path", ""))),
        ("xpointer_hex", _hex(request.get("xpointer", ""))),
        ("koreader_percent", "{:.8f}".format(
            _bounded_percent(request.get("koreader_percent")))),
        ("status_hex", _hex(request.get("status") or "reading")),
        ("closed_at", str(request.get("closed_at", ""))),
        ("previous_long", str(previous.get("long") or "")),
        ("previous_short", "" if previous.get("pid") is None
         else str(previous.get("pid"))),
        ("open_native_long", str(open_native.get("long") or "")),
        ("open_native_short", "" if open_native.get("pid") is None
         else str(open_native.get("pid"))),
        ("open_local_long", str(open_local.get("long") or "")),
        ("open_local_short", "" if open_local.get("pid") is None
         else str(open_local.get("pid"))),
    )
    encoded = _serialize(fields)
    # Parse our own serialized representation before it becomes durable.  This
    # keeps every validation rule identical for producer and consumer.
    parsed_fields, _ = _parse_checksummed(encoded, REQUEST_KEYS_V2)
    _validate_request(parsed_fields)
    state_dir = os.path.abspath(state_dir)
    outbox = os.path.join(state_dir, "progress-outbox")
    _ensure_directory(state_dir)
    _ensure_directory(outbox)
    destination = os.path.join(outbox, asin)
    with _book_lock(state_dir, asin):
        _atomic_write(destination, encoded)
    watcher_started = False
    if launch:
        if not plugin_dir:
            raise ProgressOutboxError("progress watcher path is unavailable")
        try:
            start_watcher(plugin_dir, state_dir)
            watcher_started = True
        except (OSError, ProgressOutboxError):
            # The durable snapshot is already committed. Do not report an
            # enqueue failure that would make ReaderUI perform a second save;
            # plugin initialization will replay this retained request.
            watcher_started = False
    return {
        "ok": True,
        "queued": True,
        "sequence": sequence,
        "watcher_started": watcher_started,
    }


def _read_properties(path):
    values = {}
    data = _read_regular(path, 64 * 1024)
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError as error:
        raise ProgressOutboxTransient("invalid native result") from error
    for line in text.splitlines():
        if "=" not in line:
            raise ProgressOutboxTransient("invalid native result")
        key, value = line.split("=", 1)
        if key in values:
            raise ProgressOutboxTransient("invalid native result")
        values[key] = value
    return values


def _agent_request_id():
    return "{}{:05d}".format(time.time_ns(), os.getpid() % 100000)


def _run_agent(plugin_dir, request, operation, position=None):
    request_id = _agent_request_id()
    payload_path = "/tmp/kindle-progress-{}.properties".format(request_id)
    result_path = "/tmp/kindle-progress-worker-{}.log".format(request_id)
    payload = [
        ("version", "1"),
        ("request_id", request_id),
        ("asin", request["asin"]),
        ("operation", operation),
        ("native_path_hex", _hex(request["native_path"])),
        ("sync_timeout_ms", "3000"),
    ]
    if operation == "save":
        payload.extend((
            ("long_position", position["long"]),
            ("short_position", str(position["pid"])),
        ))
    descriptor = os.open(
        payload_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        content = "".join("{}={}\n".format(key, value) for key, value in payload)
        encoded = content.encode("ascii")
        offset = 0
        while offset < len(encoded):
            offset += os.write(descriptor, encoded[offset:])
    finally:
        os.close(descriptor)
    runner = os.path.join(plugin_dir, "bin", "sync-native-progress")
    if not os.path.isfile(runner):
        try:
            os.unlink(payload_path)
        except FileNotFoundError:
            pass
        raise ProgressOutboxTransient("native progress bridge is unavailable")
    try:
        completed = subprocess.run(
            ["/bin/sh", runner, payload_path, result_path],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=30, check=False)
        if completed.returncode != 0:
            raise ProgressOutboxTransient("native progress bridge failed")
        result = _read_properties(result_path)
    except subprocess.TimeoutExpired as error:
        raise ProgressOutboxTransient("native progress bridge timed out") from error
    finally:
        for path in (payload_path, result_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
    if result.get("request_id") != request_id \
            or result.get("asin") != request["asin"] \
            or result.get("success") != "true":
        raise ProgressOutboxTransient("native progress verification failed")
    long_position = _validate_long(result.get("long_position"))
    short_position = _validate_short(result.get("saved_short"))
    native_percent = _bounded_percent(result.get("native_percent"))
    if operation == "save":
        if result.get("catalog_progress_saved") != "true" \
                or long_position != position["long"] \
                or short_position != position["pid"]:
            raise ProgressOutboxTransient("native progress save was not durable")
    return {
        "long": long_position,
        "pid": short_position,
        "percent": native_percent,
    }


def _same_position(left, right):
    return left and right and left.get("long") == right.get("long") \
        and left.get("pid") == right.get("pid")


def _request_is_current(request_path, request, state_dir):
    """Revalidate immediately before a native operation.

    Translation can take long enough for a rapid reopen/close to supersede the
    snapshot. Avoid starting a stale ReaderSDK write when that newer request is
    already durable. A request that arrives during an in-flight native save is
    retained and replayed by the same watcher sweep.
    """
    with _book_lock(state_dir, request["asin"]):
        try:
            current = parse_request(request_path)
        except ProgressOutboxError:
            return False
        return current["sequence"] == request["sequence"] \
            and current["checksum"] == request["checksum"]


def _receipt_data(request, position, action):
    return _serialize((
        ("receipt_version", "1"),
        ("asin", request["asin"]),
        ("source_sequence", request["sequence"]),
        ("source_checksum", request["checksum"]),
        ("long_position", position["long"]),
        ("short_position", str(position["pid"])),
        ("native_percent", "{:.8f}".format(position["percent"])),
        ("koreader_percent", "{:.8f}".format(request["koreader_percent"])),
        ("status_hex", _hex(request["status"])),
        ("synced_at", str(request["closed_at"])),
        ("action", action),
    ))


def _debug_data(request, action, local_position, native_position=None):
    native_position = native_position or {}
    return _serialize((
        ("debug_version", "1"),
        ("asin", request["asin"]),
        ("source_sequence", request["sequence"]),
        ("action", action),
        ("local_long", local_position.get("long", "")),
        ("local_short", str(local_position.get("pid", ""))),
        ("native_long", native_position.get("long", "")),
        ("native_short", str(native_position.get("pid", ""))),
        ("native_percent", str(native_position.get("percent", ""))),
        ("koreader_percent", "{:.8f}".format(request["koreader_percent"])),
        ("success", "true"),
    ))


def _finalize(request_path, request, state_dir, action, local_position,
              native_position=None, receipt=None, debug_path=DEFAULT_DEBUG_PATH):
    asin = request["asin"]
    with _book_lock(state_dir, asin):
        try:
            current = parse_request(request_path)
        except ProgressOutboxError:
            return False
        if current["sequence"] != request["sequence"] \
                or current["checksum"] != request["checksum"]:
            if receipt is not None:
                # The native save really completed, even though a newer close
                # arrived while it was in flight. Preserve that exact
                # intermediate baseline without acknowledging or deleting the
                # newer request; the next sweep can then advance safely.
                receipt_dir = os.path.join(state_dir, "progress-receipts")
                _atomic_write(os.path.join(receipt_dir, asin), receipt)
            return False
        if receipt is not None:
            receipt_dir = os.path.join(state_dir, "progress-receipts")
            _atomic_write(os.path.join(receipt_dir, asin), receipt)
        debug = _debug_data(request, action, local_position, native_position)
        debug_dir = os.path.join(state_dir, "progress-debug")
        _atomic_write(os.path.join(debug_dir, asin), debug)
        if debug_path:
            try:
                _atomic_write(debug_path, debug, private_parent=False)
            except (OSError, ProgressOutboxError):
                pass
        os.unlink(request_path)
        _fsync_directory(os.path.dirname(request_path))
        return True


def _durable_receipt_position(state_dir, asin):
    path = os.path.join(state_dir, "progress-receipts", asin)
    try:
        receipt = _parse_receipt(path, asin)
    except (OSError, ProgressOutboxError):
        return None
    return {
        "long": receipt["long"],
        "pid": receipt["pid"],
        "percent": receipt["native_percent"],
    }


def process_request(request_path, state_dir=DEFAULT_STATE_DIR,
                    plugin_dir="/mnt/us/koreader/plugins/kindle.koplugin",
                    debug_path=DEFAULT_DEBUG_PATH):
    state_dir = os.path.abspath(state_dir)
    request_path = os.path.abspath(request_path)
    request = parse_request(request_path)
    expected = os.path.join(state_dir, "progress-outbox", request["asin"])
    if request_path != expected:
        raise ProgressOutboxError("progress request is outside the outbox")
    translated = translate_pair(
        request["epub_path"], request["xpointer"], request["xpointer"])
    local_position = translated.get("start") if isinstance(translated, dict) else None
    if not isinstance(local_position, dict):
        raise ProgressOutboxError("position translation failed")
    local_position = {
        "long": _validate_long(local_position.get("long")),
        "pid": _validate_short(local_position.get("pid")),
    }
    previous = None
    if request["previous_long"]:
        previous = {
            "long": request["previous_long"],
            "pid": request["previous_short"],
        }
    durable_previous = _durable_receipt_position(
        state_dir, request["asin"])
    session_baseline = request.get("session_baseline")

    native = None
    if previous or durable_previous or session_baseline:
        if not _request_is_current(request_path, request, state_dir):
            return {"ok": True, "action": "superseded", "superseded": True}
        native = _run_agent(plugin_dir, request, "read")
        if _same_position(local_position, native):
            action = "already_current"
            receipt = _receipt_data(request, native, action)
            finalized = _finalize(
                request_path, request, state_dir, action, local_position,
                native, receipt, debug_path)
            return {"ok": True, "action": action,
                    "superseded": not finalized}
        if session_baseline:
            # This exact three-way merge is scoped to one KOReader open/close
            # session. It is stronger than a potentially old global receipt:
            # only the side that moved during this session may win silently.
            local_changed = not _same_position(
                local_position, session_baseline["local"])
            native_changed = not _same_position(
                native, session_baseline["native"])
            if not local_changed:
                action = "native_won" if native_changed \
                    else "no_session_change"
                finalized = _finalize(
                    request_path, request, state_dir, action, local_position,
                    native, None, debug_path)
                return {"ok": True, "action": action,
                        "superseded": not finalized}
            if native_changed:
                action = "conflict"
                finalized = _finalize(
                    request_path, request, state_dir, action, local_position,
                    native, None, debug_path)
                return {"ok": True, "action": action,
                        "superseded": not finalized}
            # KOReader alone moved. Fall through to the verified native save.
            baseline = session_baseline["native"]
        else:
            baseline = durable_previous \
                if _same_position(native, durable_previous) else previous
        if baseline is None:
            # A verified prior native receipt exists but Kindle has since
            # moved. With no local predecessor to compare, preserve Kindle.
            action = "native_won"
            finalized = _finalize(
                request_path, request, state_dir, action, local_position,
                native, None, debug_path)
            return {"ok": True, "action": action,
                    "superseded": not finalized}
        local_changed = not _same_position(local_position, baseline)
        native_changed = not _same_position(native, baseline)
        if not local_changed and native_changed:
            action = "native_won"
            finalized = _finalize(
                request_path, request, state_dir, action, local_position,
                native, None, debug_path)
            return {"ok": True, "action": action,
                    "superseded": not finalized}
        if local_changed and native_changed:
            action = "conflict"
            finalized = _finalize(
                request_path, request, state_dir, action, local_position,
                native, None, debug_path)
            return {"ok": True, "action": action,
                    "superseded": not finalized}

    if not _request_is_current(request_path, request, state_dir):
        return {"ok": True, "action": "superseded", "superseded": True}
    saved = _run_agent(plugin_dir, request, "save", local_position)
    action = "saved"
    receipt = _receipt_data(request, saved, action)
    finalized = _finalize(
        request_path, request, state_dir, action, local_position,
        saved, receipt, debug_path)
    return {"ok": True, "action": action, "superseded": not finalized}


RECEIPT_KEYS = (
    "receipt_version", "asin", "source_sequence", "source_checksum",
    "long_position", "short_position", "native_percent",
    "koreader_percent", "status_hex", "synced_at", "action",
)


def _parse_receipt(path, expected_asin):
    fields, checksum = _parse_checksummed(_read_regular(path), RECEIPT_KEYS)
    if fields["receipt_version"] != "1" \
            or _validate_asin(fields["asin"]) != expected_asin \
            or not DIGITS_RE.fullmatch(fields["source_sequence"]) \
            or not re.fullmatch(r"[0-9a-f]{64}", fields["source_checksum"]) \
            or fields["action"] not in ("saved", "already_current") \
            or not DIGITS_RE.fullmatch(fields["synced_at"]):
        raise ProgressOutboxError("invalid durable progress receipt")
    status = _unhex(fields["status_hex"], "status", 64)
    if not re.fullmatch(r"[a-z-]{0,32}", status):
        raise ProgressOutboxError("invalid durable progress receipt")
    return {
        "asin": expected_asin,
        "sequence": fields["source_sequence"],
        "checksum": checksum,
        "long": _validate_long(fields["long_position"]),
        "pid": _validate_short(fields["short_position"]),
        "native_percent": _bounded_percent(fields["native_percent"]),
        "koreader_percent": _bounded_percent(fields["koreader_percent"]),
        "status": status or "reading",
        "synced_at": int(fields["synced_at"]),
        "action": fields["action"],
    }


def list_receipts(state_dir=DEFAULT_STATE_DIR):
    receipt_dir = os.path.join(os.path.abspath(state_dir), "progress-receipts")
    try:
        names = sorted(os.listdir(receipt_dir))
    except FileNotFoundError:
        return []
    results = []
    for name in names:
        if not ASIN_RE.fullmatch(name):
            continue
        try:
            results.append(_parse_receipt(
                os.path.join(receipt_dir, name), name))
        except ProgressOutboxError:
            continue
    return results
