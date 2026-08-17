#!/usr/bin/env bash
# python_build.sh — Build kindle-helper using pre-built CPython + wheels.
#
# No compilation of Python. Downloads:
#   1. CPython standalone (armv7) from astral-sh/python-build-standalone
#   2. C extension wheels from PyPI/piwheels, with Pillow built on Bullseye
#   3. Pure Python packages (beautifulsoup4)
# Only Docker step: cross-compile tiny C wrapper + syscall shim (~30 seconds)
#
# Produces a deployable ZIP:
#   kindle.koplugin/
#     kindle-helper          - C wrapper (static ARM binary, invokes python3)
#     libsyscall_wrapper.so  - Syscall compatibility shim (preadv2/pwritev2)
#     dist/                  - Python runtime + dependencies
#       bin/python3          - CPython interpreter (glibc 2.17+, Kindle OK)
#       lib/python3.11/      - Stdlib + site-packages
#       kindle_helper.py     - Entry point
#       kfxlib/              - KFX conversion engine
#       dedrm/               - DRM decryption
#     lua/                   - Lua plugin modules
#     main.lua, _meta.lua    - KOReader plugin entry points
#
# Usage:
#   ./python_build.sh
#
# Prerequisites:
#   - Docker with buildx (for C wrapper only, ~30 seconds)
#   - Internet access for downloads

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TARGET="armv7"
VERSION="$(date +%Y%m%d)"
OUTPUT_DIR="build"

# Versions
PYTHON_BUILD_STANDALONE_TAG="20260414"
CPYTHON_VERSION="3.11.15"
CPYTHON_TARBALL_SHA256="822b49f675b04581e4244136272c4662e8475c002e65c08a9f75911e0e935627"
LXML_VERSION="6.0.3"
LXML_WHEEL_URL="https://archive1.piwheels.org/simple/lxml/lxml-6.0.3-cp311-cp311-linux_armv7l.whl"
LXML_WHEEL_SHA256="a212e799ad3eb9441327bf0199b11c91ab8bda77fa0a2b2c51ce0a4cd8deaeac"
PILLOW_VERSION="12.2.0"
PILLOW_BUILDER_IMAGE="arm32v7/debian:bullseye@sha256:b4ac940510634c13c9ce5b1124d2b5a90b5738408637e64e970fe927da895bed"
GCC_BUILDER_IMAGE="arm32v7/gcc:12@sha256:02c806c776f0e182b77ace82aadd501dcd0be902650139b4c84fa12d22895771"
DEBIAN_SNAPSHOT="20260803T000000Z"
PILLOW_SOURCE_URL="https://files.pythonhosted.org/packages/8c/21/c2bcdd5906101a30244eaffc1b6e6ce71a31bd0742a01eb89e660ebfac2d/pillow-12.2.0.tar.gz"
PILLOW_SOURCE_SHA256="a830b1a40919539d07806aa58e1b114df53ddd43213d9c8b75847eee6c0182b5"
PILLOW_WHEEL_BASENAME="pillow-${PILLOW_VERSION}-cp311-cp311-linux_armv7l.whl"
PYBIND11_VERSION="3.0.1"
PYBIND11_WHEEL_URL="https://files.pythonhosted.org/packages/cd/8a/37362fc2b949d5f733a8b0f2ff51ba423914cabefe69f1d1b6aab710f5fe/pybind11-3.0.1-py3-none-any.whl"
PYBIND11_WHEEL_SHA256="aa8f0aa6e0a94d3b64adfc38f560f33f15e589be2175e103c0a33c6bce55ee89"
PYCRYPTODOME_VERSION="3.9.9"
PYCRYPTODOME_WHEEL_URL="https://archive1.piwheels.org/simple/pycryptodome/pycryptodome-3.9.9-cp311-cp311-linux_armv7l.whl"
PYCRYPTODOME_WHEEL_SHA256="2bd41fc16ee5e5c61098a29b2289334a572ed071b3f282a6fe0b9595dd53c22e"
BEAUTIFULSOUP_VERSION="4.14.3"
BEAUTIFULSOUP_WHEEL_URL="https://files.pythonhosted.org/packages/1a/39/47f9197bdd44df24d67ac8893641e16f386c984a0619ef2ee4c51fbbc019/beautifulsoup4-4.14.3-py3-none-any.whl"
BEAUTIFULSOUP_WHEEL_SHA256="0918bfe44902e6ad8d57732ba310582e98da931428d231a5ecb9e7c703a735bb"
SOUPSIEVE_VERSION="2.8.1"
SOUPSIEVE_WHEEL_URL="https://files.pythonhosted.org/packages/48/f3/b67d6ea49ca9154453b6d70b34ea22f3996b9fa55da105a79d8732227adc/soupsieve-2.8.1-py3-none-any.whl"
SOUPSIEVE_WHEEL_SHA256="a11fe2a6f3d76ab3cf2de04eb339c1be5b506a8a47f2ceb6d139803177f85434"

