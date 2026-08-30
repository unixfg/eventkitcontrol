#!/bin/bash
# Build and validate a signed ekctl binary for local, personal use.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

for required_command in plutil codesign install tar shasum uname git awk \
    xcode-select mkdir mktemp rm dirname; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "error: required command not found: $required_command" >&2
        exit 1
    fi
done

DEFAULT_XCODE_DIRECTORY="/Applications/Xcode.app/Contents/Developer"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SELECTED_DEVELOPER_DIRECTORY="$DEVELOPER_DIR"
else
    SELECTED_DEVELOPER_DIRECTORY="$(xcode-select -p 2>/dev/null || true)"
fi

if [[ "$SELECTED_DEVELOPER_DIRECTORY" == "/Library/Developer/CommandLineTools" \
    && -x "$DEFAULT_XCODE_DIRECTORY/usr/bin/xcodebuild" ]]; then
    SELECTED_DEVELOPER_DIRECTORY="$DEFAULT_XCODE_DIRECTORY"
fi

if [[ ! -x "$SELECTED_DEVELOPER_DIRECTORY/usr/bin/xcodebuild" \
    || ! -x "$SELECTED_DEVELOPER_DIRECTORY/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]]; then
    echo "error: ekctl requires a full Xcode installation, not only Command Line Tools." >&2
    echo "Install Xcode in /Applications, select it with xcode-select, or set DEVELOPER_DIR." >&2
    exit 1
fi
export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIRECTORY"
SWIFT_EXECUTABLE="$SELECTED_DEVELOPER_DIRECTORY/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

BUILD_ROOT="$SCRIPT_DIR/.build"
if [[ -e "$BUILD_ROOT" || -L "$BUILD_ROOT" ]]; then
    if [[ ! -d "$BUILD_ROOT" || -L "$BUILD_ROOT" ]]; then
        echo "error: build root must be a real directory, not a file or symlink: $BUILD_ROOT" >&2
        exit 1
    fi
else
    mkdir -m 0700 "$BUILD_ROOT"
fi

BUILD_ROOT_PHYSICAL="$(cd -- "$BUILD_ROOT" && pwd -P)"
if [[ "$BUILD_ROOT_PHYSICAL" != "$BUILD_ROOT" ]]; then
    echo "error: build root resolves outside the expected repository path: $BUILD_ROOT" >&2
    exit 1
fi

RUN_DIRECTORY="$(mktemp -d "$BUILD_ROOT/ekctl-build.XXXXXX")"
RUN_DIRECTORY_PHYSICAL="$(cd -- "$RUN_DIRECTORY" && pwd -P)"
case "$RUN_DIRECTORY_PHYSICAL" in
    "$BUILD_ROOT_PHYSICAL"/ekctl-build.*) ;;
    *)
        echo "error: temporary build directory escaped the verified build root: $RUN_DIRECTORY" >&2
        exit 1
        ;;
esac

BUILD_COMPLETED=false
cleanup_incomplete_build() {
    if [[ "$BUILD_COMPLETED" != true \
        && -n "${RUN_DIRECTORY:-}" \
        && "$RUN_DIRECTORY" == "$BUILD_ROOT"/ekctl-build.* \
        && -d "$RUN_DIRECTORY" \
        && ! -L "$RUN_DIRECTORY" ]]; then
        rm -rf -- "$RUN_DIRECTORY"
    fi
}
trap cleanup_incomplete_build EXIT

SWIFTPM_SCRATCH_DIRECTORY="$RUN_DIRECTORY/swiftpm-scratch"
SWIFTPM_CACHE_DIRECTORY="$RUN_DIRECTORY/swiftpm-cache"
SWIFTPM_CONFIG_DIRECTORY="$RUN_DIRECTORY/swiftpm-config"
SWIFTPM_SECURITY_DIRECTORY="$RUN_DIRECTORY/swiftpm-security"
CLANG_CACHE_DIRECTORY="$RUN_DIRECTORY/module-cache/clang"
SWIFTPM_MODULE_CACHE_DIRECTORY="$RUN_DIRECTORY/module-cache/swiftpm"
PACKAGE_DIRECTORY="$RUN_DIRECTORY/local-package"
mkdir -p \
    "$SWIFTPM_SCRATCH_DIRECTORY" \
    "$SWIFTPM_CACHE_DIRECTORY" \
    "$SWIFTPM_CONFIG_DIRECTORY" \
    "$SWIFTPM_SECURITY_DIRECTORY" \
    "$CLANG_CACHE_DIRECTORY" \
    "$SWIFTPM_MODULE_CACHE_DIRECTORY" \
    "$PACKAGE_DIRECTORY"
