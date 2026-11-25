import unittest
from selection_harness import SelectionModel, run_action, run_frontend

class SelectionTests(unittest.TestCase):
    def test_sequential_marks_and_installed_guard(self):
        model = SelectionModel({"repo:one": False, "repo:two": False, "aur:old": True})
        self.assertTrue(model.toggle("repo:one"))
        self.assertTrue(model.toggle("repo:two"))
        self.assertEqual(model.keys, ["repo:one", "repo:two"])
        self.assertFalse(model.toggle("aur:old"))
        self.assertEqual(model.notice, "aur:old is already installed; choose Reinstall to install it again")
        self.assertTrue(model.toggle("aur:old", reinstall=True))

    def test_unmark_removes_only_that_key(self):
        model = SelectionModel({"repo:one": False, "repo:two": False})
        self.assertTrue(model.toggle("repo:one"))
        self.assertTrue(model.toggle("repo:two"))
        self.assertTrue(model.toggle("repo:one"))
        self.assertEqual(model.keys, ["repo:two"])

    def test_section_headings_cannot_be_marked(self):
        model = SelectionModel({"repo:one": False})
        self.assertFalse(model.toggle("@apps"))
        self.assertEqual(model.notice, "Section headings cannot be selected")
        self.assertEqual(model.keys, [])


class FrontendTests(unittest.TestCase):
    def test_classic_repeated_activation_toggles_without_leaving(self):
        for tool in ("dialog", "whiptail"):
            with self.subTest(tool=tool):
                result = run_frontend(tool, ["repo:one", "repo:two", "repo:one", "__install"])
                self.assertEqual(result["action"], "install", result["output"])
                self.assertEqual(result["keys"], ["repo:two"])
                self.assertIn("[ ]", result["calls"])
                self.assertIn("[✓]", result["calls"])
                self.assertIn("[installed]", result["calls"])
                self.assertIn("Details", result["calls"])
                self.assertIn("Compare", result["calls"])
                self.assertIn("Install marked", result["calls"])
                self.assertIn("Back", result["calls"])
                self.assertNotIn("<@apps>", result["calls"])

    def test_classic_reinstall_marks_installed_row_explicitly(self):
        result = run_frontend("dialog", ["aur:old", "__reinstall", "__install"])
        self.assertEqual(result["action"], "install", result["output"])
        self.assertEqual(result["keys"], ["aur:old"])
        self.assertIn("Reinstall", result["calls"])
        self.assertIn("[✓ installed]", result["calls"])

    def test_classic_details_preserve_marks_and_focus(self):
        result = run_frontend("dialog", ["repo:one", "repo:two", "__details"])
        self.assertEqual(result["action"], "details", result["output"])
        self.assertEqual(result["focus"], "repo:two")
        self.assertEqual(result["keys"], ["repo:one", "repo:two"])

    def test_installed_version_is_distinct_and_cached_across_redraws(self):
        cases = (
            ("dialog", ["repo:one", "__back"]),
            ("zenity", ["repo:one", "__back"]),
            ("plain", ["1", "q"]),
        )
        for mode, actions in cases:
            with self.subTest(mode=mode):
                result = run_frontend(mode, actions)
                text = result["output"] if mode == "plain" else result["calls"]
                self.assertIn("old 3.0", text)
                self.assertIn("installed version 0.9-1", text)
                self.assertIn("AUR", text)
                self.assertIn("Installed package", text)
                self.assertEqual(result["queries"].splitlines().count("Q old"), 1)

    def test_zenity_compare_preserves_marks_and_uses_literal_markers(self):
        result = run_frontend("zenity", ["repo:one", "repo:two", "__compare"])
        self.assertEqual(result["action"], "compare", result["output"])
        self.assertEqual(result["keys"], ["repo:one", "repo:two"])
        self.assertIn("[ ]", result["calls"])
        self.assertIn("[✓]", result["calls"])
        self.assertIn("[installed]", result["calls"])
        self.assertNotIn("[OK]", result["calls"])
        self.assertNotIn("<@apps>", result["calls"])

    def test_plain_ranges_details_reinstall_and_submission(self):
        result = run_frontend("plain", ["1-2", "+1", "-1", "d 2"])
        self.assertEqual(result["action"], "details", result["output"])
        self.assertEqual(result["focus"], "repo:two")
        self.assertEqual(result["keys"], ["repo:two"])
        self.assertIn("[✓]", result["output"])
        self.assertIn("[installed]", result["output"])
        result = run_frontend("plain", ["r 3", "i"])
        self.assertEqual(result["action"], "install", result["output"])
        self.assertEqual(result["keys"], ["aur:old"])
        self.assertIn("[✓ installed]", result["output"])

    def test_plain_comma_list_accumulates_marks(self):
        result = run_frontend("plain", ["1,2", "d 1"])
        self.assertEqual(result["action"], "details", result["output"])
        self.assertEqual(result["keys"], ["repo:one", "repo:two"])

    def test_plain_empty_install_does_not_submit(self):
        result = run_frontend("plain", ["i", "q"])
        self.assertEqual(result["action"], "back", result["output"])
        self.assertEqual(result["keys"], [])

    def test_plain_reinstall_refuses_a_noninstalled_row(self):
        result = run_frontend("plain", ["r 1", "q"])
        self.assertEqual(result["action"], "back", result["output"])
        self.assertEqual(result["keys"], [])
        self.assertIn("use +N", result["notice"])

    def test_gui_reinstall_marks_installed_focus_when_offered(self):
        result = run_frontend("zenity", ["aur:old", "__reinstall", "__install"])
        self.assertEqual(result["action"], "install", result["output"])
        self.assertEqual(result["keys"], ["aur:old"])
        self.assertIn("<__reinstall>", result["calls"])
        self.assertIn("[✓ installed]", result["calls"])

    def test_defensive_unoffered_reinstall_uses_activation_wording(self):
        result = run_frontend("zenity", ["__reinstall", "__back"])
        self.assertEqual(result["keys"], [])
        self.assertIn("activate the package row", result["notice"])
        self.assertNotIn("Space", result["notice"])


