import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from _helpers import load_library


class ClosureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load_library()

    def close(self, records, selected, installed=(), candidates=None):
        return self.lib["close_selection"](
            records, selected, set(installed), candidates or {}
        )

    def test_installed_core_satisfies_requirement(self):
        result = self.close(
            {"aur:plugin": {"name": "plugin", "parent": "coreapp", "conflicts": []}},
            ["aur:plugin"], {"coreapp"}, {"coreapp": ["repo:coreapp"]},
        )
        self.assertEqual(result["selected"], ["aur:plugin"])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["notices"], [])

    def test_missing_core_adds_canonical_key_and_exact_notice(self):
        result = self.close(
            {
                "aur:plugin": {"name": "plugin", "parent": "coreapp", "conflicts": []},
                "repo:coreapp": {"name": "coreapp", "parent": "", "conflicts": []},
            },
            ["aur:plugin"], candidates={"coreapp": ["repo:coreapp"]},
        )
        self.assertEqual(result["selected"], ["aur:plugin", "repo:coreapp"])
        self.assertEqual(result["added"], ["repo:coreapp"])
        self.assertEqual(result["notices"], ["Required core application coreapp was added"])
        self.assertEqual(result["unresolved"], [])

    def test_missing_shared_core_is_added_once(self):
        records = {
            "aur:one-plugin": {"name": "one-plugin", "parent": "coreapp", "conflicts": []},
            "aur:two-plugin": {"name": "two-plugin", "parent": "coreapp", "conflicts": []},
            "repo:coreapp": {"name": "coreapp", "parent": "", "conflicts": []},
        }
        result = self.close(
            records, ["aur:one-plugin", "aur:two-plugin"],
            candidates={"coreapp": ["repo:coreapp"]},
        )
        self.assertEqual(
            result["selected"],
            ["aur:one-plugin", "aur:two-plugin", "repo:coreapp"],
        )
        self.assertEqual(result["added"], ["repo:coreapp"])
        self.assertEqual(result["notices"], ["Required core application coreapp was added"])
        self.assertEqual(result["conflicts"], [])

    def test_transitive_plugin_core_chain_is_breadth_first_and_terminates(self):
        records = {
            "aur:plugin": {"name": "plugin", "parent": "middle", "conflicts": []},
            "repo:middle": {"name": "middle", "parent": "root", "conflicts": []},
            "repo:root": {"name": "root", "parent": "", "conflicts": []},
        }
        result = self.close(
            records, ["aur:plugin"],
            candidates={"middle": ["repo:middle"], "root": ["repo:root"]},
        )
        self.assertEqual(
            result["selected"], ["aur:plugin", "repo:middle", "repo:root"]
        )
        self.assertEqual(result["added"], ["repo:middle", "repo:root"])
        self.assertEqual(
            result["notices"],
            [
                "Required core application middle was added",
                "Required core application root was added",
            ],
        )

    def test_plugin_core_cycles_terminate_without_duplicates(self):
        records = {
            "aur:one": {"name": "one", "parent": "two", "conflicts": []},
            "repo:two": {"name": "two", "parent": "one", "conflicts": []},
        }
        result = self.close(
            records, ["aur:one"], candidates={"two": ["repo:two"], "one": ["aur:one"]}
        )
        self.assertEqual(result["selected"], ["aur:one", "repo:two"])
        self.assertEqual(result["added"], ["repo:two"])
        self.assertEqual(result["unresolved"], [])

    def test_ambiguous_providers_require_an_explicit_choice(self):
        records = {
            "aur:plugin": {"name": "plugin", "parent": "coreapp", "conflicts": []},
            "repo:z-provider": {"name": "z-provider", "parent": "", "conflicts": []},
            "repo:a-provider": {"name": "a-provider", "parent": "", "conflicts": []},
        }
        result = self.close(
            records, ["aur:plugin"],
            candidates={"coreapp": ["repo:z-provider", "repo:a-provider"]},
        )
        self.assertEqual(result["selected"], ["aur:plugin"])
        self.assertEqual(result["added"], [])
        self.assertEqual(
            result["ambiguous"],
            [{"parent": "coreapp", "candidates": ["repo:z-provider", "repo:a-provider"]}],
        )

    def test_unresolved_parent_keeps_plugin_and_reports_exact_parent(self):
        result = self.close(
            {"aur:plugin": {"name": "plugin", "parent": "missing-core", "conflicts": []}},
            ["aur:plugin"],
        )
        self.assertEqual(result["selected"], ["aur:plugin"])
        self.assertEqual(result["unresolved"], ["missing-core"])
        self.assertEqual(result["added"], [])

    def test_actual_conflicts_are_unique_sorted_pairs(self):
        records = {
            "repo:one": {"name": "one", "parent": "", "conflicts": ["two>=2"]},
            "aur:two": {"name": "two", "parent": "", "conflicts": ["one"]},
        }
        result = self.close(records, ["repo:one", "aur:two"])
        self.assertEqual(result["conflicts"], [("one", "two")])

    def test_conflicts_match_provided_identities_symmetrically_and_strip_versions(self):
        cases = (
            (
                {"name": "one", "provides": ["one-api=1"], "conflicts": ["two-api>=2"]},
                {"name": "two", "provides": ["two-api=2"], "conflicts": []},
            ),
            (
                {"name": "one", "provides": ["one-api=1"], "conflicts": []},
                {"name": "two", "provides": ["two-api=2"], "conflicts": ["one-api<=1"]},
            ),
        )
        for first, second in cases:
            with self.subTest(first=first, second=second):
                records = {"repo:one": first, "aur:two": second}
                result = self.close(records, ["repo:one", "aur:two"])
                self.assertEqual(result["conflicts"], [("one", "two")])

    def test_compatible_name_family_members_do_not_conflict(self):
        records = {
            "repo:demo": {"name": "demo", "parent": "", "conflicts": []},
            "aur:demo-git": {"name": "demo-git", "parent": "", "conflicts": []},
            "aur:demo-bin": {"name": "demo-bin", "parent": "", "conflicts": []},
        }
        result = self.close(records, list(records))
        self.assertEqual(result["conflicts"], [])

    def test_core_candidates_use_current_names_and_provides_in_record_order(self):
        records = {
            "aur:plugin": {"name": "plugin", "parent": "virtual-core", "provides": []},
            "repo:z": {"name": "z", "parent": "", "provides": ["virtual-core=1"]},
            "aur:a": {"name": "a", "parent": "", "provides": ["virtual-core"]},
            "repo:other": {"name": "other", "parent": "", "provides": []},
        }
        candidates = self.lib["build_core_candidates"](records, set())
        self.assertEqual(candidates["virtual-core"], ["repo:z", "aur:a"])

    def test_installed_provider_satisfies_virtual_core(self):
        records = {
            "aur:plugin": {"name": "plugin", "parent": "virtual-core", "provides": []},
            "repo:provider": {
                "name": "provider", "parent": "", "provides": ["virtual-core=1"],
                "installed": True,
            },
        }
        installed = self.lib["installed_requirements"](records, {"provider"})
        result = self.close(
            records, ["aur:plugin"], installed,
            self.lib["build_core_candidates"](records, installed),
        )
        self.assertEqual(result["selected"], ["aur:plugin"])
        self.assertEqual(result["added"], [])

    def test_normalized_records_merge_classifier_parent_and_category(self):
        normalized = {
            "aur:plugin": self.lib["new_package"]("plugin"),
            "repo:coreapp": self.lib["new_package"]("coreapp"),
        }
        normalized["aur:plugin"]["source"] = "aur"
        normalized["repo:coreapp"]["source"] = "repo"
        normalized["repo:coreapp"]["installed"] = False
        with tempfile.TemporaryDirectory() as tmp:
            meta = Path(tmp) / "search_meta"
            meta.write_text(
                "plugin|plugin|coreapp|||||\ncoreapp|app||||||\n",
                encoding="utf-8",
            )
            with patch.dict(self.lib, {"fetch_details": lambda requests: normalized}):
                records = self.lib["selection_records"](
                    [("aur", "plugin"), ("repo", "coreapp")], tmp, str(meta), set()
                )
        self.assertEqual(records["aur:plugin"]["parent"], "coreapp")
        self.assertEqual(records["aur:plugin"]["category"], "plugin")
        self.assertEqual(records["repo:coreapp"]["parent"], "")

    def test_no_search_meta_preserves_all_normalized_fields(self):
        normalized = self.lib["new_package"]("plugin")
        normalized.update({
            "source": "aur", "repository": "AUR", "parent": "coreapp",
            "depends": ["coreapp>=1"], "provides": ["plugin-api=1"],
            "conflicts": ["other-plugin"],
        })
        with tempfile.TemporaryDirectory() as tmp:
            missing_meta = str(Path(tmp) / "absent-search-meta")
            loader = Mock(return_value={"aur:plugin": normalized})
            with patch.dict(self.lib, {"fetch_details": loader}):
                records = self.lib["selection_records"](
                    [("aur", "plugin")], tmp, missing_meta, set()
                )
        self.assertEqual(records["aur:plugin"]["parent"], "coreapp")
        self.assertEqual(records["aur:plugin"]["depends"], ["coreapp>=1"])
        self.assertEqual(records["aur:plugin"]["provides"], ["plugin-api=1"])
        self.assertEqual(records["aur:plugin"]["conflicts"], ["other-plugin"])
        self.assertEqual(loader.call_count, 1)

    def test_empty_classifier_parent_does_not_erase_normalized_parent(self):
        normalized = self.lib["new_package"]("plugin")
        normalized.update({"source": "aur", "parent": "coreapp", "depends": ["coreapp"]})
        with tempfile.TemporaryDirectory() as tmp:
            meta = Path(tmp) / "search_meta"
            meta.write_text("plugin|plugin||||||\n", encoding="utf-8")
            with patch.dict(self.lib, {"fetch_details": lambda requests: {"aur:plugin": normalized}}):
                records = self.lib["selection_records"](
                    [("aur", "plugin")], tmp, str(meta), set()
                )
        self.assertEqual(records["aur:plugin"]["category"], "plugin")
        self.assertEqual(records["aur:plugin"]["parent"], "coreapp")
        self.assertEqual(records["aur:plugin"]["depends"], ["coreapp"])

    def test_unknown_official_record_does_not_invent_extra_repository(self):
        unknown = self.lib["unknown_package"]("repo", "missing")
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(self.lib, {"fetch_details": lambda requests: {"repo:missing": unknown}}):
                records = self.lib["selection_records"](
                    [("repo", "missing")], tmp, str(Path(tmp) / "missing-meta"), set()
                )
        self.assertIsNone(records["repo:missing"]["repository"])
        self.assertIn("repository", records["repo:missing"]["_unavailable"])

    def test_unknown_package_marks_closure_critical_fields_unavailable(self):
        record = self.lib["unknown_package"]("repo", "middle")
        for field in ("depends", "provides", "conflicts", "parent"):
            self.assertIsNone(record[field], field)
            self.assertIn(field, record["_unavailable"])
        records = {"repo:middle": record}
        self.assertEqual(self.lib["build_core_candidates"](records, set()), {})
        closed = self.close(records, ["repo:middle"])
        self.assertEqual(closed["conflicts"], [])

    def test_unknown_virtual_provider_fails_dependent_evaluation(self):
        middle = self.lib["unknown_package"]("repo", "middle")
        middle["parent"] = "root"
        root = self.lib["new_package"]("root")
        plugin = self.lib["new_package"]("plugin")
        plugin["parent"] = "virtual-core"
        records = {
            "repo:root": root,
            "repo:middle": middle,
            "aur:plugin": plugin,
        }
        selected = ["repo:root", "repo:middle", "aur:plugin"]
        candidates = self.lib["build_core_candidates"](records, set())
        with self.assertRaises(ValueError):
            self.lib["core_dependents"](
                records, selected, set(), candidates, "repo:middle"
            )

    def test_unknown_provides_allows_unmark_without_unknown_requirements(self):
        middle = self.lib["unknown_package"]("repo", "middle")
        middle["parent"] = "root"
        root = self.lib["new_package"]("root")
        records = {"repo:root": root, "repo:middle": middle}
        selected = ["repo:root", "repo:middle"]
        candidates = self.lib["build_core_candidates"](records, set())
        self.assertEqual(
            self.lib["core_dependents"](
                records, selected, set(), candidates, "repo:middle"
            ),
            [],
        )

    def test_core_unmark_guard_reports_direct_and_transitive_dependents(self):
        records = {
            "repo:core": {"name": "core", "parent": "", "provides": []},
            "repo:middle": {"name": "middle", "parent": "core", "provides": []},
            "aur:plugin": {"name": "plugin", "parent": "middle", "provides": []},
        }
        candidates = self.lib["build_core_candidates"](records, set())
        dependents = self.lib["core_dependents"](
            records, ["repo:core", "repo:middle", "aur:plugin"],
            set(), candidates, "repo:core",
        )
        self.assertEqual(dependents, ["repo:middle", "aur:plugin"])


if __name__ == "__main__":
    unittest.main()
