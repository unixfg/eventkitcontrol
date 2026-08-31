import json
import pathlib
import stat
import sys
import tempfile
import unittest
from unittest import mock


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "Scripts"))

import manage_keychain_search_list as keychains


class KeychainSearchListTests(unittest.TestCase):
    def test_parses_quoted_paths_without_splitting_spaces(self):
        output = (
            '    "/Users/runner/Library/Keychains/login.keychain-db"\n'
            '    "/Users/runner/Library/Keychains/a keychain.keychain-db"\n'
        )
        self.assertEqual(
            keychains.parse_search_list(output),
            [
                "/Users/runner/Library/Keychains/login.keychain-db",
                "/Users/runner/Library/Keychains/a keychain.keychain-db",
            ],
        )

    def test_rejects_multiple_unquoted_paths_on_one_line(self):
        with self.assertRaisesRegex(ValueError, "invalid keychain search-list entry"):
            keychains.parse_search_list("/first /second\n")

    @mock.patch.object(keychains.subprocess, "run")
    def test_snapshot_is_exclusive_private_json(self, run):
        run.return_value = mock.Mock(
            stdout='    "/Users/runner/Library/Keychains/login.keychain-db"\n'
        )
        with tempfile.TemporaryDirectory() as directory:
            backup = pathlib.Path(directory) / "keychains.json"
            keychains.snapshot(backup, "/tmp/release.keychain-db")

            self.assertEqual(
                json.loads(backup.read_text(encoding="utf-8")),
                ["/Users/runner/Library/Keychains/login.keychain-db"],
            )
            self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
            with self.assertRaisesRegex(ValueError, "refusing to replace"):
                keychains.snapshot(backup, "/tmp/release.keychain-db")

    @mock.patch.object(keychains.subprocess, "run")
    def test_prepend_uses_distinct_arguments_and_verifies_order(self, run):
        original = "/Users/runner/Library/Keychains/login keychain.keychain-db"
        signing = "/tmp/release.keychain-db"
        run.side_effect = [
            mock.Mock(returncode=0),
            mock.Mock(stdout=f'    "{signing}"\n    "{original}"\n'),
        ]
        with tempfile.TemporaryDirectory() as directory:
            backup = pathlib.Path(directory) / "keychains.json"
            backup.write_text(json.dumps([original]), encoding="utf-8")
            keychains.prepend(backup, signing)

        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                "/usr/bin/security",
                "list-keychains",
                "-d",
                "user",
                "-s",
                signing,
                original,
            ],
        )

    @mock.patch.object(keychains.subprocess, "run")
    def test_restore_uses_saved_order_and_verifies_result(self, run):
        original = ["/first.keychain-db", "/second keychain.keychain-db"]
        signing = "/tmp/release.keychain-db"
        run.side_effect = [
            mock.Mock(returncode=0),
            mock.Mock(stdout='    "/first.keychain-db"\n    "/second keychain.keychain-db"\n'),
        ]
        with tempfile.TemporaryDirectory() as directory:
            backup = pathlib.Path(directory) / "keychains.json"
            backup.write_text(json.dumps(original), encoding="utf-8")
            keychains.restore(backup, signing)

        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                "/usr/bin/security",
                "list-keychains",
                "-d",
                "user",
                "-s",
                *original,
            ],
        )

    @mock.patch.object(keychains.subprocess, "run")
    def test_rejects_search_list_that_was_not_applied_exactly(self, run):
        run.side_effect = [
            mock.Mock(returncode=0),
            mock.Mock(stdout='    "/different.keychain-db"\n'),
        ]
        with self.assertRaisesRegex(ValueError, "did not preserve"):
            keychains.replace_search_list(["/requested.keychain-db"])

    def test_rejects_backup_that_contains_signing_keychain(self):
        signing = "/tmp/release.keychain-db"
        with tempfile.TemporaryDirectory() as directory:
            backup = pathlib.Path(directory) / "keychains.json"
            backup.write_text(json.dumps([signing]), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "contains the signing keychain"):
                keychains.load_backup(backup, signing)

    def test_rejects_symlink_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            directory_path = pathlib.Path(directory)
            target = directory_path / "target.json"
            target.write_text("[]", encoding="utf-8")
            backup = directory_path / "backup.json"
            backup.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "not a regular file"):
                keychains.load_backup(backup, "/tmp/release.keychain-db")


if __name__ == "__main__":
    unittest.main()
