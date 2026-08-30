#!/bin/bash
# Validate the SwiftPM v3 lockfile origin hash for this single-root package.

set -Eeuo pipefail
IFS=$'\n\t'
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

fail() {
    echo "error: $*" >&2
    exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

command -v python3 >/dev/null 2>&1 \
    || fail "required command not found: python3"

python3 - "$PROJECT_ROOT/Package.swift" "$PROJECT_ROOT/Package.resolved" <<'PY'
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1])
lockfile_path = pathlib.Path(sys.argv[2])

try:
    lockfile = json.loads(lockfile_path.read_text())
except Exception as error:
    print(f"error: could not parse Package.resolved: {error}", file=sys.stderr)
    raise SystemExit(1)

if not isinstance(lockfile, dict):
    print("error: Package.resolved must contain a top-level object", file=sys.stderr)
    raise SystemExit(1)
if lockfile.get("version") != 3:
    print(
        f"error: Package.resolved schema is {lockfile.get('version')!r}; expected 3",
        file=sys.stderr,
    )
    raise SystemExit(1)

expected_hash = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
actual_hash = lockfile.get("originHash")
if actual_hash != expected_hash:
    print(
        f"error: Package.resolved originHash is {actual_hash!r}; "
        f"expected SHA-256(Package.swift) {expected_hash}",
        file=sys.stderr,
    )
    raise SystemExit(1)

print("SwiftPM lockfile validation passed: schema v3 and current manifest origin hash.")
PY
