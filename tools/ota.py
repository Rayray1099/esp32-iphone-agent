"""Signed OTA packages. Private keys stay outside the repository."""
import argparse
import hashlib
import struct
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

MAGIC = b'S3OTA1\0\0'
BOARD = b's3-n8r8-st7789'
PREFIX = struct.Struct('<8s32s32sI32s')
HEADER_SIZE = PREFIX.size + 64

def verify(package, public):
    if len(package) < HEADER_SIZE:
        raise ValueError('Truncated package')
    magic, board, version, size, digest = PREFIX.unpack(package[:PREFIX.size])
    if magic != MAGIC or board.rstrip(b'\0') != BOARD:
        raise ValueError('Wrong board or package format')
    if size > 0x2e0000 or size < 256 or len(package) != HEADER_SIZE + size:
        raise ValueError('Invalid image size')
    Ed25519PublicKey.from_public_bytes(public).verify(package[PREFIX.size:HEADER_SIZE], package[:PREFIX.size])
    if hashlib.sha256(package[HEADER_SIZE:]).digest() != digest:
        raise ValueError('Image hash mismatch')
    return version.rstrip(b'\0').decode()

def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest='command', required=True)
    keygen = commands.add_parser('keygen')
    keygen.add_argument('--private', type=Path, required=True)
    keygen.add_argument('--header', type=Path, required=True)
    pack = commands.add_parser('pack')
    pack.add_argument('--private', type=Path, required=True)
    pack.add_argument('--image', type=Path, required=True)
    pack.add_argument('--version', required=True)
    pack.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'keygen':
        if args.private.exists():
            raise SystemExit('Key already exists; refusing to replace it')
        key = Ed25519PrivateKey.generate()
        args.private.parent.mkdir(parents=True, exist_ok=True)
        args.private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        args.header.write_text('#pragma once\nstatic const unsigned char OTA_PUBLIC_KEY[32]={' + ','.join(f'0x{x:02x}' for x in public) + '};\n')
        print('Created private signing key and firmware public key. Back up the private key securely.')
    else:
        key = serialization.load_pem_private_key(args.private.read_bytes(), password=None)
        image = args.image.read_bytes()
        if len(args.version.encode()) > 31:
            raise SystemExit('Version too long')
        prefix = PREFIX.pack(MAGIC, BOARD, args.version.encode(), len(image), hashlib.sha256(image).digest())
        package = prefix + key.sign(prefix) + image
        verify(package, key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(package)
        print(f'Signed package: {args.output} ({len(package)} bytes)')

if __name__ == '__main__':
    main()
