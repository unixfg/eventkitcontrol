#!/bin/bash
# Validate a product archive and prove its single component contains only the
# exact eventkitcontrol executable expected by the selected signing mode.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() {
    echo "error: $*" >&2
    exit 1
}

usage() {
    fail "usage: $0 --signature unsigned|developer-id [identity options] /path/to/package.pkg /path/to/eventkitcontrol"
}

SIGNATURE_MODE=""
EXPECTED_TEAM_ID=""
INSTALLER_IDENTITY=""
PACKAGE_PATH=""
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
        --installer-identity)
            [[ $# -ge 2 ]] || usage
            INSTALLER_IDENTITY="$2"
            shift 2
            ;;
        --help|-h)
            echo "usage: $0 --signature unsigned|developer-id [identity options] /path/to/package.pkg /path/to/eventkitcontrol"
            exit 0
            ;;
        --*) usage ;;
        *)
            if [[ -z "$PACKAGE_PATH" ]]; then
                PACKAGE_PATH="$1"
            elif [[ -z "$BINARY_PATH" ]]; then
                BINARY_PATH="$1"
            else
                usage
            fi
            shift
            ;;
    esac
done

case "$SIGNATURE_MODE" in
    unsigned)
        [[ -z "$EXPECTED_TEAM_ID" && -z "$INSTALLER_IDENTITY" ]] \
            || fail "identity options cannot be used with unsigned package validation"
        ;;
    developer-id)
        [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
            || fail "developer-id validation requires a 10-character --team-id"
        [[ "$INSTALLER_IDENTITY" == "Developer ID Installer: "*"(${EXPECTED_TEAM_ID})" ]] \
            || fail "installer identity does not match the expected certificate type and team"
        ;;
    *) fail "--signature must be unsigned or developer-id" ;;
esac
[[ -n "$PACKAGE_PATH" && -n "$BINARY_PATH" ]] || usage
[[ -f "$PACKAGE_PATH" && ! -L "$PACKAGE_PATH" ]] \
    || fail "package is not a regular file: $PACKAGE_PATH"
[[ -f "$BINARY_PATH" && -x "$BINARY_PATH" && ! -L "$BINARY_PATH" ]] \
    || fail "reference binary is not a regular executable: $BINARY_PATH"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

for required_command in awk find grep lsbom mktemp pkgutil python3 rm shasum; do
    command -v "$required_command" >/dev/null 2>&1 \
        || fail "required command not found: $required_command"
done

if [[ "$SIGNATURE_MODE" == "unsigned" ]]; then
    "$SCRIPT_DIR/validate-artifact.sh" --signature ad-hoc "$BINARY_PATH"
    echo "Validating deliberately unsigned CI package..."
    PACKAGE_SIGNATURE="$(LC_ALL=C pkgutil --check-signature "$PACKAGE_PATH" 2>&1 || true)"
    grep -Fq "Status: no signature" <<<"$PACKAGE_SIGNATURE" \
        || fail "unsigned package did not report the expected no-signature status"
else
    "$SCRIPT_DIR/validate-artifact.sh" \
        --signature developer-id \
        --team-id "$EXPECTED_TEAM_ID" \
        "$BINARY_PATH"
    echo "Validating Developer ID Installer signature..."
    PACKAGE_SIGNATURE="$(LC_ALL=C pkgutil --check-signature "$PACKAGE_PATH" 2>&1)"
    grep -Fq "$INSTALLER_IDENTITY" <<<"$PACKAGE_SIGNATURE" \
        || fail "package signature does not use the expected Installer identity"
    grep -Fq "Signed with a trusted timestamp" <<<"$PACKAGE_SIGNATURE" \
        || fail "package signature has no trusted timestamp"
fi

