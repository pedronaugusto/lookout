#!/usr/bin/env python3
"""Bound a fake Zig cache without building or touching a user's cache."""

import pathlib
import subprocess
import tempfile
import unittest

CI = pathlib.Path(__file__).resolve().parent


class CacheTrim(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cache-test-")
        self.addCleanup(self.tmp.cleanup)
        self.cache = pathlib.Path(self.tmp.name) / "cache with spaces"
        for name in ("o", "h", "z", "tmp", "p", "ziglint"):
            folder = self.cache / name
            folder.mkdir(parents=True)
            (folder / "kept").write_bytes(b"x" * 16384)

    def trim(self, cap):
        return subprocess.run(
            ["sh", str(CI / "cache.sh"), str(self.cache), str(cap)],
            capture_output=True,
            text=True,
            check=True,
        )

    def test_over_cap_clears_products_and_keeps_packages_and_tools(self):
        self.trim(1)
        for name in ("o", "h", "z", "tmp"):
            self.assertFalse((self.cache / name).exists(), name)
        for name in ("p", "ziglint"):
            self.assertEqual((self.cache / name / "kept").read_bytes(), b"x" * 16384)
        self.trim(1)

    def test_under_cap_keeps_everything(self):
        self.trim(1024)
        self.assertTrue((self.cache / "o/kept").exists())

    def test_missing_cache_stays_missing(self):
        missing = self.cache / "absent"
        subprocess.run(["sh", str(CI / "cache.sh"), str(missing), "1"], check=True)
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main()
