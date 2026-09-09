#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
archive=${1:?Usage: sh scripts/check-container.sh dist/annalist-VERSION-linux-x86_64.tar.gz}
[ -f "$archive" ] || { echo "Archive not found: $archive" >&2; exit 1; }
archive_dir=$(CDPATH= cd "$(dirname "$archive")" && pwd)
archive_name=$(basename "$archive")
# Only test code and release artifacts enter the container, never project history.
docker build -t annalist-runtime-check:local - < tests/runtime.Dockerfile
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,exec,nosuid,size=256m \
  --mount "type=bind,src=$(pwd)/tests,dst=/work/tests,readonly" \
  --mount "type=bind,src=$archive_dir,dst=/work/dist,readonly" \
  annalist-runtime-check:local \
  python3 /work/tests/package.py "/work/dist/$archive_name"
