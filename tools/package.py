#!/usr/bin/env python3
"""Package tracked release files with hashes; never include runtime credentials."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', default='1.1.0')
    args = parser.parse_args()
    if not all(c.isalnum() or c in '.-' for c in args.version):
        raise SystemExit('Invalid version')
    paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    paths = sorted(x for x in paths if x)
    if not paths:
        raise SystemExit('Commit or stage reviewed files before packaging')
    forbidden = {'.runtime', '.git', '__pycache__', 'dist'}
    payload = {}
    for name in paths:
        p = ROOT / name
        if forbidden.intersection(p.relative_to(ROOT).parts) or p.suffix in {'.elc', '.pyc'}:
            raise SystemExit('Refusing runtime/generated file: ' + name)
        if p.is_symlink():
            raise SystemExit('Review symlink before release: ' + name)
        payload[name] = (p.read_bytes(), 0o755 if p.stat().st_mode & 0o111 else 0o644)
    sums = ''.join(hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
                   for name, (data, _) in payload.items())
    payload['SHA256SUMS'] = (sums.encode(), 0o644)
    target = ROOT / 'dist' / f'emacs-multihost-{args.version}.tar.gz'
    target.parent.mkdir(exist_ok=True)
    with target.open('xb') as raw:
        with gzip.GzipFile(fileobj=raw, filename='', mode='wb', mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w|') as archive:
                for name, (data, mode) in sorted(payload.items()):
                    info = tarfile.TarInfo(f'emacs-multihost-{args.version}/' + name)
                    info.size, info.mode, info.mtime = len(data), mode, 0
                    archive.addfile(info, io.BytesIO(data))
    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    target.with_name(target.name + '.sha256').write_text(digest + '  ' + target.name + '\n')
    print(target)
    print(digest)


if __name__ == '__main__':
    main()
