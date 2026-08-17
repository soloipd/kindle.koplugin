#!/usr/bin/env bash

# Resolve one coherent, functional JDK tool directory. macOS ships executable
# placeholders in /usr/bin that exist but fail when no Apple-registered JDK is
# present, so command -v alone is not a valid toolchain check.
kindle_find_jdk_bin() {
    local requested_javac="${JAVAC:-}"
    local path_javac=""
    local resolved_javac=""
    local registered_home=""
    local candidate=""
    local bin_dir=""
    local candidates=()

    path_javac="$(command -v javac 2>/dev/null || true)"
    if [ -n "$path_javac" ] && command -v realpath >/dev/null 2>&1; then
        resolved_javac="$(realpath "$path_javac" 2>/dev/null || true)"
    fi
    if [ -x /usr/libexec/java_home ]; then
        registered_home="$(/usr/libexec/java_home 2>/dev/null || true)"
    fi

    candidates+=(
        "${KINDLE_JDK_BIN:-}"
        "${requested_javac:+$(dirname "$requested_javac")}"
        "${JAVA_HOME:+$JAVA_HOME/bin}"
        "${resolved_javac:+$(dirname "$resolved_javac")}"
        "${path_javac:+$(dirname "$path_javac")}"
        "${registered_home:+$registered_home/bin}"
        /opt/homebrew/opt/openjdk@21/bin
        /opt/homebrew/opt/openjdk@17/bin
        /opt/homebrew/opt/openjdk@11/bin
        /opt/homebrew/opt/openjdk/bin
        /usr/local/opt/openjdk@21/bin
        /usr/local/opt/openjdk@17/bin
        /usr/local/opt/openjdk@11/bin
        /usr/local/opt/openjdk/bin
        /Library/Java/JavaVirtualMachines/*/Contents/Home/bin
        /usr/lib/jvm/java-21-openjdk*/bin
        /usr/lib/jvm/java-17-openjdk*/bin
        /usr/lib/jvm/java-11-openjdk*/bin
        /usr/lib/jvm/default-java/bin
    )

    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        case "$candidate" in
            */bin) bin_dir="$candidate" ;;
            *) bin_dir="$(dirname "$candidate")" ;;
        esac
        [ -x "$bin_dir/javac" ] \
            && [ -x "$bin_dir/jar" ] \
            && [ -x "$bin_dir/javap" ] \
            || continue
        "$bin_dir/javac" -version >/dev/null 2>&1 || continue
        "$bin_dir/javap" -version >/dev/null 2>&1 || continue
        "$bin_dir/jar" --help 2>&1 | grep -q -- '--date' || continue
        printf '%s\n' "$bin_dir"
        return 0
    done
    return 1
}
