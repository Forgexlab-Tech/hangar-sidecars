"""Reject packaged Mach-O files requiring an OS newer than the advertised floor."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
limit = tuple(map(int, sys.argv[2].split('.')))
count = 0
for path in root.rglob('*'):
    if not path.is_file() or path.is_symlink():
        continue
    kind = subprocess.check_output(['file', '-b', str(path)], text=True)
    if 'Mach-O' not in kind:
        continue
    if 'x86_64' not in kind:
        raise SystemExit(f'Wrong architecture: {path}: {kind}')
    headers = subprocess.check_output(['otool', '-l', str(path)], text=True)
    versions = []
    for block in re.split(r'Load command \d+', headers):
        if re.search(r'cmd LC_BUILD_VERSION\b', block):
            versions.extend(re.findall(r'^\s*minos (\d+\.\d+(?:\.\d+)?)$', block, re.M))
        elif re.search(r'cmd LC_VERSION_MIN_MACOSX\b', block):
            versions.extend(re.findall(r'^\s*version (\d+\.\d+(?:\.\d+)?)$', block, re.M))
    if not versions:
        raise SystemExit(f'Missing deployment target: {path}')
    for version in versions:
        parsed = tuple(map(int, version.split('.')))
        if (parsed + (0, 0))[:3] > (limit + (0, 0))[:3]:
            raise SystemExit(f'{path} requires macOS {version}, exceeds {sys.argv[2]}')
    count += 1
    print(f'{path}: {", ".join(versions)}')
if not count:
    raise SystemExit('No Mach-O payloads found')
print(f'PASS: {count} payloads within macOS {sys.argv[2]}')
