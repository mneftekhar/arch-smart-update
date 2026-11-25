import copy
import json
import unittest

from _helpers import load_library
from selection_harness import run_action


class SimilarTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load_library()

    def record(self, name, **changes):
        record = self.lib["new_package"](name)
        record.update({
            "source": "aur",
            "repository": "AUR",
            "package_base": name,
            "version": "1.0-1",
            "description": "",
            "updated": 100,
            "votes": 10,
            "popularity": 1.0,
        })
        record.update(changes)
        return record

    def test_significant_words_uses_exact_tokenizer_and_stop_words(self):
        text = (
            "A program application tool utility package Linux Arch free open source "
            "for with and the that this C++ raster photo_one x-y z 2D"
        )
        self.assertEqual(
            self.lib["significant_words"](text),
            {"c++", "raster", "photo_one", "x-y", "2d"},
        )

    def test_shared_keyword_beats_generic_description(self):
        target = self.record(
            "photo-one", keywords=["photography"], description="Raster editor",
            updated=10, votes=1, popularity=0,
        )
        related = self.record(
            "photo-two", keywords=["photography"], description="Image effects",
            updated=20, votes=5, popularity=1,
        )
        generic = self.record(
            "writer", description="A program for notes",
            updated=100, votes=100, popularity=50,
        )
        result = self.lib["similar_packages"](target, [target, related, generic])
        self.assertEqual([row["name"] for row in result], ["photo-two"])
        self.assertEqual(result[0]["reason"], "Shared keyword: photography")
        self.assertEqual(result[0]["similarity_score"], 7)

    def test_generic_stop_word_only_matches_do_not_suggest(self):
        target = self.record(
            "one", description="program application tool utility package linux arch free open source"
        )
        generic = self.record(
            "two", description="A program and application with the tool for this package"
        )
        self.assertEqual(self.lib["similar_packages"](target, [generic]), [])

    def test_shared_group_and_description_token_meet_threshold(self):
        target = self.record(
            "editor-one", groups=["video-editors"], description="Timeline editor"
        )
        related = self.record(
            "editor-two", groups=["video-editors"], description="Timeline effects"
        )
        group_only = self.record("editor-three", groups=["video-editors"])
        result = self.lib["similar_packages"](target, [related, group_only])
        self.assertEqual([row["name"] for row in result], ["editor-two"])
        self.assertEqual(result[0]["reason"], "Same group: video-editors")
        self.assertEqual(result[0]["similarity_score"], 7)

    def test_description_evidence_has_exact_threshold(self):
        target = self.record("one", description="raster layers masks filters")
        three = self.record("three", description="raster layers masks")
        two = self.record("two", description="raster layers")
        different_category = self.record(
            "other-category", description="raster layers masks", category="look"
        )
        result = self.lib["similar_packages"](
            target, [two, different_category, three]
        )
        scores = {row["name"]: row["similarity_score"] for row in result}
        self.assertEqual(scores, {"other-category": 6, "three": 7})
        self.assertEqual(
            result[0]["reason"],
            "Shared description terms: layers, masks, raster",
        )

    def test_description_contribution_is_capped_at_six(self):
        target = self.record(
            "one", description="alpha bravo charlie delta echo foxtrot golf hotel"
        )
        related = self.record(
            "two", description="alpha bravo charlie delta echo foxtrot golf hotel extra"
        )
        result = self.lib["similar_packages"](target, [related])
        self.assertEqual(result[0]["similarity_score"], 7)

    def test_score_is_exact_for_every_evidence_type(self):
        target = self.record(
            "one", keywords=["raw", "photography"], groups=["media", "editors"],
            description="raster layers masks filters color cropping",
        )
        related = self.record(
            "two", keywords=["photography", "raw"], groups=["editors", "media"],
            description="cropping color filters masks layers raster extras",
        )
        row = self.lib["similar_packages"](target, [related])[0]
        self.assertEqual(row["similarity_score"], 27)
        self.assertEqual(row["reason"], "Shared keyword: photography, raw")

    def test_excludes_identity_variants_libraries_and_documentation(self):
        target = self.record("photo-one", keywords=["photography"])
        candidates = [
            target,
            self.record("photo-one", source="repo", keywords=["photography"]),
            self.record("photo-one-bin", keywords=["photography"]),
            self.record("photo-lib", keywords=["photography"], category="lib"),
            self.record("photo-docs", keywords=["photography"], category="other"),
            self.record("photo-manual", keywords=["photography"], category="documentation"),
            self.record("photo-help", keywords=["photography"], category="lang"),
            self.record("photo-two", keywords=["photography"]),
        ]
        result = self.lib["similar_packages"](target, candidates)
        self.assertEqual([row["name"] for row in result], ["photo-two"])

    def test_exact_duplicate_candidates_are_returned_once(self):
        target = self.record("one", keywords=["photography"])
        related = self.record("two", keywords=["photography"])
        result = self.lib["similar_packages"](
            target, [related, copy.deepcopy(related), dict(related)]
        )
        self.assertEqual([row["name"] for row in result], ["two"])

    def test_unrelated_rows_are_not_suggested_by_category_alone(self):
        target = self.record("one", description="Raster editor")
        unrelated = self.record("two", description="Vector animation")
        self.assertEqual(self.lib["similar_packages"](target, [unrelated]), [])

    def test_results_are_limited_to_five(self):
        target = self.record("target", keywords=["photography"])
        candidates = [
            self.record("candidate-%d" % index, keywords=["photography"])
            for index in range(8)
        ]
        result = self.lib["similar_packages"](target, candidates)
        self.assertEqual(len(result), 5)
        self.assertEqual(
            [row["name"] for row in result],
            ["candidate-%d" % index for index in range(5)],
        )

    def test_higher_score_outranks_a_recent_weak_match(self):
        target = self.record(
            "target", keywords=["photography"], description="raster layers masks"
        )
        strong = self.record("strong-old", keywords=["photography"], updated=1)
        weak = self.record(
            "weak-new", description="raster layers masks", updated=999, category="look"
        )
        result = self.lib["similar_packages"](target, [weak, strong])
        self.assertEqual([row["name"] for row in result], ["strong-old", "weak-new"])

    def test_order_uses_update_votes_popularity_then_name(self):
        target = self.record("target", keywords=["photography"])
        rows = [
            self.record("new", keywords=["photography"], updated=50, votes=1),
            self.record("votes", keywords=["photography"], updated=20, votes=20),
            self.record("popularity", keywords=["photography"], updated=20, votes=10, popularity=5),
            self.record("name-b", keywords=["photography"], updated=20, votes=10, popularity=2),
            self.record("name-a", keywords=["photography"], updated=20, votes=10, popularity=2),
        ]
        expected = ["new", "votes", "popularity", "name-a", "name-b"]
        first = self.lib["similar_packages"](target, rows)
        second = self.lib["similar_packages"](target, list(reversed(rows)))
        self.assertEqual([row["name"] for row in first], expected)
        self.assertEqual([row["name"] for row in second], expected)
        self.assertEqual(first, second)

    def test_installed_alternative_keeps_identity_and_version(self):
        target = self.record("one", keywords=["photography"])
        installed = self.record(
            "two", keywords=["photography"], installed=True,
            installed_version="0.9-1", version="1.0-1",
        )
        row = self.lib["similar_packages"](target, [installed])[0]
        self.assertTrue(row["installed"])
        self.assertEqual(row["installed_version"], "0.9-1")
        self.assertEqual(row["version"], "1.0-1")

    def test_cached_records_are_not_mutated(self):
        target = self.record("one", keywords=["photography"])
        candidate = self.record(
            "two", keywords=["photography"], depends=["gtk4"], groups=["media"]
        )
        candidates = [target, candidate]
        snapshot = copy.deepcopy(candidates)
        row = self.lib["similar_packages"](target, candidates)[0]
        self.assertEqual(candidates, snapshot)
        self.assertIsNot(row, candidate)
        self.assertEqual(
            set(row) - set(candidate), {"reason", "similarity_score"}
        )


