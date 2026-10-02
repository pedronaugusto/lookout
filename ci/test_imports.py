"""The import gate rejects undeclared dependencies and ambiguous layer membership."""
from pathlib import Path
import os
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAYERS = ROOT / 'ci/layers.zig'


def check():
    return subprocess.run(['zig', 'build', 'check-imports'], cwd=ROOT,
                          env=os.environ.copy(), capture_output=True, text=True)


class Imports(unittest.TestCase):
    def test_undeclared_named_dependency_is_refused(self):
        table = LAYERS.read_text().split('pub const entries:', 1)[0].split('pub const modules:', 1)[0]
        source = ROOT / re.findall(r'"(src/[^"\n]+\.zig)"', table)[-1]
        before = source.read_text()
        try:
            source.write_text(before + '\nconst unowned_fixture = @import("unowned_dependency_fixture");\n')
            result = check()
            self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn('named dependencies', result.stderr)
        finally:
            source.write_text(before)

    def test_each_source_belongs_to_one_layer(self):
        before = LAYERS.read_text()
        table = before.split('pub const entries:', 1)[0].split('pub const modules:', 1)[0]
        source = re.findall(r'"(src/[^"\n]+\.zig)"', table)[-1]
        position = table.rfind('"' + source + '"')
        try:
            LAYERS.write_text(before[:position] + '"' + source + '", ' + before[position:])
            result = check()
            self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn('multiple layers', result.stderr)
        finally:
            LAYERS.write_text(before)

    def test_source_entries_have_no_importers(self):
        entries = [path for path in (ROOT / 'src').rglob('*.zig')
                   if re.search(r'^pub fn main\(', path.read_text(), re.M)]
        if not entries:
            self.skipTest('this package has no source executables')
        table = LAYERS.read_text().split('pub const entries:', 1)[0].split('pub const modules:', 1)[0]
        source = ROOT / re.findall(r'"(src/[^"\n]+\.zig)"', table)[-1]
        target = next(path for path in entries if path != source)
        before = source.read_text()
        relative = os.path.relpath(target, source.parent).replace(os.sep, '/')
        try:
            source.write_text(before + f'\nconst entry_fixture = @import("{relative}");\n')
            result = check()
            self.assertNotEqual(0, result.returncode, result.stdout + result.stderr)
            self.assertIn('entry files', result.stderr)
        finally:
            source.write_text(before)


if __name__ == '__main__':
    unittest.main()