SWIFTPM_SCRATCH_DIRECTORY_PHYSICAL="$(cd -- "$SWIFTPM_SCRATCH_DIRECTORY" && pwd -P)"

export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIRECTORY"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_MODULE_CACHE_DIRECTORY"

SWIFT_PATH_OPTIONS=(
    --scratch-path "$SWIFTPM_SCRATCH_DIRECTORY"
    --cache-path "$SWIFTPM_CACHE_DIRECTORY"
    --config-path "$SWIFTPM_CONFIG_DIRECTORY"
    --security-path "$SWIFTPM_SECURITY_DIRECTORY"
)

plutil -lint "$SCRIPT_DIR/Info.plist" "$SCRIPT_DIR/ekctl.entitlements"

echo "Building ekctl from locked dependencies..."
"$SWIFT_EXECUTABLE" build \
    "${SWIFT_PATH_OPTIONS[@]}" \
    -c release \
    --product ekctl \
    --disable-automatic-resolution

BIN_DIRECTORY="$(
    "$SWIFT_EXECUTABLE" build \
        "${SWIFT_PATH_OPTIONS[@]}" \
        -c release \
        --product ekctl \
        --disable-automatic-resolution \
        --show-bin-path
)"
BUILT_BINARY="$BIN_DIRECTORY/ekctl"

BIN_DIRECTORY_PHYSICAL="$(cd -- "$BIN_DIRECTORY" && pwd -P)"
case "$BIN_DIRECTORY_PHYSICAL/" in
    "$SWIFTPM_SCRATCH_DIRECTORY_PHYSICAL/"*) ;;
    *)
        echo "error: SwiftPM binary directory escaped this run's fresh scratch tree: $BIN_DIRECTORY" >&2
        exit 1
        ;;
esac

if [[ ! -f "$BUILT_BINARY" || ! -x "$BUILT_BINARY" || -L "$BUILT_BINARY" ]]; then
    echo "error: expected executable was not produced: $BUILT_BINARY" >&2
    exit 1
fi

STAGED_BINARY="$PACKAGE_DIRECTORY/ekctl"
install -m 0755 "$BUILT_BINARY" "$STAGED_BINARY"
if [[ ! -f "$STAGED_BINARY" || -L "$STAGED_BINARY" ]]; then
    echo "error: staged executable is not a regular file: $STAGED_BINARY" >&2
    exit 1
fi

SIGNING_IDENTITY="${EKCTL_SIGNING_IDENTITY:--}"
echo "Signing staged binary with Hardened Runtime and EventKit entitlements..."
codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp=none \
    --entitlements "$SCRIPT_DIR/ekctl.entitlements" \
    "$STAGED_BINARY"

/bin/bash "$SCRIPT_DIR/Scripts/validate-artifact.sh" "$STAGED_BINARY"

VERSION="$("$STAGED_BINARY" --version | awk 'NF { print $NF; exit }')"
if [[ ! "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?([+][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "error: unsafe or invalid version returned by ekctl: $VERSION" >&2
    exit 1
fi

SOURCE_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
ARCHITECTURE="$(uname -m)"
if [[ ! "$SOURCE_REVISION" =~ ^([0-9a-f]{7,40}|unknown)$ ]]; then
    echo "error: unsafe source revision for artifact filename: $SOURCE_REVISION" >&2
    exit 1
fi
WORKTREE_STATUS="$(git status --porcelain --untracked-files=normal 2>/dev/null || true)"
if [[ -n "$WORKTREE_STATUS" ]]; then
    SOURCE_REVISION="${SOURCE_REVISION}-dirty"
fi
if [[ ! "$ARCHITECTURE" =~ ^[0-9A-Za-z_]+$ ]]; then
    echo "error: unsafe architecture for artifact filename: $ARCHITECTURE" >&2
    exit 1
fi

ARCHIVE_NAME="ekctl-v${VERSION}-local-${SOURCE_REVISION}-${ARCHITECTURE}.tar.gz"
ARCHIVE_PATH="$PACKAGE_DIRECTORY/$ARCHIVE_NAME"

tar -C "$PACKAGE_DIRECTORY" -czf "$ARCHIVE_PATH" ekctl
(
    cd -- "$PACKAGE_DIRECTORY"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)
BUILD_COMPLETED=true

echo ""
echo "Local build complete and validated."
echo "Binary:  $STAGED_BINARY"
echo "Archive: $ARCHIVE_PATH"
echo "SHA-256: $ARCHIVE_PATH.sha256"
echo "No files were installed outside the repository."
