import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from _helpers import SCRIPT, load_library


class VariantTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load_library()
        cls.now = 1800000000
        cls.day = 86400

    def record(self, name, source="aur", **changes):
        record = self.lib["new_package"](name)
        record.update({
            "source": source,
            "repository": "extra" if source == "repo" else "AUR",
            "package_base": name,
            "version": "1.0-1",
            "updated": self.now - self.day,
            "maintainer": "maint" if source == "aur" else None,
            "packager": "Packager" if source == "repo" else None,
            "architectures": ["x86_64"],
            "depends": ["gtk4"],
            "provides": [],
            "conflicts": [],
        })
        record.update(changes)
        return record

    def fixtures(self):
        official = self.record(
            "demo", "repo", package_base="demo", updated=100, version="1",
            votes=None, popularity=None, user_share=12.5,
            download_size=1024, installed_size=4096,
        )
        binary = self.record(
            "demo-bin", package_base="demo-bin", provides=["demo"],
            updated=self.now - self.day, votes=30, popularity=2.0,
            user_share=1.25, conflicts=["demo"], version="2",
            first_submitted=self.now - 400 * self.day, installed=True,
            installed_version="1.9-1",
        )
        vcs = self.record(
            "demo-git", package_base="demo-git", provides=["demo"],
            updated=self.now, votes=100, popularity=4.0, user_share=2.5,
            conflicts=["demo"], version="2.r1", make_depends=["git"],
            check_depends=["python-pytest"], first_submitted=self.now - 300 * self.day,
        )
        source = self.record(
            "demo-source", package_base="demo-source", provides=["demo"],
            updated=self.now - 2 * self.day, maintainer=None, votes=5,
            popularity=0.2, out_of_date=self.now - 10 * self.day,
            version="2", make_depends=["meson"], check_depends=["python-pytest"],
            architectures=None, _unavailable=["architectures"],
            first_submitted=self.now - 200 * self.day,
        )
        return [official, binary, vcs, source]

    def mixed_identity_records(self):
        official = self.record("demo", "repo", updated=100)
        binary = self.record(
            "demo-bin", provides=["demo"], updated=self.now - self.day,
            votes=30, popularity=2.0,
        )
        vcs = self.record(
            "demo-git", package_base="demo-git", provides=[], updated=self.now,
        )
        secondary = self.record(
            "demo-cli", package_base="demo-git", provides=[], updated=self.now,
            votes=1000, popularity=50.0,
        )
        return [official, binary, vcs, secondary]

    def test_recent_maintained_binary_beats_vcs_and_orphan(self):
        official, binary, vcs, source = self.fixtures()
        result = self.lib["recommend_variant"]([official, binary, vcs, source], self.now)
        self.assertEqual(result["recommended_key"], "aur:demo-bin")
        self.assertIn("maintained stable variant", result["reason"])
        self.assertIn("Last update", result["reason"])
        self.assertIn(self.lib["format_date"](binary["updated"]), result["reason"])
        self.assertIn(self.lib["format_date"](official["updated"]), result["reason"])
        self.assertIn("AUR", result["reason"])
        self.assertIn("votes 30", result["reason"])
        self.assertIn("AUR popularity 2.0", result["reason"])
        self.assertIn("faster", result["reason"])
        self.assertIn("locally compiled", result["reason"])
        self.assertIn("does not imply trust", result["reason"])
        self.assertEqual(len(result["comparison_rows"]), 4)

    def test_comparison_rows_have_full_metadata_and_exact_kind_labels(self):
        records = self.fixtures()
        result = self.lib["compare_variants"](records, self.now)
        rows = result["comparison_rows"]
        self.assertEqual(
            [row["key"] for row in rows],
            ["repo:demo", "aur:demo-bin", "aur:demo-git", "aur:demo-source"],
        )
        self.assertEqual(
            [row["kind"] for row in rows],
            [
                "official",
                "binary repackaging (inferred from -bin)",
                "VCS/development (inferred from -git)",
                "source/other — verify PKGBUILD",
            ],
        )
        required = {
            "source", "repository", "version", "installed", "installed_version",
            "updated", "update_label", "update_date", "first_submitted",
            "first_submitted_date", "votes", "popularity", "user_share",
            "maintainer", "packager", "out_of_date", "architectures",
            "download_size", "installed_size", "depends", "build_only",
            "make_depends", "check_depends", "conflicts", "conflicts_with",
            "warnings", "identity_confident",
        }
        for row in rows:
            self.assertTrue(required.issubset(row), required - set(row))
        self.assertEqual(rows[0]["update_label"], "Package build date")
        self.assertEqual(rows[1]["update_label"], "AUR recipe update")
        self.assertEqual(rows[1]["installed_version"], "1.9-1")
        self.assertEqual(rows[1]["build_only"], [])
        self.assertEqual(rows[2]["build_only"], ["git", "python-pytest"])
        self.assertEqual(rows[3]["build_only"], ["meson", "python-pytest"])
        self.assertIn("Orphaned", rows[3]["maintenance"])
        self.assertTrue(rows[3]["out_of_date"])
        text = result["text"]
        for expected in (
            "Source/repository: repo / extra",
            "Variant kind: binary repackaging (inferred from -bin)",
            "Version: 2.r1",
            "Installed: yes; installed version 1.9-1",
            "Package build date: 1970-01-01",
            "AUR recipe update: " + self.lib["format_date"](self.now),
            "First submitted to AUR: " + self.lib["format_date"](records[1]["first_submitted"]),
            "AUR votes: 30",
            "AUR popularity: 2.0",
            "pkgstats popularity: 1.25",
            "Architecture: Not available",
            "Download size: 1.0 KiB",
            "Installed size: 4.0 KiB",
            "Direct/runtime requirements: gtk4",
            "Build-only requirements: git, python-pytest",
            "Download size: Not published by AUR",
            "Installed size: Unknown until built",
            "Out of date",
            "Orphaned",
            "Recommended (advisory): aur:demo-bin",
            "Age alone is not treated as a safety failure",
        ):
            self.assertIn(expected, text)

    def test_official_build_only_requirements_are_not_tracked(self):
        official = self.lib["parse_pacman_si"]("""Repository      : extra
Name            : demo
Version         : 1.2-1
Packager        : Example Packager <packager@example.invalid>
""")
        self.assertIsNone(official["make_depends"])
        self.assertIsNone(official["check_depends"])
        self.assertTrue({"make_depends", "check_depends"}.issubset(
            official["_unavailable"]
        ))
        row = self.lib["compare_variants"]([official], self.now)["comparison_rows"][0]
        self.assertEqual(row["build_only"], [])
        self.assertEqual(row["build_only_text"], "Not tracked by pacman")
        self.assertIn("Build-only requirements: Not tracked by pacman", row["text"])

    def test_partial_unknown_build_requirements_keep_known_remainder(self):
        cases = (
            (None, ["python-pytest"], "make_depends", "make dependencies"),
            (["meson"], None, "check_depends", "check dependencies"),
        )
        for make, check, unavailable, label in cases:
            with self.subTest(unavailable=unavailable):
                record = self.record(
                    "demo", make_depends=make, check_depends=check,
                    _unavailable=[unavailable],
                )
                row = self.lib["compare_variants"]([record], self.now)["comparison_rows"][0]
                known = check if make is None else make
                self.assertEqual(row["build_only"], known)
                self.assertEqual(
                    row["build_only_text"],
                    known[0] + "; " + label + ": Not available",
                )

    def test_official_out_of_date_flag_is_not_tracked(self):
        official = self.record("demo", "repo", out_of_date=None)
        row = self.lib["compare_variants"]([official], self.now)["comparison_rows"][0]
        self.assertEqual(row["out_of_date_text"], "Not tracked by pacman")
        self.assertIn("Out-of-date state: Not tracked by pacman", row["text"])
        self.assertNotIn("Out-of-date state: Not out of date", row["text"])

    def test_vcs_kind_labels_use_the_actual_suffix(self):
        for suffix in ("-git", "-svn", "-hg", "-bzr"):
            with self.subTest(suffix=suffix):
                row = self.lib["compare_variants"]([
                    self.record("demo" + suffix)
                ], self.now)["comparison_rows"][0]
                self.assertEqual(
                    row["kind"], "VCS/development (inferred from %s)" % suffix
                )

    def test_unknowns_and_popularity_sources_remain_distinct(self):
        official, binary, _, _ = self.fixtures()
        binary.update(votes=None, popularity=None, user_share=None, updated=None)
        result = self.lib["compare_variants"]([official, binary], self.now)
        text = result["text"]
        self.assertIn("AUR votes: Not used for official packages", text)
        self.assertIn("AUR popularity: Not used for official packages", text)
        self.assertIn("AUR votes: Not available", text)
        self.assertIn("AUR popularity: Not available", text)
        self.assertIn("pkgstats popularity: Not available", text)
        self.assertIn("AUR recipe update: Not available", text)
        self.assertNotIn("AUR votes: 0", text)
        self.assertNotIn("AUR popularity: 0.0", text)

    def test_only_actual_conflicts_metadata_is_flagged(self):
        records = self.fixtures()
        result = self.lib["compare_variants"](records, self.now)
        rows = {row["key"]: row for row in result["comparison_rows"]}
        self.assertEqual(rows["repo:demo"]["conflicts_with"], ["aur:demo-bin", "aur:demo-git"])
        self.assertEqual(rows["aur:demo-bin"]["conflicts_with"], ["repo:demo", "aur:demo-git", "aur:demo-source"])
        self.assertEqual(rows["aur:demo-source"]["conflicts"], [])
        self.assertEqual(rows["aur:demo-source"]["conflicts_with"], ["aur:demo-bin", "aur:demo-git"])
        self.assertIn("declared by aur:demo-bin", rows["aur:demo-source"]["conflict_warning"])
        compatible = [
            self.record("demo", "repo", provides=[]),
            self.record("demo-git", provides=[], conflicts=[]),
        ]
        compatible_rows = self.lib["compare_variants"](compatible, self.now)["comparison_rows"]
        self.assertEqual([row["conflicts_with"] for row in compatible_rows], [[], []])
        self.assertNotIn("Conflicts with:", compatible_rows[1]["text"])

    def test_suffix_alone_is_not_identity_or_a_conflict(self):
        official = self.record("demo", "repo", provides=[])
        binary = self.record("demo-bin", provides=[], conflicts=[])
        result = self.lib["compare_variants"]([official, binary], self.now)
        self.assertEqual(result["recommended_key"], "")
        self.assertIn("ambiguous", result["reason"])
        self.assertFalse(result["comparison_rows"][0]["identity_confident"])
        self.assertFalse(result["comparison_rows"][1]["identity_confident"])
        self.assertEqual(result["comparison_rows"][1]["conflicts_with"], [])

    def test_candidate_grouping_uses_conservative_evidence(self):
        official = self.record("demo", "repo")
        binary = self.record("demo-bin")
        split = self.record("demo-cli", package_base="demo")
        provider = self.record("demonstration", provides=["demo"])
        alternate = self.record("demo-stable", alt="demo")
        parented = self.record("demo-source", parent="demo", category="app")
        unrelated = self.record("other")
        plugin = self.record("demo-plugin", parent="demo", category="plugin")
        records = [official, binary, split, provider, alternate, parented, unrelated, plugin]
        candidates = self.lib["variant_candidates"](records, "repo:demo")
        self.assertEqual(
            [record["name"] for record in candidates],
            ["demo", "demo-bin", "demo-cli", "demonstration", "demo-stable", "demo-source"],
        )

    def test_weak_bridge_does_not_confer_confidence_from_explicit_target(self):
        records = self.mixed_identity_records()
        candidates = self.lib["variant_candidates"](records, "repo:demo")
        self.assertEqual([record["name"] for record in candidates], [
            "demo", "demo-bin", "demo-git", "demo-cli",
        ])
        result = self.lib["compare_variants"](records, self.now, target="repo:demo")
        self.assertEqual(result["recommended_key"], "aur:demo-bin")
        self.assertEqual(
            [row["key"] for row in result["comparison_rows"]],
            ["repo:demo", "aur:demo-bin", "aur:demo-git", "aur:demo-cli"],
        )
        confidence = {
            row["key"]: row["identity_confident"]
            for row in result["comparison_rows"]
        }
        self.assertEqual(confidence, {
            "repo:demo": True,
            "aur:demo-bin": True,
            "aur:demo-git": False,
            "aur:demo-cli": False,
        })

    def test_cross_component_identity_declines_without_a_target(self):
        result = self.lib["compare_variants"](self.mixed_identity_records(), self.now)
        self.assertEqual(result["recommended_key"], "")
        self.assertIn("ambiguous", result["reason"])
        self.assertTrue(all(
            not row["identity_confident"] for row in result["comparison_rows"]
        ))

    def test_votes_break_ties_only_inside_thirty_day_window(self):
        older = self.record(
            "demo-bin", package_base="demo", updated=self.now - 40 * self.day,
            votes=500, popularity=20.0,
        )
        newer = self.record(
            "demo-stable", package_base="demo", updated=self.now,
            votes=1, popularity=0.1,
        )
        result = self.lib["recommend_variant"]([older, newer], self.now)
        self.assertEqual(result["recommended_key"], "aur:demo-stable")
        older["updated"] = self.now - self.day
        newer["updated"] = self.now - 2 * self.day
        result = self.lib["recommend_variant"]([older, newer], self.now)
        self.assertEqual(result["recommended_key"], "aur:demo-bin")

    def test_official_rule_precedes_votes_inside_window(self):
        official = self.record("demo", "repo", package_base="demo", updated=self.now - self.day)
        binary = self.record(
            "demo-bin", package_base="demo", updated=self.now,
            votes=1000, popularity=50.0,
        )
        result = self.lib["recommend_variant"]([official, binary], self.now)
        self.assertEqual(result["recommended_key"], "repo:demo")
        self.assertIn("Official", result["reason"])
        self.assertIn("30-day", result["reason"])

    def test_thirty_day_boundary_is_inclusive_but_not_beyond(self):
        official = self.record(
            "demo", "repo", package_base="demo", updated=self.now - 30 * self.day,
        )
        binary = self.record(
            "demo-bin", package_base="demo", updated=self.now,
            votes=1000, popularity=50.0,
        )
        result = self.lib["recommend_variant"]([official, binary], self.now)
        self.assertEqual(result["recommended_key"], "repo:demo")
        official["updated"] -= 1
        result = self.lib["recommend_variant"]([official, binary], self.now)
        self.assertEqual(result["recommended_key"], "aur:demo-bin")

    def test_exact_timestamp_breaks_vote_and_popularity_ties(self):
        older = self.record(
            "demo-bin", package_base="demo", updated=self.now - 2 * self.day,
            votes=10, popularity=2.0,
        )
        newer = self.record(
            "demo-stable", package_base="demo", updated=self.now - self.day,
            votes=10, popularity=2.0,
        )
        result = self.lib["recommend_variant"]([older, newer], self.now)
        self.assertEqual(result["recommended_key"], "aur:demo-stable")

    def test_no_stable_recommendation_and_explicit_vcs_exceptions(self):
        first = self.record("demo-git", package_base="demo", updated=self.now)
        second = self.record("demo-svn", package_base="demo", updated=self.now - self.day)
        result = self.lib["recommend_variant"]([first, second], self.now)
        self.assertEqual(result["recommended_key"], "")
        self.assertIn("No maintained stable recommendation", result["reason"])
        sole = self.lib["recommend_variant"]([first], self.now)
        self.assertEqual(sole["recommended_key"], "aur:demo-git")
        self.assertIn("sole candidate", sole["reason"])
        requested = self.lib["recommend_variant"]([first, second], self.now, development=True)
        self.assertEqual(requested["recommended_key"], "aur:demo-git")
        self.assertIn("development", requested["reason"])

    def test_orphaned_and_out_of_date_candidates_are_not_stable(self):
        orphan = self.record("demo", maintainer=None, out_of_date=None)
        outdated = self.record("demo-bin", package_base="demo", out_of_date=self.now)
        result = self.lib["recommend_variant"]([orphan, outdated], self.now)
        self.assertEqual(result["recommended_key"], "")
        self.assertIn("No maintained stable recommendation", result["reason"])
        rows = {row["key"]: row for row in result["comparison_rows"]}
        self.assertTrue(any("Orphaned" in warning for warning in rows["aur:demo"]["warnings"]))
        self.assertTrue(any("Out of date" in warning for warning in rows["aur:demo-bin"]["warnings"]))

    def test_old_maintained_stable_is_not_called_unsafe(self):
        old = self.record(
            "demo-source", updated=self.now - 10 * 365 * self.day,
            maintainer="maint", out_of_date=None,
        )
        result = self.lib["recommend_variant"]([old], self.now)
        self.assertEqual(result["recommended_key"], "aur:demo-source")
        self.assertIn("maintained stable", result["reason"])
        self.assertNotIn("unsafe", result["reason"].lower())
        self.assertNotIn("out of date", result["reason"].lower())
        self.assertFalse(any("age" in warning.lower() for warning in result["comparison_rows"][0]["warnings"]))

    def test_empty_input_has_an_honest_empty_result(self):
        result = self.lib["compare_variants"]([], self.now)
        self.assertEqual(result["recommended_key"], "")
        self.assertEqual(result["reason"], "No comparable variants")
        self.assertEqual(result["comparison_rows"], [])
        self.assertIn("No comparable variants", result["text"])

    def test_selection_records_preserve_classifier_alt_evidence(self):
        normalized = self.record("demo-bin", alt="")
        with tempfile.TemporaryDirectory() as tmp:
            meta = Path(tmp) / "search_meta"
            meta.write_text(
                "|".join(["demo-bin", "app", "", "", "", "", "", "", "demo"]) + "\n",
                encoding="utf-8",
            )
            with patch.dict(self.lib, {"fetch_details": lambda requests: {"aur:demo-bin": normalized}}):
                records = self.lib["selection_records"](
                    [("aur", "demo-bin")], tmp, str(meta), set()
                )
        self.assertEqual(records["aur:demo-bin"]["alt"], "demo")

    def test_legacy_about_does_not_read_alt_as_plugin_data(self):
        source = SCRIPT.read_text(encoding="utf-8")
        trailer = 'main "$@"\n'
        self.assertTrue(source.endswith(trailer))
        with tempfile.TemporaryDirectory() as tmp:
            meta = Path(tmp) / "search_meta"
            meta.write_text(
                "|".join([
                    "demo", "app", "", "1.5", "2", "1700000000", "",
                    "plugin-one,plugin-two", "demo",
                ]) + "\n",
                encoding="utf-8",
            )
            script = Path(tmp) / "about.sh"
            script.write_text(
                source[:-len(trailer)] + "\nR_KEYS=()\nTMP=$1\npm_about demo\n",
                encoding="utf-8",
            )
            result = subprocess.run(
                ["bash", str(script), tmp], capture_output=True, text=True,
                timeout=10, check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Add-ons:     2 plugin(s)", result.stdout)
        self.assertIn("plugin-one, plugin-two", result.stdout)
        self.assertNotIn("plugin-two|demo", result.stdout)

    def test_variant_family_normalizes_base_and_supported_suffixes(self):
        for name, expected in (
            ("demo", "demo"), ("demo-bin", "demo"), ("demo-git", "demo"),
            ("demo-svn", "demo"), ("demo-hg", "demo"), ("demo-bzr", "demo"),
            ("demo-source", "demo-source"),
        ):
            with self.subTest(name=name):
                self.assertEqual(self.lib["variant_family"](self.record(name)), expected)
        split = self.record("demo-cli", package_base="demo-git")
        self.assertEqual(self.lib["variant_family"](split), "demo")


if __name__ == "__main__":
    unittest.main()