REFERENCE_VERSION="$("$BINARY_PATH" --version | awk 'NF { print $NF; exit }')"
[[ "$REFERENCE_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] \
    || fail "reference binary returned an invalid version: $REFERENCE_VERSION"

TEMP_DIRECTORY="$(mktemp -d /private/tmp/eventkitcontrol-package-validate.XXXXXX)"
cleanup() {
    if [[ -n "${TEMP_DIRECTORY:-}" \
        && "$TEMP_DIRECTORY" == /private/tmp/eventkitcontrol-package-validate.* \
        && -d "$TEMP_DIRECTORY" \
        && ! -L "$TEMP_DIRECTORY" ]]; then
        rm -rf -- "$TEMP_DIRECTORY"
    fi
}
trap cleanup EXIT

OUTER_PACKAGE="$TEMP_DIRECTORY/outer"
pkgutil --expand-full "$PACKAGE_PATH" "$OUTER_PACKAGE"

DISTRIBUTION_PATH="$OUTER_PACKAGE/Distribution"
COMPONENT_DIRECTORY="$OUTER_PACKAGE/eventkitcontrol-component.pkg"
[[ -f "$DISTRIBUTION_PATH" && ! -L "$DISTRIBUTION_PATH" ]] \
    || fail "product archive does not contain one regular Distribution file"
[[ -d "$COMPONENT_DIRECTORY" && ! -L "$COMPONENT_DIRECTORY" ]] \
    || fail "product archive does not contain the expected expanded component"

python3 - "$OUTER_PACKAGE" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
actual = {entry.name for entry in root.iterdir()}
expected = {"Distribution", "eventkitcontrol-component.pkg"}
if actual != expected:
    print(
        f"error: product archive entries were {sorted(actual)!r}; "
        f"expected {sorted(expected)!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

echo "Validating product distribution constraints..."
python3 - "$DISTRIBUTION_PATH" "$REFERENCE_VERSION" <<'PY'
import sys
import xml.etree.ElementTree as ET

distribution_path, expected_version = sys.argv[1:]
root = ET.parse(distribution_path).getroot()

def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)

def exactly_one(parent, tag):
    matches = parent.findall(tag)
    if len(matches) != 1:
        fail(f"Distribution must contain exactly one {tag}; found {len(matches)}")
    return matches[0]

if root.tag != "installer-gui-script" or root.attrib.get("minSpecVersion") != "2":
    fail("Distribution must be an installer-gui-script with minSpecVersion 2")

allowed_top_level = {
    "title",
    "options",
    "domains",
    "volume-check",
    "choices-outline",
    "choice",
    "pkg-ref",
    "product",
}
unexpected = [child.tag for child in root if child.tag not in allowed_top_level]
if unexpected:
    fail(f"Distribution contains unexpected top-level elements: {unexpected!r}")

title = exactly_one(root, "title")
if (title.text or "").strip() != "eventkitcontrol" or title.attrib:
    fail("Distribution title is not exactly eventkitcontrol")

options = exactly_one(root, "options")
expected_options = {
    "customize": "never",
    "require-scripts": "false",
    "hostArchitectures": "arm64",
}
if options.attrib != expected_options or list(options):
    fail(f"Distribution options were {options.attrib!r}; expected {expected_options!r}")

domains = exactly_one(root, "domains")
expected_domains = {
    "enable_anywhere": "false",
    "enable_currentUserHome": "false",
    "enable_localSystem": "true",
}
if domains.attrib != expected_domains or list(domains):
    fail(f"Distribution domains were {domains.attrib!r}; expected {expected_domains!r}")

volume_check = exactly_one(root, "volume-check")
if volume_check.attrib != {"script": "true"}:
    fail("Distribution volume-check must use only the literal script=true predicate")
allowed_versions = exactly_one(volume_check, "allowed-os-versions")
if len(list(volume_check)) != 1 or allowed_versions.attrib:
    fail("Distribution volume-check contains unexpected requirements")
os_version = exactly_one(allowed_versions, "os-version")
if len(list(allowed_versions)) != 1 or os_version.attrib != {"min": "14.0"}:
    fail("Distribution must require exactly macOS 14.0 or later")

outline = exactly_one(root, "choices-outline")
lines = outline.findall("line")
if outline.attrib or len(lines) != 1 or list(lines[0]):
    fail("Distribution choices outline must contain exactly one leaf choice")
if lines[0].attrib != {"choice": "io.github.unixfg.eventkitcontrol.pkg"}:
    fail("Distribution choices outline refers to the wrong component")

choices = root.findall("choice")
if len(choices) != 1:
    fail(f"Distribution must contain exactly one choice; found {len(choices)}")
choice = choices[0]
expected_choice = {
    "id": "io.github.unixfg.eventkitcontrol.pkg",
    "visible": "false",
    "title": "eventkitcontrol",
}
if choice.attrib != expected_choice:
    fail(f"Distribution choice was {choice.attrib!r}; expected {expected_choice!r}")
choice_refs = choice.findall("pkg-ref")
if len(choice_refs) != 1 or len(list(choice)) != 1:
    fail("Distribution choice must contain exactly one package reference")
choice_ref = choice_refs[0]
if choice_ref.attrib != {"id": "io.github.unixfg.eventkitcontrol.pkg"}:
    fail("Distribution choice package reference has the wrong identifier")
if list(choice_ref) or (choice_ref.text or "").strip():
    fail("Distribution choice package reference must not contain content")

package_refs = root.findall("pkg-ref")
if not package_refs:
    fail("Distribution must contain a top-level package reference")

# productbuild may split one logical package reference across multiple
# top-level pkg-ref elements with the same ID. Distribution semantics collapse
# their attributes together; exactly one element supplies the package URL.
allowed_package_attributes = {
    "id",
    "version",
    "auth",
    "installKBytes",
    "updateKBytes",
    "onConclusion",
}
package_attributes = {}
package_locations = []
for package_ref in package_refs:
    if package_ref.attrib.get("id") != "io.github.unixfg.eventkitcontrol.pkg":
        fail("Distribution contains a package reference with the wrong identifier")
    if list(package_ref):
        fail("Distribution package reference unexpectedly contains child elements")

    extra_package_attributes = set(package_ref.attrib) - allowed_package_attributes
    if extra_package_attributes:
        fail(
            "Distribution package reference has unexpected attributes: "
            f"{sorted(extra_package_attributes)!r}"
        )

    for key, value in package_ref.attrib.items():
        previous = package_attributes.get(key)
        if previous is not None and previous != value:
            fail(f"Distribution package reference has conflicting {key} attributes")
        package_attributes[key] = value

    location = (package_ref.text or "").strip()
    if location:
        package_locations.append(location)

required_package_attributes = {
    "id": "io.github.unixfg.eventkitcontrol.pkg",
    "version": expected_version,
}
for key, value in required_package_attributes.items():
    if package_attributes.get(key) != value:
        fail(
            f"Distribution package reference {key} is "
            f"{package_attributes.get(key)!r}; expected {value!r}"
        )
if package_attributes.get("onConclusion", "").lower() != "none":
    fail("Distribution package reference must not require logout, restart, or shutdown")
if "auth" in package_attributes and package_attributes["auth"].lower() != "root":
    fail("Distribution package reference must require root authorization when auth is present")
install_kbytes = package_attributes.get("installKBytes")
if install_kbytes is None or not install_kbytes.isdigit() or int(install_kbytes) <= 0:
    fail("Distribution package reference has an invalid installKBytes value")
update_kbytes = package_attributes.get("updateKBytes")
if update_kbytes is not None and not update_kbytes.isdigit():
    fail("Distribution package reference has an invalid updateKBytes value")
if package_locations != ["#eventkitcontrol-component.pkg"]:
    fail("Distribution package reference does not point to the embedded component")

products = root.findall("product")
if len(products) > 1:
    fail("Distribution contains more than one product identity")
if products:
    expected_product = {
        "id": "io.github.unixfg.eventkitcontrol",
        "version": expected_version,
    }
    if products[0].attrib != expected_product or list(products[0]):
        fail(f"Distribution product identity was {products[0].attrib!r}; expected {expected_product!r}")
PY

PAYLOAD_LIST="$TEMP_DIRECTORY/payload-files.txt"
pkgutil --payload-files "$PACKAGE_PATH" >"$PAYLOAD_LIST"

python3 - "$PAYLOAD_LIST" <<'PY'
import pathlib
import sys

allowed = {
    "",
    ".",
    "eventkitcontrol",
}
actual = set()

for raw_line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    path = raw_line.strip()
    if path.startswith("/"):
        print(f"error: unsafe package payload path: {raw_line!r}", file=sys.stderr)
        raise SystemExit(1)
    while path.startswith("./"):
        path = path[2:]
    if path.startswith("/"):
        print(f"error: unsafe package payload path: {raw_line!r}", file=sys.stderr)
        raise SystemExit(1)
    path = path.rstrip("/")
    if ".." in pathlib.PurePosixPath(path).parts:
        print(f"error: unsafe package payload path: {raw_line!r}", file=sys.stderr)
        raise SystemExit(1)
    if path not in allowed:
        print(f"error: unexpected package payload path: {raw_line!r}", file=sys.stderr)
        raise SystemExit(1)
    actual.add(path)

if "eventkitcontrol" not in actual:
    print("error: package payload does not contain eventkitcontrol", file=sys.stderr)
    raise SystemExit(1)
PY

if find "$COMPONENT_DIRECTORY" -type d -name Scripts -print -quit | grep -q .; then
    fail "package unexpectedly contains installer scripts"
fi

python3 - "$COMPONENT_DIRECTORY" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
actual = {entry.name for entry in root.iterdir()}
expected = {"Bom", "PackageInfo", "Payload"}
if actual != expected:
    print(
        f"error: component package entries were {sorted(actual)!r}; "
        f"expected {sorted(expected)!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

PACKAGE_INFO="$COMPONENT_DIRECTORY/PackageInfo"
[[ -f "$PACKAGE_INFO" && ! -L "$PACKAGE_INFO" ]] \
    || fail "component package has no regular PackageInfo"

python3 - "$PACKAGE_INFO" "$REFERENCE_VERSION" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
expected = {
    "identifier": "io.github.unixfg.eventkitcontrol.pkg",
    "version": sys.argv[2],
    "install-location": "/usr/local/bin",
    "auth": "root",
}
for key, value in expected.items():
    if root.attrib.get(key) != value:
        print(
            f"error: PackageInfo {key} is {root.attrib.get(key)!r}; expected {value!r}",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY

EXTRACTED_BINARY="$COMPONENT_DIRECTORY/Payload/eventkitcontrol"
[[ -f "$EXTRACTED_BINARY" && -x "$EXTRACTED_BINARY" && ! -L "$EXTRACTED_BINARY" ]] \
    || fail "expanded package does not contain a regular executable payload"

REFERENCE_SHA256="$(shasum -a 256 "$BINARY_PATH" | awk '{print $1}')"
EXTRACTED_SHA256="$(shasum -a 256 "$EXTRACTED_BINARY" | awk '{print $1}')"
[[ "$REFERENCE_SHA256" == "$EXTRACTED_SHA256" ]] \
    || fail "packaged executable differs from the validated reference binary"

[[ -f "$COMPONENT_DIRECTORY/Bom" && ! -L "$COMPONENT_DIRECTORY/Bom" ]] \
    || fail "expanded component has no regular bill of materials"
BOM_DETAILS="$TEMP_DIRECTORY/bom-details.txt"
lsbom -p MUGf "$COMPONENT_DIRECTORY/Bom" >"$BOM_DETAILS"

python3 - "$BOM_DETAILS" <<'PY'
import pathlib
import sys

target = None
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    fields = line.split()
    if not fields:
        continue
    normalized_path = fields[-1]
    if normalized_path.startswith("/"):
        print(f"error: unsafe bill-of-materials path: {fields[-1]!r}", file=sys.stderr)
        raise SystemExit(1)
    while normalized_path.startswith("./"):
        normalized_path = normalized_path[2:]
    if normalized_path.startswith("/"):
        print(f"error: unsafe bill-of-materials path: {fields[-1]!r}", file=sys.stderr)
        raise SystemExit(1)
    normalized_path = normalized_path.rstrip("/")
    if normalized_path == ".":
        normalized_path = ""
    if ".." in pathlib.PurePosixPath(normalized_path).parts:
        print(f"error: unsafe bill-of-materials path: {fields[-1]!r}", file=sys.stderr)
        raise SystemExit(1)
    if normalized_path not in {"", "eventkitcontrol"}:
        print(f"error: unexpected bill-of-materials path: {fields[-1]!r}", file=sys.stderr)
        raise SystemExit(1)
    if normalized_path == "eventkitcontrol":
        target = fields

if target is None:
    print("error: bill of materials has no eventkitcontrol entry", file=sys.stderr)
    raise SystemExit(1)

if len(target) < 4 or target[0] != "-rwxr-xr-x" or target[1:3] != ["root", "wheel"]:
    print(
        "error: eventkitcontrol payload must be mode 0755 and owned by root:wheel; "
        f"BOM entry was {target!r}",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

if [[ "$SIGNATURE_MODE" == "unsigned" ]]; then
    "$SCRIPT_DIR/validate-artifact.sh" --signature ad-hoc "$EXTRACTED_BINARY"
else
    "$SCRIPT_DIR/validate-artifact.sh" \
        --signature developer-id \
        --team-id "$EXPECTED_TEAM_ID" \
        "$EXTRACTED_BINARY"
fi

echo "Package validation passed: $SIGNATURE_MODE product, ARM64, macOS 14.0+, one root:wheel 0755 payload."
