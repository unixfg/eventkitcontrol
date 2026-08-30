#!/bin/bash
# Build, sign, and validate an ARM64 eventkitcontrol executable.
# The default local build leaves one binary in a unique artifact directory under
# .build and removes its isolated SwiftPM scratch tree.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    local exit_status="${1:-64}"
    cat >&2 <<EOF
usage: $0 [options]

Options:
  --output-dir DIR              New repository-local directory for the binary
  --signing-mode MODE           ad-hoc (default) or developer-id
  --signing-identity SHA1       Developer ID Application certificate SHA-1
  --team-id TEAMID              Expected 10-character Apple Team ID
  --keychain PATH               Keychain containing the signing identity
EOF
    exit "$exit_status"
}

SIGNING_MODE="ad-hoc"
SIGNING_IDENTITY=""
EXPECTED_TEAM_ID=""
KEYCHAIN_PATH=""
REQUESTED_OUTPUT_DIRECTORY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            [[ $# -ge 2 ]] || usage
            REQUESTED_OUTPUT_DIRECTORY="$2"
            shift 2
            ;;
        --signing-mode)
            [[ $# -ge 2 ]] || usage
            SIGNING_MODE="$2"
            shift 2
            ;;
        --signing-identity)
            [[ $# -ge 2 ]] || usage
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --team-id)
            [[ $# -ge 2 ]] || usage
            EXPECTED_TEAM_ID="$2"
            shift 2
            ;;
        --keychain)
            [[ $# -ge 2 ]] || usage
            KEYCHAIN_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage 0
            ;;
        *) usage ;;
    esac
done

case "$SIGNING_MODE" in
    ad-hoc)
        [[ -z "$SIGNING_IDENTITY" && -z "$EXPECTED_TEAM_ID" && -z "$KEYCHAIN_PATH" ]] \
            || fail "Developer ID options cannot be used with ad-hoc signing"
        ;;
    developer-id)
        [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]] \
            || fail "developer-id signing requires a certificate SHA-1"
        [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
            || fail "developer-id signing requires a 10-character --team-id"
        if [[ -n "$KEYCHAIN_PATH" ]]; then
            [[ "$KEYCHAIN_PATH" == /* ]] || fail "--keychain must be an absolute path"
            [[ -f "$KEYCHAIN_PATH" && ! -L "$KEYCHAIN_PATH" ]] \
                || fail "keychain is not a regular file: $KEYCHAIN_PATH"
        fi
        ;;
    *) fail "unsupported signing mode: $SIGNING_MODE" ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$PROJECT_ROOT"

for required_command in codesign install lipo mkdir mktemp mv plutil rm rmdir xcode-select; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command not found: $required_command"
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
    fail "eventkitcontrol requires a full Xcode 26 or later installation with Swift 6"
fi
export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIRECTORY"
XCODEBUILD_EXECUTABLE="$SELECTED_DEVELOPER_DIRECTORY/usr/bin/xcodebuild"
SWIFT_EXECUTABLE="$SELECTED_DEVELOPER_DIRECTORY/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

XCODE_VERSION="$("$XCODEBUILD_EXECUTABLE" -version | awk 'NR == 1 && $1 == "Xcode" { print $2 }')"
XCODE_MAJOR="${XCODE_VERSION%%.*}"
if [[ ! "$XCODE_MAJOR" =~ ^[0-9]+$ ]] || (( XCODE_MAJOR < 26 )); then
    fail "eventkitcontrol requires Xcode 26 or later; selected Xcode is ${XCODE_VERSION:-unknown}"
fi
SWIFT_VERSION_OUTPUT="$("$SWIFT_EXECUTABLE" --version)"
[[ "$SWIFT_VERSION_OUTPUT" == *"Swift version 6."* ]] \
    || fail "eventkitcontrol requires Swift 6 from the selected Xcode toolchain"

BUILD_ROOT="$PROJECT_ROOT/.build"
if [[ -e "$BUILD_ROOT" || -L "$BUILD_ROOT" ]]; then
    [[ -d "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] \
        || fail "build root must be a real directory: $BUILD_ROOT"
else
    mkdir -m 0700 "$BUILD_ROOT"
fi

BUILD_ROOT_PHYSICAL="$(cd -- "$BUILD_ROOT" && pwd -P)"
[[ "$BUILD_ROOT_PHYSICAL" == "$BUILD_ROOT" ]] \
    || fail "build root resolves outside the repository: $BUILD_ROOT"

RUN_DIRECTORY="$(mktemp -d "$BUILD_ROOT/eventkitcontrol-build.XXXXXX")"
RUN_DIRECTORY_PHYSICAL="$(cd -- "$RUN_DIRECTORY" && pwd -P)"
case "$RUN_DIRECTORY_PHYSICAL" in
    "$BUILD_ROOT_PHYSICAL"/eventkitcontrol-build.*) ;;
    *) fail "temporary build directory escaped the verified build root" ;;
esac

cleanup() {
    if [[ -n "${RUN_DIRECTORY:-}" \
        && "$RUN_DIRECTORY" == "$BUILD_ROOT"/eventkitcontrol-build.* \
        && -d "$RUN_DIRECTORY" \
        && ! -L "$RUN_DIRECTORY" ]]; then
        rm -rf -- "$RUN_DIRECTORY"
    fi

    if [[ "${OUTPUT_DIRECTORY_CREATED:-false}" == true \
        && "${OUTPUT_COMPLETE:-false}" != true \
        && -n "${OUTPUT_DIRECTORY:-}" \
        && -d "$OUTPUT_DIRECTORY" \
        && ! -L "$OUTPUT_DIRECTORY" ]]; then
        if [[ -n "${OUTPUT_TEMPORARY_BINARY:-}" \
            && "$OUTPUT_TEMPORARY_BINARY" == "$OUTPUT_DIRECTORY/.eventkitcontrol.tmp" \
            && -f "$OUTPUT_TEMPORARY_BINARY" \
            && ! -L "$OUTPUT_TEMPORARY_BINARY" ]]; then
            rm -f -- "$OUTPUT_TEMPORARY_BINARY"
        fi
        rmdir "$OUTPUT_DIRECTORY" 2>/dev/null || true
    fi
}
trap cleanup EXIT

SWIFTPM_SCRATCH_DIRECTORY="$RUN_DIRECTORY/swiftpm-scratch"
SWIFTPM_CACHE_DIRECTORY="$RUN_DIRECTORY/swiftpm-cache"
SWIFTPM_CONFIG_DIRECTORY="$RUN_DIRECTORY/swiftpm-config"
SWIFTPM_SECURITY_DIRECTORY="$RUN_DIRECTORY/swiftpm-security"
CLANG_CACHE_DIRECTORY="$RUN_DIRECTORY/module-cache/clang"
SWIFTPM_MODULE_CACHE_DIRECTORY="$RUN_DIRECTORY/module-cache/swiftpm"
STAGING_DIRECTORY="$RUN_DIRECTORY/artifact"
mkdir -p \
    "$SWIFTPM_SCRATCH_DIRECTORY" \
    "$SWIFTPM_CACHE_DIRECTORY" \
    "$SWIFTPM_CONFIG_DIRECTORY" \
    "$SWIFTPM_SECURITY_DIRECTORY" \
    "$CLANG_CACHE_DIRECTORY" \
    "$SWIFTPM_MODULE_CACHE_DIRECTORY" \
    "$STAGING_DIRECTORY"

SWIFTPM_SCRATCH_DIRECTORY_PHYSICAL="$(cd -- "$SWIFTPM_SCRATCH_DIRECTORY" && pwd -P)"
export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIRECTORY"
export SWIFTPM_MODULECACHE_OVERRIDE="$SWIFTPM_MODULE_CACHE_DIRECTORY"

SWIFT_PATH_OPTIONS=(
    --scratch-path "$SWIFTPM_SCRATCH_DIRECTORY"
    --cache-path "$SWIFTPM_CACHE_DIRECTORY"
    --config-path "$SWIFTPM_CONFIG_DIRECTORY"
    --security-path "$SWIFTPM_SECURITY_DIRECTORY"
)
SWIFT_BUILD_OPTIONS=(
    "${SWIFT_PATH_OPTIONS[@]}"
    --configuration release
    --product eventkitcontrol
    --arch arm64
    --disable-automatic-resolution
)

plutil -lint "$PROJECT_ROOT/Info.plist" "$PROJECT_ROOT/eventkitcontrol.entitlements" >/dev/null

echo "Building ARM64 eventkitcontrol from locked dependencies..."
"$SWIFT_EXECUTABLE" build "${SWIFT_BUILD_OPTIONS[@]}"

BIN_DIRECTORY="$(
    "$SWIFT_EXECUTABLE" build "${SWIFT_BUILD_OPTIONS[@]}" --show-bin-path
)"
BIN_DIRECTORY_PHYSICAL="$(cd -- "$BIN_DIRECTORY" && pwd -P)"
case "$BIN_DIRECTORY_PHYSICAL/" in
    "$SWIFTPM_SCRATCH_DIRECTORY_PHYSICAL/"*) ;;
    *) fail "SwiftPM binary directory escaped this run's scratch tree" ;;
esac

BUILT_BINARY="$BIN_DIRECTORY/eventkitcontrol"
[[ -f "$BUILT_BINARY" && -x "$BUILT_BINARY" && ! -L "$BUILT_BINARY" ]] \
    || fail "expected executable was not produced: $BUILT_BINARY"

STAGED_BINARY="$STAGING_DIRECTORY/eventkitcontrol"
install -m 0755 "$BUILT_BINARY" "$STAGED_BINARY"

CODESIGN_OPTIONS=(
    --force
    --identifier io.github.unixfg.eventkitcontrol
    --options runtime
    --entitlements "$PROJECT_ROOT/eventkitcontrol.entitlements"
)

if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
    echo "Applying an ad-hoc Hardened Runtime signature..."
    codesign \
        --sign - \
        "${CODESIGN_OPTIONS[@]}" \
        --timestamp=none \
        "$STAGED_BINARY"
    "$SCRIPT_DIR/validate-artifact.sh" \
        --signature ad-hoc \
        "$STAGED_BINARY"
else
    echo "Applying a Developer ID Application signature..."
    DEVELOPER_CODESIGN_OPTIONS=(
        --sign "$SIGNING_IDENTITY"
        "${CODESIGN_OPTIONS[@]}"
        --timestamp
    )
    if [[ -n "$KEYCHAIN_PATH" ]]; then
        DEVELOPER_CODESIGN_OPTIONS+=(--keychain "$KEYCHAIN_PATH")
    fi
    codesign "${DEVELOPER_CODESIGN_OPTIONS[@]}" "$STAGED_BINARY"
    "$SCRIPT_DIR/validate-artifact.sh" \
        --signature developer-id \
        --team-id "$EXPECTED_TEAM_ID" \
        "$STAGED_BINARY"
fi

OUTPUT_DIRECTORY_CREATED=false
OUTPUT_COMPLETE=false
if [[ -n "$REQUESTED_OUTPUT_DIRECTORY" ]]; then
    if [[ "$REQUESTED_OUTPUT_DIRECTORY" == /* ]]; then
        OUTPUT_DIRECTORY="$REQUESTED_OUTPUT_DIRECTORY"
    else
        OUTPUT_DIRECTORY="$PROJECT_ROOT/$REQUESTED_OUTPUT_DIRECTORY"
    fi
    [[ ! -e "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] \
        || fail "output directory already exists: $OUTPUT_DIRECTORY"

    OUTPUT_PARENT="$(dirname -- "$OUTPUT_DIRECTORY")"
    [[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
        || fail "output parent must be an existing real directory: $OUTPUT_PARENT"
    OUTPUT_PARENT_PHYSICAL="$(cd -- "$OUTPUT_PARENT" && pwd -P)"
    case "$OUTPUT_PARENT_PHYSICAL/" in
        "$PROJECT_ROOT/"*) ;;
        *) fail "output directory must remain inside the repository" ;;
    esac

    mkdir -m 0700 "$OUTPUT_DIRECTORY"
else
    OUTPUT_DIRECTORY="$(mktemp -d "$BUILD_ROOT/eventkitcontrol-artifact.XXXXXX")"
fi
OUTPUT_DIRECTORY_CREATED=true

OUTPUT_TEMPORARY_BINARY="$OUTPUT_DIRECTORY/.eventkitcontrol.tmp"
install -m 0755 "$STAGED_BINARY" "$OUTPUT_TEMPORARY_BINARY"
if [[ "$SIGNING_MODE" == "ad-hoc" ]]; then
    "$SCRIPT_DIR/validate-artifact.sh" --signature ad-hoc "$OUTPUT_TEMPORARY_BINARY"
else
    "$SCRIPT_DIR/validate-artifact.sh" \
        --signature developer-id \
        --team-id "$EXPECTED_TEAM_ID" \
        "$OUTPUT_TEMPORARY_BINARY"
fi

FINAL_BINARY="$OUTPUT_DIRECTORY/eventkitcontrol"
mv -- "$OUTPUT_TEMPORARY_BINARY" "$FINAL_BINARY"
OUTPUT_COMPLETE=true

echo "Build complete."
echo "Binary: $FINAL_BINARY"
echo "No archive or installation was created."
