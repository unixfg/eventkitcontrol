import pathlib
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "Scripts"))

from prepare_release_notes import extract_release_entry, render_release_notes


class ReleaseNotesTests(unittest.TestCase):
    def test_extracts_only_requested_entry_and_global_references(self):
        changelog = """# Changelog

## 1.1.0 - 2026-09-01

New behavior with [context][fork-point].

## 1.0.0 - 2026-08-31

Old behavior.

[fork-point]: https://example.invalid/commit
"""
        entry = extract_release_entry(changelog, "1.1.0")
        self.assertIn("New behavior", entry)
        self.assertIn("[fork-point]: https://example.invalid/commit", entry)
        self.assertNotIn("Old behavior", entry)

    def test_rejects_unreleased_entry(self):
        with self.assertRaisesRegex(ValueError, "must replace Unreleased"):
            extract_release_entry("## 1.0.0 - Unreleased\n\nDetails.\n", "1.0.0")

    def test_rejects_invalid_calendar_date(self):
        with self.assertRaisesRegex(ValueError, "invalid changelog date"):
            extract_release_entry("## 1.0.0 - 2026-02-30\n\nDetails.\n", "1.0.0")

    def test_rejects_duplicate_version_entries(self):
        changelog = """## 1.0.0 - 2026-08-31

First.

## 1.0.0 - 2026-09-01

Second.
"""
        with self.assertRaisesRegex(ValueError, "exactly one entry"):
            extract_release_entry(changelog, "1.0.0")

    def test_renders_changelog_and_exact_install_assets(self):
        notes = render_release_notes(
            "### Fixed\n\n- A serious bug.",
            "unixfg/eventkitcontrol",
            "v1.0.0",
            "eventkitcontrol-v1.0.0-macos-arm64.pkg",
            "eventkitcontrol-v1.0.0-macos-arm64.pkg.sha256",
        )
        self.assertTrue(notes.startswith("## What changed\n"))
        self.assertIn("A serious bug", notes)
        self.assertIn("## Install", notes)
        self.assertIn(
            "unixfg/eventkitcontrol/releases/download/v1.0.0/"
            "eventkitcontrol-v1.0.0-macos-arm64.pkg",
            notes,
        )
        self.assertIn("eventkitcontrol-v1.0.0-macos-arm64.pkg.sha256", notes)
        self.assertIn("double-click the `.pkg`", notes)

    def test_initial_release_scope_keeps_safety_rationale_in_release_notes(self):
        changelog = (PROJECT_ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        entry = extract_release_entry(changelog, "1.0.2")
        self.assertIn("round-trip paradox", entry)
        self.assertIn("`--travel-time`", entry)
        self.assertIn("the original project", entry)

    def test_command_writes_release_notes_from_a_dated_entry(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = pathlib.Path(directory)
            changelog = directory_path / "CHANGELOG.md"
            output = directory_path / "notes.md"
            changelog.write_text(
                "## 1.0.0 - 2026-08-31\n\n"
                "### Fixed\n\n- Round-trip paradox fixed.\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(PROJECT_ROOT / "Scripts" / "prepare_release_notes.py"),
                    "--changelog",
                    str(changelog),
                    "--version",
                    "1.0.0",
                    "--output",
                    str(output),
                    "--repository",
                    "unixfg/eventkitcontrol",
                    "--tag",
                    "v1.0.0",
                    "--package",
                    "eventkitcontrol-v1.0.0-macos-arm64.pkg",
                    "--checksum",
                    "eventkitcontrol-v1.0.0-macos-arm64.pkg.sha256",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Round-trip paradox fixed", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
