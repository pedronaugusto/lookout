#!/usr/bin/env python3
"""The casts that step outside the type system are said to be safe, or refused.

`@constCast`, `@ptrCast`, `@alignCast` and `@intFromPtr` each tell the
compiler to trust the program about memory: that nothing reads the constant
as written, that the bytes are the type, that the address is aligned, that
an address is only a number. A wrong one is a use after free, a torn read or
a write into memory someone shares, and no test is sure to find it. So every
one outside a test carries its reason on its own line, `// safe: <why>`,
where a reviewer reads the cast and the argument together; one without is a
failure here.

Code inside a `test` block, and a file that is all tests (`*_test.zig`,
`test_*.zig`, `tests.zig`), may cast freely.

Usage: ci/casts.py [PATH...]     # default: every .zig file tracked by git
"""

import pathlib
import re
import subprocess
import sys

CAST = re.compile(r"@(constCast|ptrCast|alignCast|intFromPtr)\s*\(")
SAFE = re.compile(r"//\s*safe:\s*\S")
STRING = re.compile(r'"(?:\\.|[^"\\\n])*"')
CHAR = re.compile(r"'(?:\\.|[^'\\\n])+'")
TEST_FILE = re.compile(r"(^|/)(\w+_test|test_\w+|tests)\.zig$")


def code_of(line):
    """The line with its strings, characters and comment blanked."""
    if line.lstrip().startswith("\\\\"):
        return ""
    line = STRING.sub('""', line)
    line = CHAR.sub("''", line)
    return line.split("//", 1)[0]


def findings(path):
    out = []
    depth = 0
    in_test = False
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        code = code_of(line)
        if not in_test and re.match(r"^\s*test\b", code):
            in_test = True
            depth = 0
        if in_test:
            depth += code.count("{") - code.count("}")
            if depth <= 0 and "{" in code or (depth <= 0 and "}" in code):
                in_test = depth > 0
            continue
        if CAST.search(code) and not SAFE.search(line):
            out.append(f"{path}:{n}: {line.strip()}")
    return out


def main():
    if len(sys.argv) > 1:
        paths = [pathlib.Path(p) for p in sys.argv[1:]]
    else:
        listed = subprocess.run(["git", "ls-files", "*.zig"], capture_output=True, text=True, check=True)
        paths = [pathlib.Path(p) for p in listed.stdout.split()]
    found = []
    for path in paths:
        if TEST_FILE.search(path.as_posix()) or not path.exists():
            continue
        found += findings(path)
    for f in found:
        print(f"{f}  <- a cast out of the type system: say why it is safe on its line, // safe: <why>", file=sys.stderr)
    if found:
        print(f"casts: {len(found)} without a reason", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
