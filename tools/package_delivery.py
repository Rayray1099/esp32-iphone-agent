"""Collect a reproducible local delivery. Never copies enrollment/signing secrets."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from cryptography.hazmat.primitives import serialization
from ota import verify

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--private', type=Path, required=True)
    parser.add_argument('--version', default='0.2.0')
    args = parser.parse_args()
    build = ROOT / 'hardware/idf/build'
    dest = ROOT / 'output/delivery'
    dest.mkdir(parents=True, exist_ok=True)
    meta = json.loads((build / 'flasher_args.json').read_text())
    for name in meta['flash_files'].values():
        target = dest / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(build / name, target)
    (dest / 'flasher_args.json').write_text(json.dumps(meta, indent=2))
    for name in ['s3_clicker.elf', 's3_clicker.map']:
        shutil.copy2(build / name, dest / name)
    for name in ['s3-setup.md', 's3-api.md', 's3-validation.md']:
        shutil.copy2(ROOT / 'docs' / name, dest / name)
    shutil.copy2(ROOT / 'LICENSE', dest / 'LICENSE')
    shutil.copy2(ROOT / 'NOTICE', dest / 'NOTICE')
    shutil.copy2(ROOT / 'hardware/idf/partitions.csv', dest / 'partitions.csv')
    shutil.copy2(ROOT / 'hardware/hid_bridge/ota_public_key.h', dest / 'ota_public_key.h')
    for directory in ['screens', 'playwright', 'emulator']:
        source = ROOT / 'output' / directory
        if source.exists():
            shutil.copytree(source, dest / directory, dirs_exist_ok=True)
    package = dest / f's3-clicker-{args.version}.ota'
    subprocess.run([sys.executable, str(ROOT / 'tools/ota.py'), 'pack', '--private',
                    str(args.private), '--image', str(build / 's3_clicker.bin'),
                    '--version', args.version, '--output', str(package)], check=True)
    key = serialization.load_pem_private_key(args.private.read_bytes(), password=None)
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    firmware_public = bytes(int(x, 16) for x in re.findall(r'0x([0-9a-fA-F]{2})',
        (ROOT / 'hardware/hid_bridge/ota_public_key.h').read_text()))
    if firmware_public != public:
        raise SystemExit('Signing key does not match the firmware public key')
    verify(package.read_bytes(), public)
    (dest / 'ota-public-key.bin').write_bytes(public)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    files = []
    for path in sorted(dest.rglob('*')):
        if not path.is_file() or path.name == 'manifest.json':
            continue
        if path.suffix.lower() in {'.pem', '.key'}:
            raise SystemExit('Private-key extension in delivery; refusing to archive')
        content = path.read_bytes()
        if b'-----BEGIN PRIVATE KEY-----' in content or b'tskey-auth-' in content:
            # Guides may mention the enrollment-key prefix; never retain an actual key.
            if b'-----BEGIN PRIVATE KEY-----' in content:
                raise SystemExit('Private key material in delivery')
        files.append({'path': path.relative_to(dest).as_posix(), 'bytes': len(content),
                      'sha256': hashlib.sha256(content).hexdigest()})
    (dest / 'manifest.json').write_text(json.dumps({'commit': commit, 'working_tree_dirty': dirty,
        'board': 's3-n8r8-st7789', 'version': args.version, 'idf': '5.5.2',
        'hardware_validated': False, 'files': files}, indent=2))
    archive = shutil.make_archive(str(ROOT / 'output/s3-clicker-delivery'), 'zip', dest)
    print(f'Delivery: {archive}; {len(files)} verified files; source {commit[:8]}')

if __name__ == '__main__':
    main()
