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