class SimilarActionFlowTests(unittest.TestCase):
    def test_details_show_evidence_and_preserve_existing_marks(self):
        result = run_action(["2", "d 1", "q", "q"], similar="current")
        self.assertEqual(result["keys"], ["aur:two"], result["output"])
        self.assertEqual(result["selection_order"], ["aur:two"])
        self.assertEqual(result["similar_keys"], ["aur:two", "aur:old"])
        self.assertEqual(
            result["similar_reasons"],
            {"aur:two": "Shared keyword: photography", "aur:old": "Shared keyword: photography"},
        )
        self.assertIn("<Similar apps> <Back>", result["dialogs"])
        self.assertIn("Shared keyword: photography", result["output"])
        self.assertIn("[installed]", result["output"])
        self.assertIn("installed version 0.9-1", result["output"])
        self.assertEqual(result["search"].splitlines(), ["pm_search demo"])
        self.assertEqual(result["installer"], "")
        self.assertGreaterEqual(result["output"].count("Results for 'demo'"), 2)

    def test_suggestion_details_and_compare_do_not_auto_mark(self):
        result = run_action(
            ["d 1", "d 1", "c 1", "1", "q", "q"], similar="current"
        )
        self.assertEqual(result["keys"], [], result["output"])
        self.assertIn("Package details: two", result["dialogs"])
        self.assertIn("Compare package variants", result["output"])
        self.assertEqual(result["installer"], "")

    def test_two_level_similar_details_back_restores_prior_suggestions(self):
        result = run_action(
            ["d 1", "d 1", "q", "q", "q"],
            similar="current",
            nested_similar=True,
        )
        output = result["output"]
        self.assertEqual(result["keys"], [], output)
        self.assertEqual(result["search"].splitlines(), ["pm_search demo"])
        self.assertEqual(result["installer"], "")
        self.assertIn("Package details: two", result["dialogs"])
        self.assertIn("Similar apps for two", output)
        self.assertGreaterEqual(output.count("Similar apps for one"), 2)
        self.assertLess(output.index("Similar apps for one"), output.index("Similar apps for two"))
        self.assertLess(output.index("Similar apps for two"), output.rindex("Similar apps for one"))
        self.assertLess(output.rindex("Similar apps for one"), output.rindex("Results for 'demo'"))
        self.assertEqual(
            result["similar_reasons"],
            {"aur:two": "Shared keyword: photography", "aur:old": "Shared keyword: photography"},
        )

    def test_suggestion_uses_normal_aggregated_install_flow(self):
        result = run_action(["d 1", "1", "i"], similar="current")
        self.assertEqual(result["keys"], ["aur:two"], result["output"])
        self.assertIn("pm_choose_installer aur\n", result["installer"])
        self.assertIn("pm_install_plan aur two", result["installer"])
        self.assertNotIn("pm_run_logged", result["installer"])

    def test_installed_suggestion_keeps_reinstall_guard(self):
        result = run_action(["d 1", "2", "q", "q"], similar="current")
        self.assertEqual(result["keys"], [], result["output"])
        self.assertIn("already installed; choose Reinstall", result["output"])
        self.assertEqual(result["installer"], "")

    def test_one_fallback_merges_records_and_preserves_search_context(self):
        result = run_action(["2", "d 1", "q", "q"], similar="followup")
        self.assertEqual(result["keys"], ["aur:two"], result["output"])
        self.assertEqual(result["selection_order"], ["aur:two"])
        self.assertEqual(result["similar_keys"], ["aur:three"])
        self.assertEqual(
            result["similar_reasons"], {"aur:three": "Shared keyword: photography"}
        )
        self.assertEqual(
            result["search"].splitlines(), ["pm_search demo", "pm_search photography"]
        )
        self.assertTrue(
            {"aur:one", "aur:two", "aur:old", "aur:three"}.issubset(
                result["result_keys"]
            )
        )
        for name in ("one", "two", "old", "three"):
            self.assertIn(name + "|app|", result["result_meta"])
        self.assertIn("Raster photography editor", result["result_labels"])
        self.assertEqual(result["installer"], "")

    def test_fallback_preserves_original_normalized_summary_context(self):
        result = run_action(["2", "d 1", "q", "q"], similar="followup")
        records = [json.loads(line) for line in result["result_jsonl"].splitlines()]
        identities = {record["source"] + ":" + record["name"] for record in records}
        self.assertEqual(identities, {"aur:one", "aur:two", "aur:old", "aur:three"})
        shares = {record["name"]: record["user_share"] for record in records}
        self.assertEqual(shares, {"one": 1.5, "two": 2.5, "old": 0.5, "three": 3.5})

    def test_empty_fallback_has_exact_message_and_one_search_bound(self):
        result = run_action(["2", "d 1", "q", "q"], similar="empty")
        self.assertEqual(result["keys"], ["aur:two"], result["output"])
        self.assertEqual(result["selection_order"], ["aur:two"])
        self.assertEqual(result["similar_keys"], [])
        self.assertEqual(
            result["search"].splitlines(), ["pm_search demo", "pm_search photography"]
        )
        self.assertEqual(
            result["dialogs"].count("No reliable similar applications found"), 1
        )
        self.assertNotIn("Similar apps for", result["output"])
        self.assertTrue({"aur:one", "aur:two", "aur:old"}.issubset(result["result_keys"]))
        self.assertEqual(result["installer"], "")

    def test_failed_fallback_restores_original_results_and_metadata(self):
        result = run_action(["2", "d 1", "q", "q"], similar="failed")
        self.assertEqual(result["keys"], ["aur:two"], result["output"])
        self.assertEqual(result["similar_keys"], [])
        self.assertEqual(
            result["result_keys"], ["@apps", "aur:one", "aur:two", "aur:old"]
        )
        for name in ("one", "two", "old"):
            self.assertIn(name + "|app|", result["result_meta"])
        self.assertIn("Raster photography editor", result["result_labels"])
        self.assertIn("No reliable similar applications found", result["dialogs"])
        self.assertEqual(result["installer"], "")


if __name__ == "__main__":
    unittest.main()
