#!/usr/bin/env python3
"""Verify the actual release archive, then exercise its extracted binary."""
import hashlib
import os
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile

repo = Path(__file__).resolve().parent.parent
archive = Path(sys.argv[1]).resolve()
checksum = archive.with_name(archive.name + '.sha256').read_text().split()
assert len(checksum) == 2 and checksum[1] == archive.name, 'unexpected checksum entry'
assert hashlib.sha256(archive.read_bytes()).hexdigest() == checksum[0], 'checksum mismatch'
name = archive.name.removesuffix('.tar.gz')
with tempfile.TemporaryDirectory(prefix='annalist-package-') as tmp:
    root = Path(tmp)
    with tarfile.open(archive, 'r:gz') as bundle:
        for entry in bundle.getmembers():
            path = PurePosixPath(entry.name)
            assert not path.is_absolute() and '..' not in path.parts, entry.name
            assert path.parts[0] == name, entry.name
            assert entry.isfile() or entry.isdir(), 'archive must not contain links or devices'
            assert not any(p in {'.git', '.annalist', '.zig-cache', 'zig-out'} for p in path.parts), entry.name
        bundle.extractall(root, filter='data')
    release = root / name
    for required in ('annalist', 'README.md', 'CHANGELOG.md', 'SECURITY.md', 'RUNTIME.txt', 'docs/INSTALL.md', 'docs/RELEASE.md', 'docs/VERIFICATION.md'):
        assert (release / required).is_file(), required
    binary = release / 'annalist'
    assert os.access(binary, os.X_OK), 'binary executable bit missing'
    # Even version/help probes get isolated HOME/XDG locations.
    env = dict(os.environ, HOME=str(root / 'home'), XDG_DATA_HOME=str(root / 'data'))
    version = subprocess.check_output([str(binary), 'version'], env=env, cwd=root, text=True).strip()
    assert name == version.replace(' ', '-') + '-linux-x86_64', (name, version)
    help_text = subprocess.check_output([str(binary), 'help'], env=env, cwd=root, text=True)
    assert 'rewind' in help_text and 'export' in help_text and 'ui' in help_text
    for test in ('integration.py', 'terminal.py'):
        subprocess.run([sys.executable, str(repo / 'tests' / test), str(binary)], env=env, cwd=repo, check=True, timeout=240)
print('PASS release checksum, archive contents, executable, version/help, and extracted-binary regressions')
