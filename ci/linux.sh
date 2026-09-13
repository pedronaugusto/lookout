#!/usr/bin/env bash
#
# lookout -- run the suite on Linux, from a machine that is not Linux.
#
# The inotify backend cannot be executed on macOS or Windows, and a
# backend that only compiles is a backend nobody has run. This builds a
# Debian image with the pinned Zig and runs the same `zig build test` CI
# runs, so "green on Linux" is something anyone with Docker can check
# before pushing rather than something they learn from a CI run.
#
# The suite selects backends per host, so inside the container it
# exercises inotify and polling, exactly as the Linux CI job does.
#
# Usage:
#   ci/linux.sh                       # every optimize mode
#   ci/linux.sh Debug ReleaseFast     # only these
#
# Environment:
#   LOOKOUT_LINUX_IMAGE   use an existing image instead of building one

set -euo pipefail
cd "$(dirname "$0")/.."

ZIG_VERSION=0.16.0
IMAGE=${LOOKOUT_LINUX_IMAGE:-lookout-linux-zig-$ZIG_VERSION}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> building $IMAGE (Zig $ZIG_VERSION)"
  docker build --build-arg "ZIG=$ZIG_VERSION" -t "$IMAGE" -f ci/linux.Dockerfile ci
fi

modes=("$@")
if [ ${#modes[@]} -eq 0 ]; then
  modes=(Debug ReleaseSafe ReleaseFast ReleaseSmall)
fi

for mode in "${modes[@]}"; do
  echo "==> $mode"
  # The working tree is mounted read-only and copied in: the build writes
  # zig-out and the tests write temporary directories under .zig-cache,
  # and neither belongs in the tree of the machine running this.
  docker run --rm -v "$PWD:/src:ro" -w /tmp/build "$IMAGE" sh -c "
    cp -r /src/. /tmp/build &&
    zig build test -Doptimize=$mode --cache-dir /tmp/zc --global-cache-dir /tmp/zg
  "
done

echo "==> Linux: all green"
