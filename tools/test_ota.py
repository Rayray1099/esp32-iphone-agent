import hashlib
import unittest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from ota import PREFIX, MAGIC, BOARD, HEADER_SIZE, verify

class PackageTests(unittest.TestCase):
    def setUp(self):
        self.key=Ed25519PrivateKey.generate()
        self.public=self.key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
        self.image=b'\xe9'+b'x'*1023
        self.header=PREFIX.pack(MAGIC,BOARD,b'0.2.0',len(self.image),hashlib.sha256(self.image).digest())
        self.package=self.header+self.key.sign(self.header)+self.image
    def test_valid(self):
        self.assertEqual(verify(self.package,self.public),'0.2.0')
    def test_corrupt_image(self):
        with self.assertRaises(ValueError):verify(self.package[:-1]+b'y',self.public)
    def test_signature_and_wrong_key(self):
        from cryptography.exceptions import InvalidSignature
        with self.assertRaises(InvalidSignature):verify(self.package,bytes(32))
        with self.assertRaises(InvalidSignature):verify(self.package[:44]+b'X'+self.package[45:],self.public)
    def test_interrupted(self):
        for length in [0,7,HEADER_SIZE-1,HEADER_SIZE,HEADER_SIZE+100]:
            with self.assertRaises(ValueError):verify(self.package[:length],self.public)
    def test_size_and_board(self):
        for board,size in [(b'wrong',1024),(BOARD,0x2e0001)]:
            header=PREFIX.pack(MAGIC,board,b'0.2.0',size,hashlib.sha256(self.image).digest())
            with self.assertRaises(ValueError):verify(header+self.key.sign(header)+self.image,self.public)

if __name__=='__main__':unittest.main()
