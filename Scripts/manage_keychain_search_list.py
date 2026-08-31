#!/usr/bin/env python3
"""Safely save, extend, and restore the macOS user keychain search list."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import stat
import subprocess
import sys
from collections.abc import Sequence


SECURITY = "/usr/bin/security"


def parse_search_list(output: str) -> list[str]:
    """Parse the quoted, one-path-per-line output from security."""
    keychains: list[str] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        values = shlex.split(line)
        if len(values) != 1 or not values[0]:
            raise ValueError("security returned an invalid keychain search-list entry")
        keychains.append(values[0])
    return keychains


def current_search_list() -> list[str]:
    result = subprocess.run(
        [SECURITY, "list-keychains", "-d", "user"],
        check=True,
        capture_output=True,
        text=True,
    )
    return parse_search_list(result.stdout)


def validate_saved_list(value: object, signing_keychain: str) -> list[str]:
    if not isinstance(value, list):
        raise ValueError("saved user keychain search list is not an array")
    if any(not isinstance(path, str) or not path for path in value):
        raise ValueError("saved user keychain search list contains an invalid path")
    if signing_keychain in value:
        raise ValueError("saved user keychain search list contains the signing keychain")
    return value


def load_backup(path: pathlib.Path, signing_keychain: str) -> list[str]:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode):
        raise ValueError("keychain search-list backup is not a regular file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"could not read keychain search-list backup: {error}") from error
    return validate_saved_list(value, signing_keychain)


def write_backup(
    path: pathlib.Path,
    keychains: Sequence[str],
    signing_keychain: str,
) -> None:
    validate_saved_list(list(keychains), signing_keychain)
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(list(keychains), output)
        output.write("\n")


def replace_search_list(keychains: Sequence[str]) -> None:
    subprocess.run(
        [SECURITY, "list-keychains", "-d", "user", "-s", *keychains],
        check=True,
    )
    actual = current_search_list()
    if actual != list(keychains):
        raise ValueError(
            "macOS did not preserve the requested user keychain search-list order"
        )


def snapshot(path: pathlib.Path, signing_keychain: str) -> None:
    if path.exists() or path.is_symlink():
        raise ValueError(f"refusing to replace keychain search-list backup: {path}")
    write_backup(path, current_search_list(), signing_keychain)


def prepend(path: pathlib.Path, signing_keychain: str) -> None:
    original = load_backup(path, signing_keychain)
    replace_search_list([signing_keychain, *original])


def restore(path: pathlib.Path, signing_keychain: str) -> None:
    replace_search_list(load_backup(path, signing_keychain))


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--output", required=True, type=pathlib.Path)
    snapshot_parser.add_argument("--keychain", required=True)

    for name in ("prepend", "restore"):
        command_parser = subparsers.add_parser(name)
        command_parser.add_argument("--backup", required=True, type=pathlib.Path)
        command_parser.add_argument("--keychain", required=True)

    return parser.parse_args()


def main() -> int:
    options = arguments()
    try:
        if options.command == "snapshot":
            snapshot(options.output, options.keychain)
        elif options.command == "prepend":
            prepend(options.backup, options.keychain)
        elif options.command == "restore":
            restore(options.backup, options.keychain)
        else:  # pragma: no cover - argparse constrains this value.
            raise ValueError(f"unsupported command: {options.command}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
