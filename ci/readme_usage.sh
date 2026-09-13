#!/usr/bin/env bash
#
# lookout -- README.md's Usage snippet, extracted from examples/usage.zig.
#
# A code snippet in a README is a claim about how the library is used, and
# nothing compiles it. This one is a region of an example that `zig build
# examples` builds AND runs, so comparing this output against the document
# is what keeps the two the same thing.
#
# Usage: ci/readme_usage.sh          # writes the fenced block to stdout

set -uo pipefail
cd "$(dirname "$0")/.."

exec python3 - <<'PY'
import pathlib
import sys

source = pathlib.Path("examples/usage.zig")
text = source.read_text(encoding="utf-8")

MARKER = "// --- README:usage ---"
parts = text.split(MARKER)
if len(parts) != 3:
    sys.exit(
        "%s: expected exactly two %s markers, found %d"
        % (source, MARKER, len(parts) - 1)
    )

# The import is the one line a reader needs that cannot live inside main, so
# it is read from the file too rather than written out here.
imports = [
    line for line in text.splitlines() if line.startswith('const lookout = @import(')
]
if len(imports) != 1:
    sys.exit("%s: expected exactly one `const lookout = @import(...)` line" % source)

body = []
for line in parts[1].splitlines():
    # The region sits inside main; the README shows it at the left margin.
    body.append(line[4:] if line.startswith("    ") else line)

print("```zig")
print(imports[0])
print()
print("\n".join(body).strip("\n"))
print("```")
PY
