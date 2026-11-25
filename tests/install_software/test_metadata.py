import unittest
from _helpers import load_library

class MetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load_library()

    def test_aur_metadata_and_unknown_sizes(self):
        record = self.lib["normalize_aur"]({
            "Name": "demo-bin", "PackageBase": "demo-bin", "Version": "1.2-1",
            "Description": "Demo", "NumVotes": 42, "Popularity": 1.5,
            "FirstSubmitted": 1600000000, "LastModified": 1700000000,
            "Maintainer": "maint", "License": ["MIT"], "Depends": ["gtk4"],
            "MakeDepends": ["meson"], "CheckDepends": ["pytest"],
            "OptDepends": ["demo-cli: CLI"], "Keywords": ["utility"],
        })
        self.assertEqual(record["votes"], 42)
        self.assertEqual(record["first_submitted"], 1600000000)
        self.assertEqual(record["updated"], 1700000000)
        self.assertEqual(record["depends"], ["gtk4"])
        self.assertEqual(record["licenses"], ["MIT"])
        self.assertIsNone(record["download_size"])
        self.assertIsNone(record["installed_size"])

    def test_official_sizes_license_architecture_and_packager(self):
        record = self.lib["parse_pacman_si"]("""Repository      : extra
Name            : demo
Version         : 1.2-1
Description     : Demo
Architecture    : x86_64
Licenses        : MIT
Depends On      : gtk4  glib2
Optional Deps   : demo-cli: CLI
Download Size   : 1.50 MiB
Installed Size  : 4.00 MiB
Packager        : Example Packager <packager@example.invalid>
Build Date      : Sun Jan 7 03:04:05 2024
""")
        self.assertEqual(record["repository"], "extra")
        self.assertEqual(record["architectures"], ["x86_64"])
        self.assertEqual(record["download_size"], 1572864)
        self.assertEqual(record["installed_size"], 4194304)
        self.assertEqual(record["licenses"], ["MIT"])
        self.assertEqual(record["packager"], "Example Packager <packager@example.invalid>")
        self.assertIsNone(record["first_submitted"])

    def test_records_do_not_share_lists(self):
        first = self.lib["new_package"]("first")
        second = self.lib["new_package"]("second")
        first["depends"].append("gtk4")
        self.assertEqual(second["depends"], [])

if __name__ == "__main__":
    unittest.main()
