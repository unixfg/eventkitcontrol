#!/bin/bash
# Build and validate a product archive that installs eventkitcontrol at
# /usr/local/bin/eventkitcontrol. Developer ID mode signs the outer archive for
# releases; unsigned mode exercises the same package structure in ordinary CI.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    fail "usage: $0 --signing-mode unsigned|developer-id [signing options] --output PACKAGE /path/to/eventkitcontrol"
}

SIGNING_MODE=""
EXPECTED_TEAM_ID=""
INSTALLER_IDENTITY=""
KEYCHAIN_PATH=""
REQUESTED_OUTPUT=""
BINARY_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --signing-mode)
            [[ $# -ge 2 ]] || usage
            SIGNING_MODE="$2"
            shift 2
            ;;
        --team-id)
            [[ $# -ge 2 ]] || usage
            EXPECTED_TEAM_ID="$2"
            shift 2
            ;;
        --installer-identity)
            [[ $# -ge 2 ]] || usage
            INSTALLER_IDENTITY="$2"
            shift 2
            ;;
        --keychain)
            [[ $# -ge 2 ]] || usage
            KEYCHAIN_PATH="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || usage
            REQUESTED_OUTPUT="$2"
            shift 2
            ;;
        --help|-h)
            echo "usage: $0 --signing-mode unsigned|developer-id [signing options] --output PACKAGE /path/to/eventkitcontrol"
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

case "$SIGNING_MODE" in
    unsigned)
        [[ -z "$EXPECTED_TEAM_ID" && -z "$INSTALLER_IDENTITY" && -z "$KEYCHAIN_PATH" ]] \
            || fail "Developer ID options cannot be used with unsigned package mode"
        ;;
    developer-id)
        [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
            || fail "developer-id mode requires a 10-character --team-id"
        [[ "$INSTALLER_IDENTITY" == "Developer ID Installer: "*"(${EXPECTED_TEAM_ID})" ]] \
            || fail "installer identity does not match the expected certificate type and team"
        [[ "$KEYCHAIN_PATH" == /* && -f "$KEYCHAIN_PATH" && ! -L "$KEYCHAIN_PATH" ]] \
            || fail "--keychain must name an absolute regular file"
        ;;
    *) fail "--signing-mode must be unsigned or developer-id" ;;
esac
[[ -n "$REQUESTED_OUTPUT" && -n "$BINARY_PATH" ]] || usage
[[ -f "$BINARY_PATH" && -x "$BINARY_PATH" && ! -L "$BINARY_PATH" ]] \
    || fail "input binary is not a regular executable: $BINARY_PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

for required_command in awk cat find grep install mktemp mv pkgbuild pkgutil productbuild rm tr wc; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command not found: $required_command"
done

if [[ "$REQUESTED_OUTPUT" == /* ]]; then
    PACKAGE_PATH="$REQUESTED_OUTPUT"
else
    PACKAGE_PATH="$PROJECT_ROOT/$REQUESTED_OUTPUT"
fi
[[ "$PACKAGE_PATH" == *.pkg ]] || fail "package output must end in .pkg"
[[ ! -e "$PACKAGE_PATH" && ! -L "$PACKAGE_PATH" ]] \
    || fail "refusing to replace existing package output: $PACKAGE_PATH"

OUTPUT_PARENT="$(dirname -- "$PACKAGE_PATH")"
[[ -d "$OUTPUT_PARENT" && ! -L "$OUTPUT_PARENT" ]] \
    || fail "package output parent must be an existing real directory"
OUTPUT_PARENT_PHYSICAL="$(cd -- "$OUTPUT_PARENT" && pwd -P)"
case "$OUTPUT_PARENT_PHYSICAL/" in
    "$PROJECT_ROOT/"*) ;;
    *) fail "package output must remain inside the repository" ;;
esac

if [[ "$SIGNING_MODE" == "unsigned" ]]; then
    "$SCRIPT_DIR/validate-artifact.sh" --signature ad-hoc "$BINARY_PATH"
else
    "$SCRIPT_DIR/validate-artifact.sh" \
        --signature developer-id \
        --team-id "$EXPECTED_TEAM_ID" \
        "$BINARY_PATH"
fi

VERSION="$("$BINARY_PATH" --version | awk 'NF { print $NF; exit }')"
[[ "$VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
    || fail "binary returned an invalid package version: $VERSION"

TEMP_DIRECTORY="$(mktemp -d "$OUTPUT_PARENT_PHYSICAL/.eventkitcontrol-package-build.XXXXXX")"
cleanup() {
    if [[ -n "${TEMP_DIRECTORY:-}" \
        && "$TEMP_DIRECTORY" == "$OUTPUT_PARENT_PHYSICAL"/.eventkitcontrol-package-build.* \
        && -d "$TEMP_DIRECTORY" \
        && ! -L "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi
}
trap cleanup EXIT

PAYLOAD_ROOT="$TEMP_DIRECTORY/payload"
COMPONENT_PACKAGE="$TEMP_DIRECTORY/eventkitcontrol-component.pkg"
DISTRIBUTION_PATH="$TEMP_DIRECTORY/Distribution.xml"
STAGED_PACKAGE="$TEMP_DIRECTORY/eventkitcontrol-product.pkg"

install -d -m 0755 "$PAYLOAD_ROOT"
install -m 0755 "$BINARY_PATH" "$PAYLOAD_ROOT/eventkitcontrol"

[[ "$(find "$PAYLOAD_ROOT" -type f | wc -l | tr -d ' ')" == "1" ]] \
    || fail "package payload contains unexpected files"
if find "$PAYLOAD_ROOT" -type l -print -quit | grep -q .; then
    fail "package payload must not contain symbolic links"
fi

pkgbuild \
    --root "$PAYLOAD_ROOT" \
    --identifier io.github.unixfg.eventkitcontrol.pkg \
    --version "$VERSION" \
    --install-location /usr/local/bin \
    --ownership recommended \
    --min-os-version 14.0 \
    "$COMPONENT_PACKAGE"

COMPONENT_SIGNATURE="$(LC_ALL=C pkgutil --check-signature "$COMPONENT_PACKAGE" 2>&1 || true)"
grep -Fq "Status: no signature" <<<"$COMPONENT_SIGNATURE" \
    || fail "component package must be unsigned; only the outer product may be signed"

cat >"$DISTRIBUTION_PATH" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>eventkitcontrol</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <volume-check script="true">
    <allowed-os-versions>
      <os-version min="14.0"/>
    </allowed-os-versions>
  </volume-check>
  <choices-outline>
    <line choice="io.github.unixfg.eventkitcontrol.pkg"/>
  </choices-outline>
  <choice id="io.github.unixfg.eventkitcontrol.pkg" visible="false" title="eventkitcontrol">
    <pkg-ref id="io.github.unixfg.eventkitcontrol.pkg"/>
  </choice>
  <pkg-ref id="io.github.unixfg.eventkitcontrol.pkg" version="$VERSION" onConclusion="none">eventkitcontrol-component.pkg</pkg-ref>
</installer-gui-script>
EOF

PRODUCTBUILD_OPTIONS=(
    --identifier io.github.unixfg.eventkitcontrol
    --version "$VERSION"
    --distribution "$DISTRIBUTION_PATH"
    --package-path "$TEMP_DIRECTORY"
)
if [[ "$SIGNING_MODE" == "developer-id" ]]; then
    PRODUCTBUILD_OPTIONS+=(
        --sign "$INSTALLER_IDENTITY"
        --keychain "$KEYCHAIN_PATH"
        --timestamp
    )
fi
productbuild "${PRODUCTBUILD_OPTIONS[@]}" "$STAGED_PACKAGE"

if [[ "$SIGNING_MODE" == "unsigned" ]]; then
    "$SCRIPT_DIR/validate-package.sh" \
        --signature unsigned \
        "$STAGED_PACKAGE" \
        "$BINARY_PATH"
else
    "$SCRIPT_DIR/validate-package.sh" \
        --signature developer-id \
        --team-id "$EXPECTED_TEAM_ID" \
        --installer-identity "$INSTALLER_IDENTITY" \
        "$STAGED_PACKAGE" \
        "$BINARY_PATH"
fi

mv -- "$STAGED_PACKAGE" "$PACKAGE_PATH"
echo "Package build complete: $PACKAGE_PATH"
