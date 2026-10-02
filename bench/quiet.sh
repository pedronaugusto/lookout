#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "${PYTHON:-python3}" "$here/quiet.py" "$@"
