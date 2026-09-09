#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
: "${ZIG:=zig}"
[ "$("$ZIG" version)" = 0.15.2 ] || { echo 'Zig 0.15.2 required' >&2; exit 1; }
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo 'Validated packaging target is Linux x86_64' >&2; exit 1; }
# Baseline x86_64: never ship native-CPU instructions (past release
# crashed with SIGILL on hosted runners whose CPUs lack them).
"$ZIG" build -Doptimize=ReleaseSafe -Dcpu=baseline
version=$(zig-out/bin/annalist version | cut -d ' ' -f2)
name="annalist-${version}-linux-x86_64"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$stage/$name" dist
cp zig-out/bin/annalist README.md CHANGELOG.md SECURITY.md CONTRIBUTING.md "$stage/$name/"
cp -R docs "$stage/$name/"
{
  printf '%s\n' "Annalist $version · Linux x86_64" \
    'Requires glibc and system libsqlite3.so.0. No Zig runtime is required.' \
    'Unsigned local release candidate. See docs/INSTALL.md and docs/RELEASE.md.' \
    'CPU baseline: generic x86_64 (no host-specific instructions).'
  printf '\nBuild toolchain: Zig %s\n' "$("$ZIG" version)"
  if [ -r /etc/os-release ]; then
    sed -n 's/^PRETTY_NAME=/Build distribution: /p' /etc/os-release
  fi
  printf '\nRequired shared libraries:\n'
  readelf -d zig-out/bin/annalist | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'
  printf '\nRequired glibc symbol versions (not a clean-machine compatibility guarantee):\n'
  readelf --version-info zig-out/bin/annalist | sed -n 's/.*Name: \(GLIBC_[0-9.]*\).*/\1/p' | sort -Vu
} > "$stage/$name/RUNTIME.txt"
tar -C "$stage" -czf "dist/$name.tar.gz" "$name"
(cd dist && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
printf 'Created dist/%s.tar.gz and checksum (not published)\n' "$name"
