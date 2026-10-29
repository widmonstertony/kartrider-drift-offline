import hashlib
import struct
import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from enable_ios_camera import (CAMERA_ENTRY, CAMERA_TRAMPOLINE, CAMERA_WRAPPER,
                               LOADING_SITE, LOADING_WRAPPER, patch)
from enable_ios_local_results import branch


ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = ROOT / 'analysis' / 'KartDrift-ios-decrypted'
RUNTIME_CAMERA_SHA = 'c88bd9195c60bf1563bbd7ace9b750b0dd2642c4708825f30fd8a24bf02390aa'
COCKPIT_HELPERS = {
    (0x58e97e0, 0x58e98e0): 'ab4228e4e4ea10a1b95abd99f9dd3be36f6268a9427e46ef640721b1b39cc1b5',
    (0x58f3eb0, 0x58f3f40): '2d9be4649093077aae5ea6bec58d2ad5043403fb5b62671f1acadbb456fada42',
    (0x58f3f40, 0x58f3f8c): '0678459afc3a083a9ac3c78f3b44992e456d3b1afb563d56c7544f1bdad5d70b',
    (0x58f3f8c, 0x58f3fd0): '0997d220e1a325a0bc6e3c50a79d854e33333ee9780e78d060849e0e6922ecf7',
    (0x5ab8d20, 0x5ab8d60): 'c143e3496716b5986c1c03eaedc6f7f177d62abb532377f05e97ed107284735f',
}


class CameraPatchTests(unittest.TestCase):
    def test_bridges_preserve_original_camera_and_track_loading_context(self):
        if not ORIGINAL.is_file():
            self.skipTest('retained local compatibility fixture unavailable')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'KartDrift'
            result = patch(ORIGINAL, output)
            data = output.read_bytes()
            self.assertEqual(data[CAMERA_ENTRY:CAMERA_ENTRY+4], branch(CAMERA_ENTRY, CAMERA_WRAPPER))
            self.assertEqual(data[LOADING_SITE:LOADING_SITE+4], branch(LOADING_SITE, LOADING_WRAPPER))
            self.assertEqual(struct.unpack_from('<I', data, CAMERA_TRAMPOLINE)[0], 0x6DBC23E9)
            self.assertIn(b'offline_camera_view\0', data[CAMERA_WRAPPER:CAMERA_WRAPPER+0x100])
            self.assertIn(b'offline_loading_widget\0', data[LOADING_WRAPPER:LOADING_WRAPPER+0x100])
            # Runtime validation deliberately starts after the installed
            # branch instruction; otherwise a correct patch rejects itself.
            self.assertEqual(hashlib.sha256(data[CAMERA_ENTRY+4:CAMERA_ENTRY+0x200]).hexdigest(),
                             RUNTIME_CAMERA_SHA)
            self.assertIn(RUNTIME_CAMERA_SHA, (ROOT/'tools/offline_camera.m').read_text())
            source = (ROOT/'tools/offline_camera.m').read_text()
            original = ORIGINAL.read_bytes()
            for (start, end), digest in COCKPIT_HELPERS.items():
                self.assertEqual(hashlib.sha256(original[start:end]).hexdigest(), digest)
                self.assertIn(digest, source)
            self.assertEqual(result['sha256'], hashlib.sha256(data).hexdigest())

    def test_unknown_camera_build_is_rejected_without_output(self):
        if not ORIGINAL.is_file():
            self.skipTest('retained local compatibility fixture unavailable')
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'unknown'
            output = Path(directory) / 'result'
            data = bytearray(ORIGINAL.read_bytes());data[CAMERA_ENTRY+8] ^= 1
            source.write_bytes(data)
            with self.assertRaises(ValueError):
                patch(source, output)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
