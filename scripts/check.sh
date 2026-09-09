#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${ZIG:=zig}"
export ZIG
[ "$("$ZIG" version)" = 0.15.2 ] || { echo 'Zig 0.15.2 required' >&2; exit 1; }
"$ZIG" fmt --check build.zig build.zig.zon src
"$ZIG" build test --summary all
"$ZIG" build
python3 tests/integration.py
python3 tests/terminal.py
"$ZIG" build test -Doptimize=ReleaseSafe --summary all
sh scripts/package.sh
version=$(zig-out/bin/annalist version | cut -d ' ' -f2)
python3 tests/package.py "dist/annalist-${version}-linux-x86_64.tar.gz"
git diff --check
