#!/bin/bash
# Validate the privacy metadata and signature of a locally built ekctl binary.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() {
    echo "error: $*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    fail "usage: $0 /path/to/ekctl"
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
BINARY_PATH="$1"
EXPECTED_INFO_PLIST="$PROJECT_ROOT/Info.plist"
EXPECTED_ENTITLEMENTS="$PROJECT_ROOT/ekctl.entitlements"

for required_command in codesign otool dd plutil python3 awk grep mktemp rm; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        fail "required command not found: $required_command"
    fi
done

[[ -f "$BINARY_PATH" ]] || fail "binary not found: $BINARY_PATH"
[[ -x "$BINARY_PATH" ]] || fail "binary is not executable: $BINARY_PATH"
[[ ! -L "$BINARY_PATH" ]] || fail "binary must not be a symbolic link: $BINARY_PATH"

plutil -lint "$EXPECTED_INFO_PLIST" "$EXPECTED_ENTITLEMENTS" >/dev/null

TEMP_DIRECTORY="$(mktemp -d /private/tmp/ekctl-validate.XXXXXX)"
cleanup() {
    if [[ -n "${TEMP_DIRECTORY:-}" \
        && "$TEMP_DIRECTORY" == /private/tmp/ekctl-validate.* \
        && -d "$TEMP_DIRECTORY" \
        && ! -L "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi
}
trap cleanup EXIT

ACTUAL_ENTITLEMENTS="$TEMP_DIRECTORY/entitlements.plist"
ACTUAL_INFO_PLIST="$TEMP_DIRECTORY/Info.plist"

echo "Validating code signature..."
codesign --verify --strict --verbose=2 "$BINARY_PATH"

SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$BINARY_PATH" 2>&1)"
if ! grep -Eq 'flags=.*\([^)]*runtime' <<<"$SIGNATURE_DETAILS"; then
    fail "code signature does not enable Hardened Runtime"
fi

codesign \
    --display \
    --xml \
    --entitlements "$ACTUAL_ENTITLEMENTS" \
    "$BINARY_PATH" \
    >/dev/null 2>&1

[[ -s "$ACTUAL_ENTITLEMENTS" ]] || fail "signed binary has no entitlements"
plutil -lint "$ACTUAL_ENTITLEMENTS" >/dev/null

python3 - "$EXPECTED_ENTITLEMENTS" "$ACTUAL_ENTITLEMENTS" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as expected_file:
    expected = plistlib.load(expected_file)
with open(sys.argv[2], "rb") as actual_file:
    actual = plistlib.load(actual_file)

if actual != expected:
    print("error: signed entitlements differ from ekctl.entitlements", file=sys.stderr)
    print(f"expected: {expected!r}", file=sys.stderr)
    print(f"actual:   {actual!r}", file=sys.stderr)
    raise SystemExit(1)
PY

echo "Validating embedded Info.plist..."
SECTION_METADATA="$(otool -l "$BINARY_PATH" | awk '
    $1 == "sectname" { section_name = $2; next }
    $1 == "segname" {
        in_info_section = ($2 == "__TEXT" && section_name == "__info_plist")
        next
    }
    in_info_section && $1 == "size" { section_size = $2; next }
    in_info_section && $1 == "offset" { print $2, section_size; exit }
')"
[[ -n "$SECTION_METADATA" ]] || fail "binary is missing __TEXT,__info_plist"

IFS=' ' read -r INFO_OFFSET INFO_SIZE <<<"$SECTION_METADATA"
[[ "$INFO_SIZE" != "0" && "$INFO_SIZE" != "0x0" ]] \
    || fail "embedded Info.plist section is empty"

dd \
    if="$BINARY_PATH" \
    of="$ACTUAL_INFO_PLIST" \
    bs=1 \
    skip="$((INFO_OFFSET))" \
    count="$((INFO_SIZE))" \
    2>/dev/null
[[ -s "$ACTUAL_INFO_PLIST" ]] || fail "embedded Info.plist section is empty"
plutil -lint "$ACTUAL_INFO_PLIST" >/dev/null

python3 - "$EXPECTED_INFO_PLIST" "$ACTUAL_INFO_PLIST" <<'PY'
import plistlib
import sys

required_keys = {
    "CFBundleExecutable",
    "CFBundleIdentifier",
    "CFBundleName",
    "CFBundleShortVersionString",
    "CFBundleVersion",
    "NSCalendarsFullAccessUsageDescription",
    "NSCalendarsUsageDescription",
    "NSRemindersFullAccessUsageDescription",
    "NSRemindersUsageDescription",
}

with open(sys.argv[1], "rb") as expected_file:
    expected = plistlib.load(expected_file)
with open(sys.argv[2], "rb") as actual_file:
    actual = plistlib.load(actual_file)

if actual != expected:
    print("error: embedded Info.plist differs from the source Info.plist", file=sys.stderr)
    raise SystemExit(1)

missing = sorted(required_keys - actual.keys())
if missing:
    print(f"error: embedded Info.plist is missing keys: {', '.join(missing)}", file=sys.stderr)
    raise SystemExit(1)

for key in required_keys:
    if not isinstance(actual[key], str) or not actual[key].strip():
        print(f"error: embedded Info.plist key {key} must be a non-empty string", file=sys.stderr)
        raise SystemExit(1)

if actual["CFBundleVersion"] != actual["CFBundleShortVersionString"]:
    print("error: plist build and marketing versions differ", file=sys.stderr)
    raise SystemExit(1)
PY

PLIST_VERSION="$(
    plutil -extract CFBundleShortVersionString raw -o - "$ACTUAL_INFO_PLIST"
)"
CLI_VERSION_OUTPUT="$("$BINARY_PATH" --version)"
CLI_VERSION="$(awk 'NF { print $NF; exit }' <<<"$CLI_VERSION_OUTPUT")"
[[ "$CLI_VERSION" == "$PLIST_VERSION" ]] \
    || fail "CLI version '$CLI_VERSION' differs from plist version '$PLIST_VERSION'"

MINIMUM_VERSIONS="$(otool -l "$BINARY_PATH" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_command = 1; next }
    in_command && $1 == "minos" { print $2; in_command = 0 }
')"
[[ -n "$MINIMUM_VERSIONS" ]] || fail "could not determine Mach-O minimum macOS version"

while IFS= read -r minimum_version; do
    case "$minimum_version" in
        13|13.0|13.0.0) ;;
        *) fail "unexpected minimum macOS version: $minimum_version (expected 13.0)" ;;
    esac
done <<<"$MINIMUM_VERSIONS"

echo "Artifact validation passed: version $PLIST_VERSION, macOS 13.0+."