verify_sha256() {
    file="$1"
    expected="$2"
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "$file" | awk '{print $1}')"
    else
        actual="$(shasum -a 256 "$file" | awk '{print $1}')"
    fi
    if [ "$actual" != "$expected" ]; then
        echo "SHA-256 mismatch: $file" >&2
        return 1
    fi
}

build_arm_image() {
    local image_tag="$1"
    local dockerfile="$2"
    local build_context
    local build_status=0

    # Neither wrapper Dockerfile consumes checkout files. An exclusive empty
    # context prevents Git history, generated archives, and untracked local
    # material from being uploaded to the configured Docker daemon.
    build_context="$(mktemp -d "${TMPDIR:-/tmp}/kindle-wrapper-context.XXXXXX")" \
        || return 1
    if docker buildx version >/dev/null 2>&1; then
        docker buildx build \
            --platform linux/arm/v7 \
            -t "$image_tag" \
            -f "$dockerfile" \
            --load \
            "$build_context" || build_status=$?
    else
        # Docker Desktop installations without the optional buildx CLI still
        # expose multi-platform support through the legacy build command.
        docker build \
            --platform linux/arm/v7 \
            -t "$image_tag" \
            -f "$dockerfile" \
            "$build_context" || build_status=$?
    fi
    rmdir "$build_context" || return 1
    return "$build_status"
}

