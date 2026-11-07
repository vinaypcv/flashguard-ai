import unittest
from pathlib import Path

import server


class ChaosFixtureTests(unittest.TestCase):
    def test_fixture_ground_truth(self):
        mount = server.create_virtual_drive("unit_test_ssd")
        root = mount.split(": ", 1)[1]
        truth = server.verify_drive_ground_truth(root)
        self.assertTrue(truth["VID_4K_valid.mp4"]["structurally_valid"])
        self.assertFalse(truth["VID_4K_corrupt_disconnect.mp4"]["structurally_valid"])
        self.assertEqual(
            truth["IMG_001_original.jpg"]["sha256"],
            truth["IMG_001_copy.jpg"]["sha256"],
        )

    def test_disconnect_and_sandbox_boundary(self):
        mount = server.create_virtual_drive("unit_test_disconnect")
        root = Path(mount.split(": ", 1)[1])
        target = root / "VID_4K_valid.mp4"
        before = target.stat().st_size
        server.simulate_mid_transfer_disconnect(str(target))
        self.assertLess(target.stat().st_size, before)
        self.assertFalse(
            server.verify_drive_ground_truth(str(root))[target.name][
                "structurally_valid"
            ]
        )
        with self.assertRaises(ValueError):
            server.create_virtual_drive("../escape")
        with self.assertRaises(ValueError):
            server.simulate_mid_transfer_disconnect(__file__)


if __name__ == "__main__":
    unittest.main()
