#!/bin/bash
# Validate an ARM64 eventkitcontrol executable, its embedded privacy metadata,
# deployment target, entitlements, and code-signing mode.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    fail "usage: $0 [--signature ad-hoc|developer-id] [--team-id TEAMID] /path/to/eventkitcontrol"
}

SIGNATURE_MODE="ad-hoc"
EXPECTED_TEAM_ID=""
BINARY_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signature)
            [[ $# -ge 2 ]] || usage
            SIGNATURE_MODE="$2"
            shift 2
            ;;
        --team-id)
            [[ $# -ge 2 ]] || usage
            EXPECTED_TEAM_ID="$2"
            shift 2
            ;;
        --help|-h)
            echo "usage: $0 [--signature ad-hoc|developer-id] [--team-id TEAMID] /path/to/eventkitcontrol"
            exit 0
            ;;
        --*) usage ;;
        *)
            [[ -z "$BINARY_PATH" ]] || usage
            BINARY_PATH="$1"
            shift
            ;;
    esac
done

[[ -n "$BINARY_PATH" ]] || usage
case "$SIGNATURE_MODE" in
    ad-hoc)
        [[ -z "$EXPECTED_TEAM_ID" ]] \
            || fail "--team-id is only valid with --signature developer-id"
        ;;
    developer-id)
        [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
            || fail "developer-id validation requires a 10-character --team-id"
        ;;
    *) fail "unsupported signature mode: $SIGNATURE_MODE" ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
EXPECTED_INFO_PLIST="$PROJECT_ROOT/Info.plist"
EXPECTED_ENTITLEMENTS="$PROJECT_ROOT/eventkitcontrol.entitlements"

for required_command in awk codesign dd grep lipo mktemp otool plutil python3 rm; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command not found: $required_command"
done

[[ -f "$BINARY_PATH" ]] || fail "binary not found: $BINARY_PATH"
[[ -x "$BINARY_PATH" ]] || fail "binary is not executable: $BINARY_PATH"
[[ ! -L "$BINARY_PATH" ]] || fail "binary must not be a symbolic link: $BINARY_PATH"

plutil -lint "$EXPECTED_INFO_PLIST" "$EXPECTED_ENTITLEMENTS" >/dev/null

ARCHITECTURES="$(lipo -archs "$BINARY_PATH")"
[[ "$ARCHITECTURES" == "arm64" ]] \
    || fail "binary architecture is '$ARCHITECTURES'; expected exactly arm64"

TEMP_DIRECTORY="$(mktemp -d /private/tmp/eventkitcontrol-validate.XXXXXX)"
cleanup() {
    if [[ -n "${TEMP_DIRECTORY:-}" \
        && "$TEMP_DIRECTORY" == /private/tmp/eventkitcontrol-validate.* \
        && -d "$TEMP_DIRECTORY" \
        && ! -L "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi
}
trap cleanup EXIT

ACTUAL_ENTITLEMENTS="$TEMP_DIRECTORY/entitlements.plist"
ACTUAL_INFO_PLIST="$TEMP_DIRECTORY/Info.plist"

echo "Validating $SIGNATURE_MODE code signature..."
codesign --verify --strict --verbose=4 "$BINARY_PATH"

SIGNATURE_DETAILS="$(codesign --display --verbose=4 "$BINARY_PATH" 2>&1)"
grep -Eq '^Identifier=io[.]github[.]unixfg[.]eventkitcontrol$' \
    <<<"$SIGNATURE_DETAILS" \
    || fail "code signature has the wrong identifier"
grep -Eq 'flags=.*\([^)]*runtime' <<<"$SIGNATURE_DETAILS" \
    || fail "code signature does not enable Hardened Runtime"

if [[ "$SIGNATURE_MODE" == "ad-hoc" ]]; then
    grep -Eq '^Signature=adhoc$' <<<"$SIGNATURE_DETAILS" \
        || fail "expected an ad-hoc signature"
else
    grep -Eq '^Authority=Developer ID Application:' <<<"$SIGNATURE_DETAILS" \
        || fail "signature is not from a Developer ID Application certificate"
    grep -Eq "^TeamIdentifier=${EXPECTED_TEAM_ID}$" <<<"$SIGNATURE_DETAILS" \
        || fail "signature TeamIdentifier does not match the expected team"
    grep -Eq '^Timestamp=' <<<"$SIGNATURE_DETAILS" \
        || fail "Developer ID signature has no secure timestamp"
    if grep -Eq '^Signed Time=' <<<"$SIGNATURE_DETAILS"; then
        fail "Developer ID signature reports Signed Time instead of a secure timestamp"
    fi

    DESIGNATED_REQUIREMENT="=anchor apple generic and identifier \"io.github.unixfg.eventkitcontrol\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"${EXPECTED_TEAM_ID}\""
    codesign --verify --strict --verbose=4 -R "$DESIGNATED_REQUIREMENT" "$BINARY_PATH"
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
    print(
        "error: signed entitlements differ from eventkitcontrol.entitlements",
        file=sys.stderr,
    )
    print(f"expected: {expected!r}", file=sys.stderr)
    print(f"actual:   {actual!r}", file=sys.stderr)
    raise SystemExit(1)

if actual.get("com.apple.security.get-task-allow"):
    print("error: release entitlement get-task-allow must not be enabled", file=sys.stderr)
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
    "NSRemindersFullAccessUsageDescription",
}
forbidden_keys = {
    "NSCalendarsUsageDescription",
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

superseded = sorted(forbidden_keys & actual.keys())
if superseded:
    print(
        f"error: embedded Info.plist contains superseded keys: {', '.join(superseded)}",
        file=sys.stderr,
    )
    raise SystemExit(1)

for key in required_keys:
    if not isinstance(actual[key], str) or not actual[key].strip():
        print(f"error: embedded Info.plist key {key} must be a non-empty string", file=sys.stderr)
        raise SystemExit(1)

expected_identity = {
    "CFBundleExecutable": "eventkitcontrol",
    "CFBundleIdentifier": "io.github.unixfg.eventkitcontrol",
    "CFBundleName": "eventkitcontrol",
}
for key, expected_value in expected_identity.items():
    if actual[key] != expected_value:
        print(
            f"error: embedded Info.plist key {key} is {actual[key]!r}; "
            f"expected {expected_value!r}",
            file=sys.stderr,
        )
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
        14|14.0|14.0.0) ;;
        *) fail "unexpected minimum macOS version: $minimum_version (expected 14.0)" ;;
    esac
done <<<"$MINIMUM_VERSIONS"

echo "Artifact validation passed: eventkitcontrol $PLIST_VERSION, ARM64, macOS 14.0+."
