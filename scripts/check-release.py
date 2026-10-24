#!/usr/bin/env python3
"""Validate source and package contents before release.

Check for excluded artifacts, local build paths and credentials.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--release-dir', type=pathlib.Path)
args = parser.parse_args()

rules = {
    'local home/build path': rb'(?:/Users/|/home/|/var/folders/)[A-Za-z0-9._-]+/',
    'Windows home path': rb'[A-Za-z]:\\Users\\[A-Za-z0-9._-]+\\',
    'private key': rb'-----BEGIN [A-Z ]*PRIVATE KEY-----',
    'credential token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16})\b',
    'email address': rb'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
}
private_dirs = {'.work', '.mock', '.build', '.derivedData', '.deviceData', '.swiftpm', 'xcuserdata', '__pycache__', '.git'}
private_suffixes = {'.pen', '.p12', '.p8', '.pem', '.key', '.mobileprovision', '.log', '.dmg', '.dSYM', '.xcarchive'}

def prohibited(path):
    return (any(p in private_dirs or p.endswith(('.dSYM', '.xcarchive')) for p in path.parts)
            or path.name in {'SPEC.md', '.DS_Store', '.env'}
            or path.name.startswith('.env.') or path.suffix in private_suffixes
            or '.pen.' in path.name)

if args.release_dir:
    base = args.release_dir.resolve()
    files = [p.relative_to(base) for p in base.rglob('*') if p.is_file() or p.is_symlink()]
else:
    base = ROOT
    if (ROOT / '.git').exists():
        result = subprocess.run(['git', '-C', str(ROOT), 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], check=True, capture_output=True)
        files = sorted({pathlib.Path(p.decode()) for p in result.stdout.split(b'\0') if p})
    else:
        # Before repository creation, examine only intended public source roots.
        dirs = ['App', 'Device', 'Sources', 'Tests', 'UITests', 'ResizeAPFS.xcodeproj', 'scripts', '.github']
        files = [p.relative_to(ROOT) for d in dirs for p in (ROOT/d).rglob('*') if p.is_file() and not any(x in private_dirs for x in p.relative_to(ROOT).parts)]
        files += [pathlib.Path(p) for p in ['README.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE', 'Package.swift', '.gitignore', 'resize-apfs'] if (ROOT/p).exists()]

# Retina asset filenames can resemble email addresses inside signature manifests.
retina_names = {p.name.encode() for p in files if re.fullmatch(r'.+@[23]x\.png', p.name)}
errors = []
for relative in files:
    if prohibited(relative):
        errors.append((str(relative), 'prohibited private file'))
        continue
    path = base / relative
    if path.is_symlink():
        errors.append((str(relative), 'unexpected symlink; review before publication'))
        continue
    if not path.is_file():
        continue
    data = path.read_bytes()
    local_account = pathlib.Path.home().name.encode()
    if local_account not in {b'root', b'runner', b'admin', b'user'} and len(local_account) >= 4:
        if re.search(rb'(?<![A-Za-z0-9])' + re.escape(local_account) + rb'(?![A-Za-z0-9])', data, re.IGNORECASE):
            errors.append((str(relative), 'local account name'))
    for label, pattern in rules.items():
        # Preserve upstream authors' public contact notices in vendored source.
        if label == 'email address' and 'third_party' in relative.parts:
            continue
        matches = re.finditer(pattern, data)
        if any(label != 'email address' or match.group() not in retina_names for match in matches):
            errors.append((str(relative), label))
    if args.release_dir and relative.name == 'palera1n':
        errors.append((str(relative), 'external palera1n binary'))

for path, reason in errors:
    print(f'FAIL: {path}: {reason}', file=sys.stderr)
if errors:
    sys.exit(1)
print(f'PASS: release checks passed for {len(files)} files.')