build_pillow_arm_assets() {
    python_dist="$(cd "$1" && pwd)"
    asset_dir="$2"
    expected_wheel="$asset_dir/$PILLOW_WHEEL_BASENAME"
    ca_bundle="$python_dist/lib/python3.11/site-packages/pip/_vendor/certifi/cacert.pem"
    crypto_source="$SCRIPT_DIR/lib/crypto_hook.c"
    test -f "$ca_bundle"
    test -f "$crypto_source"

    source_archive="$CACHE_DIR/pillow-${PILLOW_VERSION}.tar.gz"
    if [ ! -f "$source_archive" ]; then
        curl -fSL --progress-bar -o "$source_archive" "$PILLOW_SOURCE_URL"
    fi
    verify_sha256 "$source_archive" "$PILLOW_SOURCE_SHA256"
    pybind11_wheel="$CACHE_DIR/pybind11-${PYBIND11_VERSION}-py3-none-any.whl"
    if [ ! -f "$pybind11_wheel" ]; then
        curl -fSL --progress-bar -o "$pybind11_wheel" "$PYBIND11_WHEEL_URL"
    fi
    verify_sha256 "$pybind11_wheel" "$PYBIND11_WHEEL_SHA256"

    rm -rf "$asset_dir"
    mkdir -p "$asset_dir"
    docker run --rm --platform linux/arm/v7 \
        -e "DEBIAN_SNAPSHOT=$DEBIAN_SNAPSHOT" \
        -e "PYBIND11_VERSION=$PYBIND11_VERSION" \
        -v "$(cd "$python_dist" && pwd):/python:ro" \
        -v "$(cd "$(dirname "$source_archive")" && pwd)/$(basename "$source_archive"):/src/pillow.tar.gz:ro" \
        -v "$(cd "$(dirname "$pybind11_wheel")" && pwd)/$(basename "$pybind11_wheel"):/src/pybind11-${PYBIND11_VERSION}-py3-none-any.whl:ro" \
        -v "$ca_bundle:/etc/ssl/certs/ca-certificates.crt:ro" \
        -v "$crypto_source:/src/crypto_hook.c:ro" \
        -v "$(cd "$asset_dir" && pwd):/out" \
        "$PILLOW_BUILDER_IMAGE" bash -c '
set -eu
printf "%s\n" \
    "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bullseye main" \
    "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bullseye-updates main" \
    "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/ bullseye-security main" \
    > /etc/apt/sources.list
rm -f /etc/apt/sources.list.d/*
apt-get -o Acquire::Check-Valid-Until=false update >/dev/null
apt-get install -y --no-install-recommends \
    build-essential=12.9 \
    libfreetype6-dev=2.10.4+dfsg-1+deb11u2 \
    libjpeg62-turbo-dev=1:2.0.6-4 \
    liblcms2-dev=2.12~rc1-2+deb11u1 \
    libopenjp2-7-dev=2.4.0-3+deb11u3 \
    libtiff-dev=4.2.0-1+deb11u8 \
    libwebp-dev=0.6.1-2.1+deb11u2 \
    libxcb1-dev=1.14-3 \
    zlib1g-dev=1:1.2.11.dfsg-2+deb11u2 \
    libxml2=2.9.10+dfsg-6.7+deb11u10 \
    libxslt1.1=1.1.34-4+deb11u3 >/dev/null
mkdir -p /build-deps
/python/bin/python3.11 -m pip install --no-cache-dir --no-deps --no-index \
    --target /build-deps /src/pybind11-${PYBIND11_VERSION}-py3-none-any.whl
PYTHONPATH=/build-deps /python/bin/python3.11 -m pip wheel --no-cache-dir --no-deps \
    --no-binary=Pillow --no-index --no-build-isolation \
    --wheel-dir /out /src/pillow.tar.gz
gcc -shared -fPIC -O2 -o /out/crypto_hook.so /src/crypto_hook.c -ldl -lpthread
strip /out/crypto_hook.so
mkdir -p /out/libs
for lib in \
    libXau.so.6 libXdmcp.so.6 libbrotlicommon.so.1 libbrotlidec.so.1 \
    libbsd.so.0 libdeflate.so.0 libfreetype.so.6 libjbig.so.0 \
    libjpeg.so.62 liblcms2.so.2 liblzma.so.5 libmd.so.0 \
    libopenjp2.so.7 libpng16.so.16 libtiff.so.5 libwebp.so.6 \
    libwebpdemux.so.2 libwebpmux.so.3 libxcb.so.1 libz.so.1 libzstd.so.1 \
    libxml2.so.2 libxslt.so.1 libexslt.so.0 libgcrypt.so.20 \
    libgpg-error.so.0 libicuuc.so.67 libicudata.so.67
do
    if [ -f /usr/lib/arm-linux-gnueabihf/$lib ]; then
        cp -L /usr/lib/arm-linux-gnueabihf/$lib /out/libs/
    elif [ -f /lib/arm-linux-gnueabihf/$lib ]; then
        cp -L /lib/arm-linux-gnueabihf/$lib /out/libs/
    else
        echo "missing required Pillow runtime library: $lib" >&2
        exit 1
    fi
done
'
    test -f "$expected_wheel"
    test -f "$asset_dir/crypto_hook.so"
    test -f "$asset_dir/libs/libxml2.so.2"
}

echo "=== Kindle Helper Build (download-based) ==="
echo "Python: CPython $CPYTHON_VERSION"
echo "Version: $VERSION"
echo ""

# Create output directory
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

STAGING="$OUTPUT_DIR/kindle.koplugin"
mkdir -p "$STAGING"

# ---------------------------------------------------------------------------
# Steps 1-2: CPython + packages
#
# Download archives may be reused only after their hashes are verified. The
# executable runtime and compiled assets are rebuilt into the freshly cleared
# output directory every time; no writable marker can bless an older tree.
# ---------------------------------------------------------------------------
CACHE_DIR="build-cache"
mkdir -p "$CACHE_DIR"

echo "[1/5] Preparing verified CPython $CPYTHON_VERSION (armv7)..."
CPYTHON_TARBALL="$CACHE_DIR/cpython-${CPYTHON_VERSION}+${PYTHON_BUILD_STANDALONE_TAG}.tar.gz"
CPYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_BUILD_STANDALONE_TAG}/cpython-${CPYTHON_VERSION}%2B${PYTHON_BUILD_STANDALONE_TAG}-armv7-unknown-linux-gnueabihf-install_only.tar.gz"
if [ ! -f "$CPYTHON_TARBALL" ]; then
    curl -fSL --progress-bar -o "$CPYTHON_TARBALL" "$CPYTHON_URL"
fi
verify_sha256 "$CPYTHON_TARBALL" "$CPYTHON_TARBALL_SHA256"

DIST_DIR="$OUTPUT_DIR/dist"
mkdir -p "$DIST_DIR"
tar xzf "$CPYTHON_TARBALL" -C "$DIST_DIR" --strip-components=1
test -x "$DIST_DIR/bin/python3"

echo "[2/5] Installing verified packages..."
SITE_PACKAGES="$DIST_DIR/lib/python3.11/site-packages"
mkdir -p "$SITE_PACKAGES"

LXML_WHEEL="$CACHE_DIR/lxml-${LXML_VERSION}-cp311-cp311-linux_armv7l.whl"
if [ ! -f "$LXML_WHEEL" ]; then
    curl -fSL --progress-bar -o "$LXML_WHEEL" "$LXML_WHEEL_URL"
fi
verify_sha256 "${LXML_WHEEL}" "${LXML_WHEEL_SHA256}"
unzip -q -o "$LXML_WHEEL" -d "$SITE_PACKAGES"

# Pillow is compiled in a fresh Bullseye container so neither a cached wheel
# nor a newer host glibc can enter the release.
PILLOW_ASSET_DIR="$OUTPUT_DIR/.pillow-assets"
build_pillow_arm_assets "$DIST_DIR" "$PILLOW_ASSET_DIR"
unzip -q -o "$PILLOW_ASSET_DIR/$PILLOW_WHEEL_BASENAME" -d "$SITE_PACKAGES"

PYCRYPTODOME_WHEEL="$CACHE_DIR/pycryptodome-${PYCRYPTODOME_VERSION}-cp311-cp311-linux_armv7l.whl"
if [ ! -f "$PYCRYPTODOME_WHEEL" ]; then
    curl -fSL --progress-bar -o "$PYCRYPTODOME_WHEEL" "$PYCRYPTODOME_WHEEL_URL"
fi
verify_sha256 "${PYCRYPTODOME_WHEEL}" "${PYCRYPTODOME_WHEEL_SHA256}"
unzip -q -o "$PYCRYPTODOME_WHEEL" -d "$SITE_PACKAGES"

BEAUTIFULSOUP_WHEEL="$CACHE_DIR/beautifulsoup4-${BEAUTIFULSOUP_VERSION}-py3-none-any.whl"
if [ ! -f "$BEAUTIFULSOUP_WHEEL" ]; then
    curl -fSL --progress-bar -o "$BEAUTIFULSOUP_WHEEL" "$BEAUTIFULSOUP_WHEEL_URL"
fi
verify_sha256 "${BEAUTIFULSOUP_WHEEL}" "${BEAUTIFULSOUP_WHEEL_SHA256}"
unzip -q -o "$BEAUTIFULSOUP_WHEEL" -d "$SITE_PACKAGES"

# BeautifulSoup imports its CSS adapter during normal kfxlib startup. The
# adapter warns on stderr when soupsieve is absent, which would corrupt the
# helper's JSON-only process protocol even when CSS selectors are not used.
SOUPSIEVE_WHEEL="$CACHE_DIR/soupsieve-${SOUPSIEVE_VERSION}-py3-none-any.whl"
if [ ! -f "$SOUPSIEVE_WHEEL" ]; then
    curl -fSL --progress-bar -o "$SOUPSIEVE_WHEEL" "$SOUPSIEVE_WHEEL_URL"
fi
verify_sha256 "${SOUPSIEVE_WHEEL}" "${SOUPSIEVE_WHEEL_SHA256}"
unzip -q -o "$SOUPSIEVE_WHEEL" -d "$SITE_PACKAGES"

# ---------------------------------------------------------------------------
# Step 3: Copy plugin Python source into dist
# ---------------------------------------------------------------------------
echo "[3/5] Copying plugin source..."

cp python/kindle_helper.py "$DIST_DIR/kindle_helper.py"
cp python/annotation_position.py "$DIST_DIR/annotation_position.py"
cp -r python/kfxlib/ "$DIST_DIR/kfxlib/"
cp -r python/dedrm/ "$DIST_DIR/dedrm/"

# Clean bytecode
find "$DIST_DIR" -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$DIST_DIR" -name "*.pyc" -delete 2>/dev/null || true

# Strip unnecessary files from CPython to reduce size
rm -rf "$DIST_DIR/include"                # C headers
rm -rf "$DIST_DIR/share"                  # man pages, etc
rm -rf "$DIST_DIR/bin/2to3"*              # unused tools
rm -rf "$DIST_DIR/bin/idle3"*             # IDE
rm -rf "$DIST_DIR/bin/pydoc3"*            # docs
rm -rf "$DIST_DIR/bin/pip"*               # pip not needed at runtime
rm -rf "$DIST_DIR/bin/python"             # duplicate binary
mv "$DIST_DIR/bin/python3.11" "$DIST_DIR/bin/python3"
rm -f "$DIST_DIR/bin/python3-config"
rm -f "$DIST_DIR/bin/python3.11-config"
rm -rf "$DIST_DIR/lib/libpython3.11.so"*          # shared lib (28MB, not needed)
rm -rf "$DIST_DIR/lib/libpython3.so"             # linker stub
rm -rf "$DIST_DIR/lib/pkgconfig"                 # build metadata
rm -rf "$DIST_DIR/lib/tcl9"                      # Tcl runtime
rm -rf "$DIST_DIR/lib/tcl9.0"                    # Tcl runtime
rm -rf "$DIST_DIR/lib/tk9.0"                     # Tk runtime
rm -rf "$DIST_DIR/lib/itcl"*                     # Tcl extension
rm -rf "$DIST_DIR/lib/thread"*                   # Tcl extension
rm -f "$DIST_DIR/lib/libtcl"*                    # Tcl/Tk .so
rm -f "$DIST_DIR/lib/libtcl9"*                   # Tcl .so
rm -rf "$DIST_DIR/lib/python3.11/idlelib" # IDE
rm -rf "$DIST_DIR/lib/python3.11/tkinter" # Tk
rm -rf "$DIST_DIR/lib/python3.11/test"    # test suite
rm -rf "$DIST_DIR/lib/python3.11/unittest"# test framework
rm -rf "$DIST_DIR/lib/python3.11/pydoc_data" # docs
rm -rf "$DIST_DIR/lib/python3.11/ensurepip"  # pip bundler
rm -rf "$DIST_DIR/lib/python3.11/lib2to3"   # 2to3 converter
rm -rf "$DIST_DIR/lib/python3.11/turtle.py"  # turtle graphics
rm -rf "$DIST_DIR/lib/python3.11/telnetlib.py"
rm -rf "$DIST_DIR/lib/python3.11/asyncio"    # async framework
find "$DIST_DIR/lib/python3.11" -name "tests" -exec rm -rf {} + 2>/dev/null || true
find "$DIST_DIR/lib/python3.11" -name "test" -type d -exec rm -rf {} + 2>/dev/null || true

# Strip debug symbols from the Python binary (27MB -> ~7MB)
docker run --rm --platform linux/arm/v7 \
    -v "$(cd "$DIST_DIR" && pwd)/bin:/mnt" \
    "$GCC_BUILDER_IMAGE" strip /mnt/python3

# Bundle the exact Bullseye runtime libraries used to compile Pillow.
echo "  Bundling shared libs for Pillow..."
mkdir -p "$DIST_DIR/lib/external"
cp -a "$PILLOW_ASSET_DIR/libs/." "$DIST_DIR/lib/external/"
cp "$PILLOW_ASSET_DIR/crypto_hook.so" "$OUTPUT_DIR/crypto_hook.so"

# Strip unnecessary Crypto modules
rm -rf "$SITE_PACKAGES/Crypto/SelfTest"
rm -rf "$SITE_PACKAGES/Crypto/IO"

# Strip pip and setuptools from site-packages (build tools only)
rm -rf "$SITE_PACKAGES/pip"
rm -rf "$SITE_PACKAGES/pip"*.dist-info
rm -rf "$SITE_PACKAGES/setuptools"
rm -rf "$SITE_PACKAGES/setuptools"*.dist-info
rm -rf "$SITE_PACKAGES/_distutils_hack"
rm -f "$SITE_PACKAGES/distutils-precedence.pth"

# ---------------------------------------------------------------------------
# Step 4: Build C wrapper + syscall shim (tiny, ~30 seconds in Docker)
# ---------------------------------------------------------------------------
echo "[4/5] Building C wrapper..."

WRAPPER_TAG="kindle-wrapper-builder"

build_arm_image "$WRAPPER_TAG" .github/Dockerfile.wrapper

CONTAINER_ID=$(docker create "$WRAPPER_TAG")
docker cp "$CONTAINER_ID:/build/kindle-helper" "$OUTPUT_DIR/kindle-helper"
docker cp "$CONTAINER_ID:/build/libsyscall_wrapper.so" "$OUTPUT_DIR/libsyscall_wrapper.so"
docker rm "$CONTAINER_ID"

chmod +x "$OUTPUT_DIR/kindle-helper"

# ---------------------------------------------------------------------------
# Step 5: Package the plugin ZIP
# ---------------------------------------------------------------------------
echo "[5/5] Packaging..."

# Rebuild and compare the privileged Java agent inside this packaging
# transaction, then stage only that freshly verified artifact. A stale or
# locally replaced prebuilt JAR can no longer pass through to the release ZIP.
VERIFIED_AGENT_JAR="$SCRIPT_DIR/$OUTPUT_DIR/native-reading-progress-agent-v7.jar"
KINDLE_AGENT_VERIFIED_OUTPUT="$VERIFIED_AGENT_JAR" \
    ./scripts/check_native_progress_agent
test -f "$VERIFIED_AGENT_JAR"

# Copy Lua plugin files
cp -r lua/ "$STAGING/lua/"
mkdir -p "$STAGING/bin/classes"
cp bin/sync-native-progress "$STAGING/bin/"
cp "$VERIFIED_AGENT_JAR" "$STAGING/bin/native-reading-progress-agent-v7.jar"
cp bin/classes/AttachLauncher.class "$STAGING/bin/classes/"
chmod 0755 "$STAGING/bin/sync-native-progress"
cp main.lua "$STAGING/"
cp _meta.lua "$STAGING/"
cp -r patches/ "$STAGING/patches/" 2>/dev/null || true

# Copy the C wrapper
cp "$OUTPUT_DIR/kindle-helper" "$STAGING/"
cp "$OUTPUT_DIR/libsyscall_wrapper.so" "$STAGING/"

# Copy the DRM helpers (crypto hook, Java jar) into dist/lib/
# Python resolves plugin_dir as dist/ (where kindle_helper.py lives)
mkdir -p "$STAGING/dist/lib"
cp "$OUTPUT_DIR/crypto_hook.so" "$STAGING/dist/lib/"
cp lib/KFXVoucherExtractor.jar "$STAGING/dist/lib/"

# Copy the Python runtime contents into the existing dist/ directory. The
# directory already contains DRM helper assets, so copying DIST_DIR itself
# would incorrectly create dist/dist/ and break the launcher paths.
cp -a "$DIST_DIR/." "$STAGING/dist/"

# Fail the build if the package no longer matches Dockerfile.wrapper's paths.
test -x "$STAGING/dist/bin/python3"
test -f "$STAGING/dist/kindle_helper.py"
test -f "$STAGING/dist/annotation_position.py"
test -f "$STAGING/dist/dedrm/native_extractor.py"
test -d "$STAGING/dist/lib/python3.11/site-packages/soupsieve"
test -f "$STAGING/dist/lib/external/libxml2.so.2"
test -f "$STAGING/dist/lib/external/libxslt.so.1"
test -f "$STAGING/dist/lib/external/libexslt.so.0"
test -f "$STAGING/dist/lib/external/libicuuc.so.67"
test -f "$STAGING/dist/lib/external/libicudata.so.67"
test -f "$STAGING/dist/lib/external/libgcrypt.so.20"
test -f "$STAGING/dist/lib/external/libtiff.so.5"
test ! -f "$STAGING/dist/lib/external/libtiff.so.6"
test -x "$STAGING/bin/sync-native-progress"
test -f "$STAGING/bin/native-reading-progress-agent-v7.jar"
test -f "$STAGING/bin/classes/AttachLauncher.class"
test ! -e "$STAGING/bin/native-reading-progress-agent-v2.jar"
test ! -e "$STAGING/bin/native-reading-progress-agent-v3.jar"
test ! -e "$STAGING/bin/native-reading-progress-agent-v6.jar"
test ! -d "$STAGING/dist/dist"

# Exercise Pillow under the oldest supported build userspace. This catches a
# newer GLIBC symbol in either the wheel or one of its copied dependencies.
docker run --rm --platform linux/arm/v7 \
    -v "$(cd "$STAGING/dist" && pwd):/runtime:ro" \
    "$PILLOW_BUILDER_IMAGE" bash -c '
set -e
export LD_LIBRARY_PATH=/runtime/lib/external
/runtime/bin/python3 -c "from PIL import Image; assert Image.new(\"RGB\", (2, 2)).size == (2, 2)"
if find /runtime/lib/python3.11/site-packages/PIL /runtime/lib/external \
    -type f -name "*.so*" -exec readelf --version-info {} \; 2>/dev/null \
    | grep -Eq "GLIBC_2\\.(3[2-9]|[4-9][0-9])"; then
    echo "Pillow runtime requires glibc newer than Bullseye" >&2
    exit 1
fi
'

# Create ZIP
ZIP_NAME="kindle-koplugin-${TARGET}.zip"
cd "$OUTPUT_DIR"
zip -r "$ZIP_NAME" kindle.koplugin/
cd "$SCRIPT_DIR"

echo ""
echo "=== Done! ==="
echo "Output: $OUTPUT_DIR/$ZIP_NAME"
echo "Size: $(du -sh "$OUTPUT_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "Deploy to Kindle:"
echo "  unzip $OUTPUT_DIR/$ZIP_NAME -d /mnt/us/koreader/plugins/"