class ActionFlowTests(unittest.TestCase):
    def test_details_use_task2_renderer_and_preserve_selection(self):
        result = run_action(["1", "2", "d 1", "q"])
        self.assertEqual(result["keys"], ["repo:one", "repo:two"], result["output"])
        self.assertIn("Package details: one", result["dialogs"])
        self.assertIn("Package: one 1.0-1", result["dialogs"])
        self.assertIn("Repository: extra", result["dialogs"])
        self.assertEqual(result["installer"], "")
        self.assertEqual(result["calls"], "")
        self.assertEqual(len(result["cache"]), 1)

    def test_failed_metadata_preserves_marks(self):
        result = run_action(["1", "2", "d 1", "q"], details_fail=True)
        self.assertEqual(result["keys"], ["repo:one", "repo:two"], result["output"])
        self.assertIn("Package details: one", result["dialogs"])
        self.assertEqual(result["installer"], "")

    def test_optional_extras_preserve_marks(self):
        result = run_action(["1", "i", "2"], extras=True)
        self.assertEqual(result["keys"], ["repo:one"], result["output"])
        self.assertIn("<Install> <Extras…> <Cancel>", result["dialogs"])
        self.assertEqual(result["installer"].count("pm_install_plan repo one"), 2)
        self.assertNotIn("pm_run_logged", result["installer"])

    def test_declining_new_search_preserves_marks_and_skips_search(self):
        result = run_action(["q"], initial_marks=["repo:one"], search_confirm=False)
        self.assertEqual(result["keys"], ["repo:one"], result["output"])
        self.assertIn("ui_ask", result["search"])
        self.assertNotIn("pm_search", result["search"])
        self.assertEqual(result["installer"], "")

    def test_accepting_new_search_clears_marks_after_confirmation(self):
        result = run_action(["q"], initial_marks=["repo:one"], search_confirm=True)
        self.assertEqual(result["keys"], [], result["output"])
        self.assertIn("ui_ask", result["search"])
        self.assertIn("pm_search", result["search"])
        self.assertLess(result["search"].index("ui_ask"), result["search"].index("pm_search"))

    def test_empty_selection_needs_no_new_search_confirmation(self):
        result = run_action(["q"], search_confirm=False)
        self.assertNotIn("ui_ask", result["search"])
        self.assertIn("pm_search", result["search"])

    def test_grouped_install_cancel_keeps_marks_without_a_transaction(self):
        result = run_action(["1", "2", "i", "q"])
        self.assertEqual(result["keys"], ["repo:one", "repo:two"], result["output"])
        self.assertIn("Install 2 marked packages", result["dialogs"])
        self.assertIn("Selected applications:", result["dialogs"])
        self.assertIn("repo:one", result["dialogs"])
        self.assertIn("repo:two", result["dialogs"])
        self.assertIn("pm_choose_installer repo", result["installer"])
        self.assertEqual(result["installer"].count("pm_install_plan"), 2)
        self.assertNotIn("pm_run_logged", result["installer"])
        self.assertNotIn("ensure_sudo", result["installer"])
        self.assertNotIn("not yet implemented", result["dialogs"])

    def test_compare_is_complete_and_non_mutating(self):
        result = run_action(["1", "c 1", "q", "q"], variants=True)
        self.assertEqual(result["keys"], ["repo:one"], result["output"])
        self.assertIn("Compare package variants", result["output"])
        self.assertIn("Recommended (advisory): aur:one-bin", result["output"])
        self.assertIn("binary repackaging (inferred from -bin)", result["output"])
        self.assertIn("VCS/development (inferred from -git)", result["output"])
        self.assertIn("AUR votes: 30", result["output"])
        self.assertIn("pkgstats popularity: 1.25", result["output"])
        self.assertIn("Build-only requirements: git", result["output"])
        self.assertIn("Conflicts with:", result["output"])
        self.assertNotIn("not yet implemented", result["output"])
        self.assertEqual(result["installer"], "")

    def test_recommendation_highlight_does_not_preselect_or_install(self):
        result = run_action(["c 1", "2", "q"], variants=True)
        self.assertEqual(result["keys"], [], result["output"])
        self.assertIn("Variant: one-bin", result["dialogs"])
        self.assertIn("<Use this variant> <Back>", result["dialogs"])
        self.assertNotIn("pm_run_logged", result["installer"])
        self.assertNotIn("pm_install_plan", result["installer"])

    def test_use_this_variant_replaces_only_family_marks(self):
        result = run_action(
            ["2", "5", "c 1", "2", "q"], variants=True, use_variant=True
        )
        self.assertEqual(result["keys"], ["aur:one-bin", "repo:two"], result["output"])
        self.assertNotIn("pm_run_logged", result["installer"])
        self.assertNotIn("pm_install_plan", result["installer"])

    def test_use_variant_rolls_back_when_core_guard_blocks(self):
        result = run_action(
            ["2", "5", "c 1", "2", "q"], variants=True,
            use_variant=True, variant_core=True,
        )
        self.assertEqual(result["keys"], ["aur:one-git", "repo:two"], result["output"])
        self.assertIn("Cannot unmark required core application one-git", result["dialogs"])
        self.assertNotIn("aur:one-bin", result["keys"])
        self.assertEqual(result["installer"], "")

    def test_use_installed_variant_retains_reinstall_guard(self):
        result = run_action(["1", "c 3", "1", "q"], use_variant=True)
        self.assertEqual(result["keys"], ["repo:one"], result["output"])
        self.assertIn("already installed; choose Reinstall", result["dialogs"])
        self.assertEqual(result["installer"], "")

    def test_explicit_reinstall_does_not_use_needed(self):
        result = run_action(["r 3", "i", "q"], confirm=True)
        self.assertEqual(result["keys"], [], result["output"])
        self.assertIn("pm_run_logged", result["installer"], result["output"])
        command = next(line for line in result["installer"].splitlines() if line.startswith("pm_run_logged"))
        self.assertIn("paru -S", command)
        self.assertIn(" old", command)
        self.assertNotIn("--needed", command)

    def test_single_mark_still_uses_existing_preview_and_confirmation(self):
        result = run_action(["1", "i"])
        self.assertIn("pm_choose_installer repo", result["installer"])
        self.assertIn("pm_install_plan repo one", result["installer"])
        self.assertIn("Install one", result["dialogs"])
        self.assertIn("Preview for one", result["dialogs"])
        self.assertIn("<Install> <Cancel>", result["dialogs"])
        self.assertNotIn("pm_run_logged", result["installer"])
        self.assertNotIn("ensure_sudo", result["installer"])


if __name__ == "__main__":
    unittest.main()
