"""Verify simulation inputs without installing or claiming to patch a package."""

import re
import unittest
from pathlib import Path


class SimulationInputs(unittest.TestCase):
    def test_release_metadata(self):
        self.assertRegex(Path("version.txt").read_text().strip(), r"^\d+\.\d+\.\d+$")
        self.assertIn("aiohttp==", Path("requirements.txt").read_text())
        change = Path("CHANGE_REQUEST").read_text().strip()
        self.assertTrue(not change or re.fullmatch(r"CHG[0-9]{1,30}", change))


if __name__ == "__main__":
    unittest.main()
