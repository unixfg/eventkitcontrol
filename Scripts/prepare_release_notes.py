#!/usr/bin/env python3
"""Extract one dated changelog entry and prepend it to release install notes."""

from __future__ import annotations

import argparse
import datetime
import pathlib
import re
import sys


HEADING = re.compile(r"^## ([^ ]+) - (.+)$")
REFERENCE_DEFINITION = re.compile(r"^\[[^]]+\]:[ \t]+\S.*$")
SEMANTIC_VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
ISO_DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


def extract_release_entry(changelog: str, version: str) -> str:
    """Return one version body plus any document-level reference definitions."""
    if SEMANTIC_VERSION.fullmatch(version) is None:
        raise ValueError(f"release version is not canonical semantic versioning: {version}")

    lines = changelog.splitlines()
    entries: list[tuple[int, str]] = []
    for index, line in enumerate(lines):
        match = HEADING.fullmatch(line)
        if match and match.group(1) == version:
            entries.append((index, match.group(2)))

    if len(entries) != 1:
        raise ValueError(
            f"CHANGELOG.md must contain exactly one entry for {version}; "
            f"found {len(entries)}"
        )

    start, release_date = entries[0]
    if ISO_DATE.fullmatch(release_date) is None:
        raise ValueError(
            f"changelog entry for {version} must replace Unreleased with an ISO date"
        )
    try:
        datetime.date.fromisoformat(release_date)
    except ValueError as error:
        raise ValueError(f"invalid changelog date for {version}: {error}") from error

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break

    body = "\n".join(lines[start + 1 : end]).strip()
    if not body:
        raise ValueError(f"changelog entry for {version} is empty")

    body_lines = set(body.splitlines())
    missing_definitions = [
        line
        for line in lines
        if REFERENCE_DEFINITION.fullmatch(line) and line not in body_lines
    ]
    if missing_definitions:
        body += "\n\n" + "\n".join(missing_definitions)
    return body


def render_release_notes(
    changelog_entry: str,
    repository: str,
    tag: str,
    package: str,
    checksum: str,
) -> str:
    install = f"""## Install

Download both files, verify the checksum, and run the signed installer:

```bash
curl -fLO "https://github.com/{repository}/releases/download/{tag}/{package}"
curl -fLO "https://github.com/{repository}/releases/download/{tag}/{checksum}"
shasum -a 256 -c "{checksum}"
sudo installer -pkg "{package}" -target /
eventkitcontrol --version
```

The package is Apple Silicon-only, Developer ID signed, notarized,
stapled for offline Gatekeeper validation, and installs
`eventkitcontrol` at `/usr/local/bin/eventkitcontrol`. After the checksum passes,
you may double-click the `.pkg` in Finder instead of using the command-line
installer."""
    return f"## What changed\n\n{changelog_entry}\n\n{install}\n"


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--changelog", required=True, type=pathlib.Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--checksum", required=True)
    return parser.parse_args()


def main() -> int:
    options = arguments()
    try:
        changelog = options.changelog.read_text(encoding="utf-8")
        entry = extract_release_entry(changelog, options.version)
        notes = render_release_notes(
            entry,
            options.repository,
            options.tag,
            options.package,
            options.checksum,
        )
        if options.output.exists() or options.output.is_symlink():
            raise ValueError(f"refusing to replace release-note output: {options.output}")
        options.output.write_text(notes, encoding="utf-8")
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
