import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
import urllib.parse
from pathlib import Path

from _helpers import SCRIPT


def sync_desc(name, version, provides):
    return (
        f"%NAME%\n{name}\n\n"
        f"%VERSION%\n{version}\n\n"
        f"%PROVIDES%\n{provides}\n"
    )


def run_harness(body, installed=(), detail_records=None, search_meta=None, sync_dbs=None):
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        runtime = root / "runtime"
        runtime.mkdir()
        if search_meta is not None:
            (runtime / "search_meta").write_text(search_meta, encoding="utf-8")
        for db_name, descriptions in (sync_dbs or {}).items():
            db_path = runtime / "db" / "sync" / db_name
            db_path.parent.mkdir(parents=True, exist_ok=True)
            with tarfile.open(db_path, "w:gz") as archive:
                for index, description in enumerate(descriptions):
                    payload = description.encode("utf-8")
                    entry = tarfile.TarInfo(f"entry-{index}/desc")
                    entry.size = len(payload)
                    archive.addfile(entry, io.BytesIO(payload))
        for key, record in (detail_records or {}).items():
            directory = runtime / "package-details"
            directory.mkdir(exist_ok=True)
            safe = urllib.parse.quote(key, safe="")
            (directory / (safe + ".json")).write_text(json.dumps(record), encoding="utf-8")
        harness = source[:-len(trailer)] + r'''
eval "$(declare -f pm_install_plan | sed '1s/pm_install_plan/pm_install_plan_real/')"
TMP=$TEST_TMP
HOME=$TEST_HOME
MENU_STYLE=plain
GUI=false
GUI_TOOL=""
PM_TOOL=paru
declare -a PM_SELECTION_ORDER=() PM_INSTALL_REPO=() PM_INSTALL_AUR=()
declare -A PM_AUTO_ADDED=() PM_REINSTALL=() PM_EXTRAS=() PM_EXTRA_SOURCE=()
pacman() {
    local name
    if [[ $1 == -Qq && $# -eq 1 ]]; then
        for name in $TEST_INSTALLED; do printf '%s\n' "$name"; done
        return 0
    fi
    if [[ $1 == -Qq ]]; then
        name=${!#}
        printf 'VERIFY %s\n' "$name" >>"$TEST_CALLS"
        [[ " $TEST_INSTALLED " == *" $name "* ]]
        return
    fi
    if [[ $1 == -Q ]]; then
        name=${!#}
        [[ " $TEST_INSTALLED " == *" $name "* ]] || return 1
        printf '%s 1.0-1\n' "$name"
        return 0
    fi
    printf 'UNEXPECTED_PACMAN %s\n' "$*" >>"$TEST_CALLS"
    return 1
}
pm_install_plan() {
    local kind=$1 name=$2 owner=$1:$2
    shift 2
    printf 'PLAN %s %s' "$kind" "$name" >>"$TEST_CALLS"
    printf ' <%s>' "$@" >>"$TEST_CALLS"
    printf '\n' >>"$TEST_CALLS"
    PLAN_TEXT="Preview for $name"
    PLAN_OPT=() PLAN_MAKE=() PLAN_ROWS=()
    case $name in
        one)
            PLAN_ROWS+=(
                "repo|one|1.0-1|extra|1024|selected|$owner"
                "repo|shared|2.0-1|extra|2048|dependency|$owner"
                "installed|installed-dep||||installed|$owner"
                "repo|extra-one|1.0-1|extra||optional|$owner"
            )
            PLAN_OPT=("extra-one|CLI")
            ;;
        two)
            PLAN_ROWS+=(
                "repo|two|1.0-1|extra|4096|selected|$owner"
                "repo|shared|2.0-1|extra|2048|dependency|$owner"
                "repo|extra-two|1.0-1|extra||optional|$owner"
            )
            PLAN_OPT=("extra-two|Tools")
            ;;
        plugin)
            PLAN_ROWS+=(
                "aur|plugin|1.0-1|AUR||selected|$owner"
                "repo|shared|2.0-1|extra|2048|dependency|$owner"
                "repo|meson|1.0-1|extra||build|$owner"
            )
            PLAN_MAKE=(meson)
            ;;
        roles)
            PLAN_ROWS+=(
                "aur|roles|1.0-1|AUR||selected|$owner"
                "repo|shared|2.0-1|extra|2048|dependency|$owner"
                "repo|shared|2.0-1|extra|512|extra|$owner"
                "repo|shared|2.0-1|extra|4096|build|$owner"
                "repo|build-only|1.0-1|extra|1024|build|$owner"
            )
            PLAN_MAKE=(shared build-only)
            ;;
        core)
            PLAN_ROWS+=("repo|core|1.0-1|extra|1024|selected|$owner") ;;
        chain)
            PLAN_ROWS+=(
                "aur|chain|1.0-1|AUR||selected|$owner"
                "repo|core||||dependency|$owner"
            )
            ;;
        bad)
            PLAN_TEXT="metadata failed for bad"
            return 1
            ;;
        *) PLAN_ROWS+=("$kind|$name||$([[ $kind == aur ]] && printf AUR || printf extra)||selected|$owner") ;;
    esac
    for name in "$@"; do
        PLAN_ROWS+=("$kind|$name|||$([[ $kind == aur ]] && printf AUR || printf extra)|512|extra|$owner")
    done
    return 0
}
pm_choose_installer() { PM_TOOL=paru; return 0; }
pm_run_logged() {
    local log=$1
    shift
    printf 'RUN %s' "$log" >>"$TEST_CALLS"
    printf ' <%s>' "$@" >>"$TEST_CALLS"
    printf '\n' >>"$TEST_CALLS"
    if [[ " $* " == *" paru "* ]]; then return "${TEST_AUR_RC:-0}"; fi
    return "${TEST_REPO_RC:-0}"
}
ensure_sudo() { printf 'SUDO\n' >>"$TEST_CALLS"; return 0; }
session_set() { return 0; }
log_info() { return 0; }
log_step() { return 0; }
log_success() { printf 'SUCCESS %s\n' "$*" >>"$TEST_CALLS"; }
log_error() { printf 'ERROR %s\n' "$*" >>"$TEST_CALLS"; }
log_warning() { printf 'WARNING %s\n' "$*" >>"$TEST_CALLS"; }
diagnose() { printf 'DIAGNOSE %s\n' "$*" >>"$TEST_CALLS"; }
report_diagnosis() { return 0; }
apply_fixes() { return 0; }
ui_ask() { return 1; }
ui_dialog() {
    {
        printf 'DIALOG <%s>\n' "$1"
        printf '%s\n' "$2"
        printf 'BUTTONS'
        shift 4
        printf ' <%s>' "$@"
        printf '\n'
    } >>"$TEST_DIALOGS"
    TUI_CHOICE=0
    return 0
}
print_marked() { printf '%s\n' "${!PM_MARKED[@]}" | sort | paste -sd' ' -; }
ui_choose() {
    if [[ $1 == "Optional extras" ]]; then
        if [[ ! -e $TEST_TMP/extra-choice ]]; then
            : >"$TEST_TMP/extra-choice"
            printf '%s\n' "$3"
        else
            rm -f "$TEST_TMP/extra-choice"
            printf '%s\n' done
        fi
        return 0
    fi
    return 1
}
'''
        harness += "\n" + body + "\n"
        script = root / "scenario.sh"
        script.write_text(harness, encoding="utf-8")
        calls = root / "calls"
        dialogs = root / "dialogs"
        env = os.environ.copy()
        env.update(
            TEST_TMP=str(runtime), TEST_HOME=str(root), TEST_CALLS=str(calls),
            TEST_DIALOGS=str(dialogs), TEST_INSTALLED=" ".join(installed),
            LC_ALL="C.UTF-8", TERM="xterm-256color",
        )
        result = subprocess.run(
            ["bash", str(script)], text=True, capture_output=True,
            env=env, timeout=20, check=False,
        )
        return {
            "returncode": result.returncode,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "calls": calls.read_text() if calls.exists() else "",
            "dialogs": dialogs.read_text() if dialogs.exists() else "",
        }


class BatchInstallTests(unittest.TestCase):
    def assert_clean(self, result):
        self.assertEqual(result["returncode"], 0, result["stderr"] + result["stdout"])
        self.assertEqual(result["stderr"], "", result["stderr"])
        self.assertNotIn("UNEXPECTED_PACMAN", result["calls"])

    def test_real_closure_merges_search_parent_and_adds_core_to_shared_model(self):
        body = r'''
R_KEYS=(aur:plugin repo:core)
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
pm_close_marked_selection
printf 'rc=%s\n' "$?"
printf 'marked='; print_marked
printf 'auto=%s\n' "${!PM_AUTO_ADDED[@]}"
printf 'repo=%s\n' "${PM_INSTALL_REPO[*]}"
printf 'aur=%s\n' "${PM_INSTALL_AUR[*]}"
printf 'notices=%s\n' "${PM_NOTICES[@]}"
printf 'selected=%s\n' "${PM_SELECTION_ORDER[*]}"
'''
        records = {
            "aur:plugin": {"source": "aur", "name": "plugin"},
            "repo:core": {"source": "repo", "name": "core"},
        }
        result = run_harness(
            body, detail_records=records,
            search_meta="plugin|plugin|core|||||\ncore|app||||||\n",
        )
        self.assert_clean(result)
        self.assertIn("rc=0", result["stdout"])
        self.assertIn("marked=aur:plugin repo:core", result["stdout"])
        self.assertIn("auto=repo:core", result["stdout"])
        self.assertIn("repo=core", result["stdout"])
        self.assertIn("aur=plugin", result["stdout"])
        self.assertIn("notices=Required core application core was added", result["stdout"])
        self.assertIn("selected=aur:plugin repo:core", result["stdout"])

    def test_ambiguous_provider_choice_reruns_closure_and_cancel_blocks(self):
        records = {
            "aur:plugin": {"source": "aur", "name": "plugin"},
            "repo:z": {"source": "repo", "name": "z", "provides": ["virtual-core"]},
            "repo:a": {"source": "repo", "name": "a", "provides": ["virtual-core=1"]},
        }
        meta = "plugin|plugin|virtual-core|||||\nz|app||||||\na|app||||||\n"
        for choice in ("repo:a", "cancel"):
            with self.subTest(choice=choice):
                body = r'''
R_KEYS=(aur:plugin repo:z repo:a)
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
ui_choose() {
    printf 'CHOOSE %s\n' "$1" >>"$TEST_CALLS"
    [[ $1 == "Choose required core application" ]] || return 1
''' + ('    printf \'%s\\n\' repo:a\n' if choice == "repo:a" else "    return 1\n") + r'''}
pm_resolve_marked_selection
printf 'rc=%s\n' "$?"
printf 'marked='; print_marked
printf 'auto=%s\n' "${!PM_AUTO_ADDED[*]}"
printf 'repo=%s\n' "${PM_INSTALL_REPO[*]}"
'''
                result = run_harness(body, detail_records=records, search_meta=meta)
                self.assert_clean(result)
                self.assertIn("CHOOSE Choose required core application", result["calls"])
                self.assertNotIn("RUN ", result["calls"])
                if choice == "repo:a":
                    self.assertIn("rc=0", result["stdout"])
                    self.assertIn("marked=aur:plugin repo:a", result["stdout"])
                    self.assertIn("auto=repo:a", result["stdout"])
                    self.assertIn("repo=a", result["stdout"])
                else:
                    self.assertIn("rc=1", result["stdout"])
                    self.assertIn("marked=aur:plugin", result["stdout"])
                    self.assertIn("No provider was chosen for virtual-core", result["dialogs"])

    def test_conflict_comparison_is_nonmutating_and_unmark_is_explicit(self):
        records = {
            "repo:one": {"source": "repo", "name": "one", "conflicts": ["two"]},
            "aur:two": {"source": "aur", "name": "two", "conflicts": ["one"]},
        }
        meta = "one|app||||||\ntwo|app||||||\n"
        for choice in ("compare", "drop|aur:two"):
            with self.subTest(choice=choice):
                body = r'''
R_KEYS=(repo:one aur:two)
PM_MARKED=([repo:one]=1 [aur:two]=1)
PM_SELECTION_ORDER=(repo:one aur:two)
pm_about() { printf 'Details for %s\n' "$1"; }
ui_choose() {
    printf 'CHOOSE %s\n' "$1" >>"$TEST_CALLS"
    [[ $1 == "Resolve package conflicts" ]] || return 1
''' + "    if [[ -e $TEST_TMP/conflict-choice ]]; then return 1; fi\n    : >\"$TEST_TMP/conflict-choice\"\n    printf '%s\\n' '" + choice + "'\n" + r'''}
pm_resolve_marked_selection
printf 'rc=%s\n' "$?"
printf 'marked='; print_marked
'''
                result = run_harness(body, detail_records=records, search_meta=meta)
                self.assert_clean(result)
                self.assertNotIn("RUN ", result["calls"])
                if choice == "compare":
                    self.assertIn("rc=1", result["stdout"])
                    self.assertIn("marked=aur:two repo:one", result["stdout"])
                    self.assertIn("Conflict details: one", result["dialogs"])
                    self.assertIn("Conflict details: two", result["dialogs"])
                else:
                    self.assertIn("rc=0", result["stdout"])
                    self.assertIn("marked=repo:one", result["stdout"])

    def test_aggregated_preview_deduplicates_and_preserves_dependency_sections(self):
        body = r'''
PM_MARKED=([repo:one]=1 [repo:two]=1 [aur:plugin]=1 [repo:core]=1)
PM_SELECTION_ORDER=(repo:one repo:two aur:plugin repo:core)
PM_AUTO_ADDED=([repo:core]=1)
pm_install_plan_many
rc=$?
printf 'rc=%s\n' "$rc"
printf 'repo=%s\n' "${PM_INSTALL_REPO[*]}"
printf 'aur=%s\n' "${PM_INSTALL_AUR[*]}"
printf '%s\n' "$PLAN_TEXT"
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("rc=0", result["stdout"])
        self.assertIn("repo=core one two", result["stdout"])
        self.assertIn("aur=plugin", result["stdout"])
        text = result["stdout"]
        self.assertIn("Selected applications:", text)
        self.assertIn("Auto-added core applications:", text)
        self.assertIn("repo:core", text)
        self.assertEqual(text.count("repo:shared"), 1, text)
        self.assertIn("Known download total: 8.0 KiB", text)
        self.assertIn("Unknown size for:", text)
        self.assertIn("aur:plugin", text)
        self.assertIn("repo:meson", text)
        self.assertIn("ONLY NEEDED TO BUILD", text)
        self.assertIn("not selected applications", text)
        self.assertIn("ALREADY ON YOUR SYSTEM", text)
        self.assertIn("installed-dep", text)
        self.assertIn("OPTIONAL", text)
        self.assertIn("for repo:one", text)
        self.assertIn("for repo:two", text)
        self.assertNotIn("~ repo:meson (selected", text)

    def test_known_selected_core_size_wins_over_unknown_dependency_row(self):
        body = r'''
PM_MARKED=([aur:chain]=1 [repo:core]=1)
PM_SELECTION_ORDER=(aur:chain repo:core)
PM_AUTO_ADDED=([repo:core]=1)
pm_install_plan_many || exit 20
printf '%s\n' "$PLAN_TEXT"
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("Known download total: 1.0 KiB", result["stdout"])
        unknown = next(line for line in result["stdout"].splitlines() if line.startswith("Unknown size for:"))
        self.assertIn("aur:chain", unknown)
        self.assertNotIn("repo:core", unknown)


    def test_plan_many_refuses_unresolved_ambiguous_and_conflicts(self):
        cases = (
            ("unresolved", "PM_UNRESOLVED=(missing-core)", "missing-core"),
            ("ambiguous", "PM_AMBIGUOUS=('core|repo:a,repo:b')", "core"),
            ("conflicts", "PM_CONFLICTS=('one|two')", "one"),
        )
        for label, setup, expected in cases:
            with self.subTest(case=label):
                body = r'''
PM_MARKED=([repo:one]=1)
PM_SELECTION_ORDER=(repo:one)
''' + setup + r'''
pm_install_plan_many
printf 'rc=%s\n' "$?"
printf '%s\n' "$PLAN_TEXT"
'''
                result = run_harness(body)
                self.assert_clean(result)
                self.assertIn("rc=1", result["stdout"])
                self.assertIn(expected, result["stdout"])
                self.assertNotIn("PLAN ", result["calls"])

    def test_official_precedes_aur_and_all_selected_packages_are_verified(self):
        body = r'''
PM_MARKED=([repo:one]=1 [repo:two]=1 [aur:plugin]=1 [repo:core]=1)
PM_SELECTION_ORDER=(repo:one repo:two aur:plugin repo:core)
PM_AUTO_ADDED=([repo:core]=1)
PM_REINSTALL=([repo:one]=1)
PM_EXTRAS=([repo:two]='extra-two' [aur:plugin]='aur-extra')
PM_TOOL=paru
pm_install_plan_many || exit 20
pm_execute_install_plan
printf 'execute_rc=%s\n' "$?"
printf 'success=%s\n' "$PM_INSTALL_SUCCESS"
printf 'missing=%s\n' "${PM_VERIFY_MISSING[@]}"
printf 'repo=%s\n' "${PM_INSTALL_REPO[*]}"
printf 'aur=%s\n' "${PM_INSTALL_AUR[*]}"
'''
        result = run_harness(
            body,
            installed=("one", "two", "plugin", "core", "extra-two", "aur-extra"),
        )
        self.assert_clean(result)
        calls = result["calls"]
        repo = calls.index("RUN ")
        aur = calls.index("<paru>")
        self.assertLess(repo, aur)
        self.assertEqual(calls.count("RUN "), 2, calls)
        repo_line = next(line for line in calls.splitlines() if "RUN " in line and "<sudo>" in line)
        aur_line = next(line for line in calls.splitlines() if "<paru>" in line)
        self.assertIn("<pacman> <-S> <--> <core> <one> <two> <extra-two>", repo_line)
        self.assertNotIn("--needed", repo_line)
        self.assertIn("<paru> <-S> <--needed> <--> <plugin> <aur-extra>", aur_line)
        self.assertNotIn("--noconfirm", calls)
        for name in ("one", "two", "plugin", "core", "extra-two", "aur-extra"):
            self.assertIn("VERIFY " + name, calls)
        self.assertIn("success=true", result["stdout"])
        self.assertIn("missing=", result["stdout"])
        self.assertIn("Every requested package was verified with pacman -Qq.", result["dialogs"])
        self.assertNotIn("virtual requirements were verified", result["dialogs"])

    def test_failed_reinstall_is_not_overall_success_when_old_version_remains(self):
        body = r'''
PM_MARKED=([repo:one]=1)
PM_SELECTION_ORDER=(repo:one)
PM_REINSTALL=([repo:one]=1)
TEST_REPO_RC=1
pm_install_plan_many || exit 20
pm_execute_install_plan
printf 'success=%s\n' "$PM_INSTALL_SUCCESS"
printf 'one=%s\n' "${PM_VERIFY_STATUS[repo:one]}"
printf 'missing=%s\n' "${PM_VERIFY_MISSING[@]}"
'''
        result = run_harness(body, installed=("one",))
        self.assert_clean(result)
        self.assertIn("success=false", result["stdout"])
        self.assertIn("one=installed", result["stdout"])
        self.assertIn("missing=", result["stdout"])
        self.assertIn("DIAGNOSE", result["calls"])
        self.assertIn("Overall installation was NOT successful", result["dialogs"])


    def test_missing_requested_package_prevents_overall_success_and_keeps_diagnosis(self):
        body = r'''
PM_MARKED=([repo:one]=1 [aur:plugin]=1)
PM_SELECTION_ORDER=(repo:one aur:plugin)
PM_TOOL=paru
TEST_AUR_RC=1
pm_install_plan_many || exit 20
pm_execute_install_plan
printf 'rc=%s\n' "$?"
printf 'success=%s\n' "$PM_INSTALL_SUCCESS"
printf 'missing=%s\n' "${PM_VERIFY_MISSING[@]}"
printf 'plugin=%s\n' "${PM_VERIFY_STATUS[aur:plugin]}"
printf 'one=%s\n' "${PM_VERIFY_STATUS[repo:one]}"
printf 'logs=%s\n' "${PM_INSTALL_LOGS[*]}"
'''
        result = run_harness(body, installed=("one",))
        self.assertEqual(result["returncode"], 0, result["stderr"])
        self.assertIn("success=false", result["stdout"])
        self.assertIn("missing=plugin", result["stdout"])
        self.assertIn("plugin=missing", result["stdout"])
        self.assertIn("one=installed", result["stdout"])
        self.assertIn("DIAGNOSE", result["calls"])
        self.assertIn("install-aur.log", result["stdout"])
        self.assertNotIn("SUCCESS plugin", result["calls"])
        self.assertIn("ERROR", result["calls"])

    def test_optional_extras_are_stored_per_owner_and_survive_replanning(self):
        body = r'''
PM_MARKED=([repo:one]=1 [repo:two]=1)
PM_SELECTION_ORDER=(repo:one repo:two)
pm_install_plan_many || exit 20
pm_pick_extras_for repo:one
pm_pick_extras_for repo:two
printf 'one=%s\n' "${PM_EXTRAS[repo:one]}"
printf 'two=%s\n' "${PM_EXTRAS[repo:two]}"
printf 'marked='; print_marked
pm_install_plan_many || exit 21
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("one=extra-one", result["stdout"])
        self.assertIn("two=extra-two", result["stdout"])
        self.assertIn("marked=repo:one repo:two", result["stdout"])
        self.assertIn("PLAN repo one <extra-one>", result["calls"])
        self.assertIn("PLAN repo two <extra-two>", result["calls"])
        self.assertNotIn("PLAN repo one <extra-two>", result["calls"])
        self.assertNotIn("PLAN repo two <extra-one>", result["calls"])

    def test_failed_metadata_blocks_confirmation_without_losing_selection(self):
        body = r'''
PM_MARKED=([repo:one]=1 [aur:bad]=1 [repo:two]=1)
PM_SELECTION_ORDER=(repo:one aur:bad repo:two)
pm_install_plan_many
printf 'rc=%s\n' "$?"
printf 'marked='; print_marked
printf '%s\n' "$PLAN_TEXT"
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("marked=aur:bad repo:one repo:two", result["stdout"])
        self.assertIn("metadata failed for bad", result["stdout"])
        self.assertNotIn("RUN ", result["calls"])

    def test_action_flow_unmark_before_closure_loads_records_and_preserves_ordinary_unmark(self):
        body = r'''
ui_input() { TUI_INPUT=demo; return 0; }
pm_search() { R_KEYS=(aur:plugin repo:core); R_LABELS=(plugin core); }
ui_multiselect() {
    PM_MARKED=([aur:plugin]=1 [repo:core]=1)
    PM_SELECTION_ORDER=(aur:plugin repo:core)
    [[ ! -e $TMP/selection-records.json ]] || return 90
    pm_toggle_key repo:core
    printf 'guard_rc=%s\n' "$?"
    printf 'notice=%s\n' "$PM_NOTICE"
    printf 'guarded_marked='; print_marked
    pm_toggle_key aur:plugin
    printf 'plugin_rc=%s\n' "$?"
    pm_toggle_key repo:core
    printf 'core_rc=%s\n' "$?"
    printf 'final_marked='; print_marked
    PM_ACTION=back
    return 1
}
action_install
printf 'action_rc=%s\n' "$?"
'''
        records = {
            "aur:plugin": {
                "source": "aur", "name": "plugin", "parent": "core",
                "depends": ["core"], "provides": [], "conflicts": [],
            },
            "repo:core": {"source": "repo", "name": "core"},
        }
        result = run_harness(body, detail_records=records)
        self.assert_clean(result)
        self.assertIn("guard_rc=1", result["stdout"])
        self.assertIn("Cannot unmark required core application core", result["stdout"])
        self.assertIn("Restore core", result["stdout"])
        self.assertIn("guarded_marked=aur:plugin repo:core", result["stdout"])
        self.assertIn("plugin_rc=0", result["stdout"])
        self.assertIn("core_rc=0", result["stdout"])
        self.assertIn("final_marked=\n", result["stdout"])
        self.assertNotIn("RUN ", result["calls"])

    def test_unknown_virtual_provider_blocks_real_unmark_evaluation(self):
        body = r'''
R_KEYS=(repo:root repo:middle aur:plugin)
PM_MARKED=([repo:root]=1 [repo:middle]=1 [aur:plugin]=1)
PM_SELECTION_ORDER=(repo:root repo:middle aur:plugin)
pm_toggle_key repo:middle
printf 'rc=%s\n' "$?"
printf 'notice=%s\n' "$PM_NOTICE"
printf 'marked='; print_marked
'''
        records = {
            "repo:root": {"source": "repo", "name": "root"},
            "repo:middle": {
                "source": "repo", "name": "middle", "parent": None,
                "depends": None, "provides": None, "conflicts": None,
                "_unavailable": ["depends", "provides", "conflicts", "parent"],
            },
            "aur:plugin": {"source": "aur", "name": "plugin"},
        }
        meta = (
            "root|app||||||\n"
            "middle|plugin|root|||||\n"
            "plugin|plugin|virtual-core|||||\n"
        )
        result = run_harness(body, detail_records=records, search_meta=meta)
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("could not be evaluated", result["stdout"])
        self.assertIn("marked=aur:plugin repo:middle repo:root", result["stdout"])

    def test_unmark_fails_closed_when_requirement_evaluation_fails(self):
        body = r'''
R_KEYS=(repo:one)
PM_MARKED=([repo:one]=1)
PM_SELECTION_ORDER=(repo:one)
pm_selection_records_load() { return 1; }
pm_toggle_key repo:one
printf 'rc=%s\n' "$?"
printf 'notice=%s\n' "$PM_NOTICE"
printf 'marked='; print_marked
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("could not be evaluated", result["stdout"])
        self.assertIn("marked=repo:one", result["stdout"])

    def test_real_bash_unmark_guard_keeps_required_core_and_dependents(self):
        body = r'''
cat >"$TMP/selection-records.json" <<'JSON'
{"repo:core":{"name":"core","parent":"","provides":[]},"repo:middle":{"name":"middle","parent":"core","provides":[]},"aur:plugin":{"name":"plugin","parent":"middle","provides":[]}}
JSON
PM_MARKED=([repo:core]=1 [repo:middle]=1 [aur:plugin]=1)
PM_SELECTION_ORDER=(repo:core repo:middle aur:plugin)
pm_toggle_key repo:core
printf 'rc=%s\n' "$?"
printf 'notice=%s\n' "$PM_NOTICE"
printf 'marked='; print_marked
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("Cannot unmark required core application core", result["stdout"])
        self.assertIn("Restore core or unmark the dependent plugin(s) first", result["stdout"])
        self.assertIn("middle", result["stdout"])
        self.assertIn("plugin", result["stdout"])
        self.assertIn("marked=aur:plugin repo:core repo:middle", result["stdout"])

    def test_real_repo_planner_rejects_metadata_and_transaction_failures(self):
        cases = (
            ("si_fail", "pacman -Si"),
            ("si_empty", "pacman -Si"),
            ("sp_fail", "pacman -Sp"),
            ("sp_empty", "selected package"),
        )
        for mode, expected in cases:
            with self.subTest(mode=mode):
                body = r'''
pacman() {
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    if [[ $1 == -Qq ]]; then return 1; fi
    if [[ $1 == -Si ]]; then
        case $TEST_MODE in
            si_fail) return 1 ;;
            si_empty) return 0 ;;
        esac
        printf '%s\n' \
            'Repository      : extra' 'Name            : one' 'Version         : 1.0-1' \
            'Description     : One' 'Depends On      : shared' 'Optional Deps   : None' \
            'Download Size   : 1.00 KiB' 'Installed Size  : 2.00 KiB'
        return 0
    fi
    if [[ $1 == -Sp ]]; then
        case $TEST_MODE in
            sp_fail) return 1 ;;
            sp_empty) return 0 ;;
        esac
        printf '%s\n' 'one|1.0-1|extra|1024' 'shared|2.0-1|extra|2048'
        return 0
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(shared); DEP_REPO=(); DEP_AUR=(); }
pm_install_plan() { pm_install_plan_real "$@"; }
PM_MARKED=([repo:one]=1)
PM_SELECTION_ORDER=(repo:one)
pm_install_plan_real repo one
printf 'direct_rc=%s\n' "$?"
printf 'direct_rows=%s\n' "${#PLAN_ROWS[@]}"
printf 'direct_text=%s\n' "$PLAN_TEXT"
pm_install_plan_many
printf 'many_rc=%s\n' "$?"
printf 'many_text=%s\n' "$PLAN_TEXT"
'''
                result = run_harness(body.replace("$TEST_MODE", mode))
                self.assert_clean(result)
                self.assertNotIn("direct_rc=0", result["stdout"])
                self.assertIn("direct_rows=0", result["stdout"])
                self.assertIn("many_rc=1", result["stdout"])
                self.assertIn(expected, result["stdout"])
                self.assertIn("Metadata could not be loaded for repo:one", result["stdout"])
                self.assertNotIn("RUN ", result["calls"])

    def test_action_install_real_repo_failure_offers_no_install_action(self):
        body = r'''
pacman() {
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    if [[ $1 == -Qq ]]; then [[ ${!#} == one ]]; return; fi
    if [[ $1 == -Si ]]; then return 1; fi
    if [[ $1 == -Sp ]]; then printf '%s\n' 'one|1.0-1|extra|1024'; return 0; fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
pm_install_plan() { pm_install_plan_real "$@"; }
ui_input() { TUI_INPUT=demo; return 0; }
pm_search() { R_KEYS=(repo:one); R_LABELS=(one); }
ui_multiselect() {
    PM_MARKED=([repo:one]=1)
    PM_SELECTION_ORDER=(repo:one)
    PM_ACTION=install
    return 0
}
action_install
printf 'action_rc=%s\n' "$?"
'''
        result = run_harness(
            body, installed=("one",),
            detail_records={"repo:one": {"source": "repo", "name": "one"}},
        )
        self.assert_clean(result)
        self.assertIn("action_rc=0", result["stdout"])
        self.assertIn("DIALOG <Installation blocked>", result["dialogs"])
        self.assertIn("pacman -Si", result["dialogs"])
        self.assertNotIn("DIALOG <Install one>", result["dialogs"])
        self.assertNotIn("RUN ", result["calls"])
        self.assertNotIn("SUDO", result["calls"])

    def test_aur_planner_missing_or_invalid_update_is_not_epoch(self):
        for updated in ("", "0", "not-a-number"):
            with self.subTest(updated=updated):
                body = r'''
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
aur_json() {
    printf '%s\n' 'Name=plugin' 'Version=1.0-1' 'Description=Plugin' \
        'Maintainer=maint' 'NumVotes=1' 'LastModified=@UPDATE@' 'OutOfDate=' \
        'Depends=' 'OptDepends=' 'MakeDepends=' 'CheckDepends='
}
pm_install_plan_real aur plugin
printf 'rc=%s\n' "$?"
printf '%s\n' "$PLAN_TEXT"
'''.replace("@UPDATE@", updated)
                result = run_harness(body)
                self.assert_clean(result)
                self.assertIn("rc=0", result["stdout"])
                self.assertIn("updated Not available", result["stdout"])
                self.assertNotIn("1970-01-01", result["stdout"])

    def test_plugin_parent_label_recomputes_missing_selected_and_installed_state(self):
        body = r'''
pacman() {
    if [[ $1 == -T ]]; then [[ ${TEST_PARENT_INSTALLED:-false} == true ]]; return; fi
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    return 1
}
PM_MARKED=()
pm_selection_label aur:plugin "Plugin row"
printf 'missing=%s\n' "$PM_LABEL"
PM_MARKED=([repo:core]=1)
pm_selection_label aur:plugin "Plugin row"
printf 'selected=%s\n' "$PM_LABEL"
PM_MARKED=()
TEST_PARENT_INSTALLED=true
pm_selection_label aur:plugin "Plugin row"
printf 'installed=%s\n' "$PM_LABEL"
'''
        result = run_harness(
            body, search_meta="plugin|plugin|core|||||\ncore|app||||||\n"
        )
        self.assert_clean(result)
        self.assertIn("missing=[ ] Plugin row · requires core: core (missing)", result["stdout"])
        self.assertIn("selected=[ ] Plugin row · requires core: core (selected)", result["stdout"])
        self.assertIn("installed=[ ] Plugin row · requires core: core (installed)", result["stdout"])

    def test_parent_state_is_cached_across_rows_and_redraws(self):
        meta = "".join(
            f"plugin-{index}|plugin|core|||||\n" for index in range(12)
        ) + "core-provider|app||||||\n"
        body = r'''
pacman() {
    if [[ $1 == -T ]]; then printf 'PARENT\n' >>"$TEST_CALLS"; return 1; fi
    return 1
}
python3() {
    [[ " $* " == *" --selected-identities "* ]] && printf 'IDENTITIES\n' >>"$TEST_CALLS"
    command python3 "$@"
}
printf '%s\n' '{"source":"repo","name":"core-provider","provides":["core=1"]}' \
    >"$TMP/search_meta.jsonl"
PM_MARKED=([repo:core-provider]=1)
PM_SELECTION_ORDER=(repo:core-provider)
plugins=(plugin-{0..11})
for pass in first second; do
    for plugin in "${plugins[@]}"; do pm_selection_label "aur:$plugin" "Plugin row"; done
done
printf 'parent_checks=%s\n' "$(grep -c '^PARENT$' "$TEST_CALLS" || :)"
printf 'identity_checks=%s\n' "$(grep -c '^IDENTITIES$' "$TEST_CALLS" || :)"
'''
        result = run_harness(body, search_meta=meta)
        self.assert_clean(result)
        self.assertIn("parent_checks=1", result["stdout"])
        self.assertIn("identity_checks=1", result["stdout"])

    def test_selected_virtual_core_uses_summary_or_detail_provides(self):
        for metadata_source in ("summary", "detail"):
            with self.subTest(metadata_source=metadata_source):
                body = r'''
pacman() {
    if [[ $1 == -T ]]; then return 1; fi
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    return 1
}
PM_MARKED=([repo:core-provider]=1)
'''
                if metadata_source == "summary":
                    body += r'''
printf '%s\n' '{"source":"repo","name":"core-provider","provides":["core=1"]}' \
    >"$TMP/search_meta.jsonl"
'''
                else:
                    body += r'''
printf '%s\n' '{"repo:core-provider":{"source":"repo","name":"core-provider","provides":["core=1"]}}' \
    >"$TMP/selection-records.json"
'''
                body += r'''
pm_selection_label aur:plugin "Plugin row"
printf '%s\n' "$PM_LABEL"
'''
                result = run_harness(
                    body, search_meta="plugin|plugin|core|||||\ncore-provider|app||||||\n"
                )
                self.assert_clean(result)
                self.assertIn("requires core: core (selected)", result["stdout"])

    def test_aggregation_uses_canonical_role_precedence_not_role_keys(self):
        body = r'''
PM_MARKED=([aur:roles]=1)
PM_SELECTION_ORDER=(aur:roles)
pm_install_plan_many || exit 20
printf '%s\n' "$PLAN_TEXT"
printf 'make=%s\n' "${PM_PLAN_MAKE[*]}"
'''
        result = run_harness(body)
        self.assert_clean(result)
        text = result["stdout"]
        self.assertEqual(text.count("repo:shared"), 1, text)
        self.assertIn("+ repo:shared 2.0-1 (extra; for aur:roles)", text)
        build = text.split("ONLY NEEDED TO BUILD", 1)[1].split("Known download total", 1)[0]
        self.assertNotIn("repo:shared", build)
        self.assertIn("repo:build-only", build)
        self.assertIn("make=build-only", text)
        self.assertIn("Known download total: 3.0 KiB", text)

    def test_real_aur_official_extra_uses_repo_source_preview_and_execution(self):
        body = r'''
pacman() {
    local name
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    if [[ $1 == -Qq ]]; then
        name=${!#}
        printf 'VERIFY %s\n' "$name" >>"$TEST_CALLS"
        [[ " $TEST_INSTALLED " == *" $name "* ]]
        return
    fi
    if [[ $1 == -Sp ]]; then
        name=${!#}
        case $name in
            official-extra) printf '%s\n' 'official-extra|1.0-1|extra|512'; return 0 ;;
            official-option) printf '%s\n' 'official-option|1.0-1|extra|256'; return 0 ;;
        esac
        return 1
    fi
    if [[ $1 == -Si ]]; then return 1; fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
aur_json() {
    printf '%s\n' \
        'Name=plugin' 'Version=1.0-1' 'Description=Plugin' 'Maintainer=maint' \
        'NumVotes=1' 'LastModified=0' 'OutOfDate=' 'Depends=' \
        'OptDepends=official-option: Official tools' 'MakeDepends=' 'CheckDepends='
}
pm_install_plan_real aur plugin official-extra || exit 30
printf '%s\n' "${PLAN_ROWS[@]}"
printf 'source=%s\n' "${PM_EXTRA_SOURCE[aur:plugin:official-extra]}"
pm_install_plan() { pm_install_plan_real "$@"; }
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
PM_EXTRAS=([aur:plugin]=official-extra)
PM_TOOL=paru
pm_install_plan_many || exit 31
printf '%s\n' "$PLAN_TEXT"
pm_execute_install_plan
'''
        result = run_harness(body, installed=("plugin", "official-extra"))
        self.assert_clean(result)
        self.assertIn("repo|official-extra|1.0-1|extra|512|extra|aur:plugin", result["stdout"])
        self.assertIn("repo|official-option|1.0-1|extra|256|optional|aur:plugin", result["stdout"])
        self.assertIn("source=repo", result["stdout"])
        self.assertNotIn("aur|official-extra|", result["stdout"])
        self.assertIn("Known download total: 512 B", result["stdout"])
        unknown = next(line for line in result["stdout"].splitlines() if line.startswith("Unknown size for:"))
        self.assertIn("aur:plugin", unknown)
        self.assertNotIn("official-extra", unknown)
        repo = result["calls"].index("<sudo>")
        aur = result["calls"].index("<paru>")
        self.assertLess(repo, aur)
        repo_line = next(line for line in result["calls"].splitlines() if "RUN " in line and "<sudo>" in line)
        aur_line = next(line for line in result["calls"].splitlines() if "RUN " in line and "<paru>" in line)
        self.assertIn("<official-extra>", repo_line)
        self.assertNotIn("<plugin>", repo_line)
        self.assertIn("<plugin>", aur_line)
        self.assertNotIn("<official-extra>", aur_line)
        self.assertIn("VERIFY official-extra", result["calls"])
        self.assertIn("VERIFY plugin", result["calls"])

    def test_virtual_extra_uses_resolved_official_provider_and_verifies_requirement(self):
        body = r'''
pacman() {
    local name=${!#}
    if [[ $1 == -Qq && $# -eq 1 ]]; then
        printf '%s\n' $TEST_INSTALLED
        return 0
    fi
    if [[ $1 == -Qq ]]; then
        printf 'QUERY %s\n' "$name" >>"$TEST_CALLS"
        [[ " $TEST_INSTALLED " == *" $name "* ]]
        return
    fi
    if [[ $1 == -Q ]]; then
        [[ " $TEST_INSTALLED " == *" $name "* ]] || return 1
        printf '%s 1.0-1\n' "$name"
        return 0
    fi
    if [[ $1 == -T ]]; then
        printf 'SATISFY %s\n' "$name" >>"$TEST_CALLS"
        [[ $name == java-runtime && " $TEST_INSTALLED " == *" jre-openjdk "* ]]
        return
    fi
    if [[ $1 == -Sp ]]; then
        [[ $name == java-runtime ]] || return 1
        printf '%s\n' 'jre-openjdk|17.0.1-1|extra|1024'
        return 0
    fi
    if [[ $1 == -Si ]]; then
        [[ $name == jre-openjdk ]] || return 1
        printf '%s\n' 'Repository      : extra' 'Name            : jre-openjdk' \
            'Version         : 17.0.1-1' 'Provides        : java-runtime=17'
        return 0
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
aur_json() {
    printf '%s\n' 'Name=plugin' 'Version=1.0-1' 'Description=Plugin' \
        'Maintainer=maint' 'NumVotes=1' 'LastModified=1700000000' 'OutOfDate=' \
        'Depends=' 'OptDepends=java-runtime: Java support' 'MakeDepends=' 'CheckDepends='
}
pm_install_plan() { pm_install_plan_real "$@"; }
DB_PATH=$TEST_TMP/db
declare -A PM_EXTRA_PROVIDER=()
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
PM_EXTRAS=([aur:plugin]=java-runtime)
PM_TOOL=paru
pm_install_plan_many || exit 30
printf 'provider=%s\n' "${PM_EXTRA_PROVIDER[aur:plugin:java-runtime]}"
printf 'source=%s\n' "${PM_EXTRA_SOURCE[aur:plugin:java-runtime]}"
printf '%s\n' "$PLAN_TEXT"
pm_execute_install_plan
printf 'success=%s\n' "$PM_INSTALL_SUCCESS"
printf 'extra_status=%s\n' "${PM_VERIFY_STATUS[repo:java-runtime]}"
'''
        result = run_harness(
            body, installed=("plugin", "jre-openjdk"),
            sync_dbs={"extra.db": [sync_desc("jre-openjdk", "17.0.1-1", "java-runtime=17")]},
        )
        self.assert_clean(result)
        self.assertIn("provider=jre-openjdk", result["stdout"])
        self.assertIn("source=repo", result["stdout"])
        self.assertIn("repo:jre-openjdk", result["stdout"])
        repo_line = next(line for line in result["calls"].splitlines() if "RUN " in line and "<sudo>" in line)
        aur_line = next(line for line in result["calls"].splitlines() if "RUN " in line and "<paru>" in line)
        self.assertIn("<jre-openjdk>", repo_line)
        self.assertNotIn("<java-runtime>", repo_line)
        self.assertNotIn("java-runtime", aur_line)
        self.assertIn("SATISFY java-runtime", result["calls"])
        self.assertNotIn("QUERY java-runtime", result["calls"])
        self.assertIn("success=true", result["stdout"])
        self.assertIn("extra_status=installed", result["stdout"])
        self.assertIn(
            "Every requested package was verified with pacman -Qq; virtual requirements were verified with pacman -T.",
            result["dialogs"],
        )

    def test_virtual_extra_with_multiple_providers_blocks_and_lists_candidates(self):
        body = r'''
pacman() {
    local name=${!#}
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    if [[ $1 == -Qq ]]; then return 1; fi
    if [[ $1 == -Sp ]]; then
        [[ $name == java-runtime ]] || return 1
        printf '%s\n' 'jre-openjdk|17.0.1-1|extra|1024' \
            'jre-openjdk-headless|17.0.1-1|extra|512'
        return 0
    fi
    if [[ $1 == -Si ]]; then
        case $name in
            jre-openjdk|jre-openjdk-headless)
                printf '%s\n' 'Repository      : extra' "Name            : $name" \
                    'Version         : 17.0.1-1' 'Provides        : java-runtime=17'
                return 0
                ;;
        esac
        return 1
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
aur_json() {
    printf '%s\n' 'Name=plugin' 'Version=1.0-1' 'Description=Plugin' \
        'Maintainer=maint' 'NumVotes=1' 'LastModified=1700000000' 'OutOfDate=' \
        'Depends=' 'OptDepends=java-runtime: Java support' 'MakeDepends=' 'CheckDepends='
}
pm_install_plan() { pm_install_plan_real "$@"; }
DB_PATH=$TEST_TMP/db
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
PM_EXTRAS=([aur:plugin]=java-runtime)
PM_TOOL=paru
pm_install_plan_many
printf 'rc=%s\n' "$?"
printf '%s\n' "$PLAN_TEXT"
printf 'marked='; print_marked
'''
        result = run_harness(
            body,
            sync_dbs={"extra.db": [
                sync_desc("jre-openjdk", "17.0.1-1", "java-runtime=17"),
                sync_desc("jre-openjdk-headless", "17.0.1-1", "java-runtime=17"),
            ]},
        )
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("jre-openjdk", result["stdout"])
        self.assertIn("jre-openjdk-headless", result["stdout"])
        self.assertIn("confirmation is blocked", result["stdout"].lower())
        self.assertIn("marked=aur:plugin", result["stdout"])
        self.assertNotIn("RUN ", result["calls"])
        self.assertNotIn("aur|java-runtime", result["stdout"])

    def test_virtual_extra_default_stdout_blocks_when_sync_db_has_multiple_providers(self):
        body = r'''
pacman() {
    local name=${!#}
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    if [[ $1 == -Qq ]]; then return 1; fi
    if [[ $1 == -Sp ]]; then
        [[ $name == java-runtime ]] || return 1
        printf '%s\n' 'jdk-openjdk|17.0.1-1|extra|1024'
        return 0
    fi
    if [[ $1 == -Si ]]; then
        case $name in
            jdk-openjdk|jre-openjdk)
                printf '%s\n' 'Repository      : extra' "Name            : $name" \
                    'Version         : 17.0.1-1' 'Provides        : java-runtime=17'
                return 0
                ;;
        esac
        return 1
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
aur_json() {
    printf '%s\n' 'Name=plugin' 'Version=1.0-1' 'Description=Plugin' \
        'Maintainer=maint' 'NumVotes=1' 'LastModified=1700000000' 'OutOfDate=' \
        'Depends=' 'OptDepends=java-runtime: Java support' 'MakeDepends=' 'CheckDepends='
}
pm_install_plan() { pm_install_plan_real "$@"; }
DB_PATH=$TEST_TMP/db
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
PM_EXTRAS=([aur:plugin]=java-runtime)
PM_TOOL=paru
pm_install_plan_many
printf 'rc=%s\n' "$?"
printf 'provider=%s\n' "${PM_EXTRA_PROVIDER[aur:plugin:java-runtime]}"
printf '%s\n' "$PLAN_TEXT"
printf 'marked='; print_marked
'''
        result = run_harness(
            body,
            sync_dbs={"extra.db": [
                sync_desc("jdk-openjdk", "17.0.1-1", "java-runtime=17"),
                sync_desc("jre-openjdk", "17.0.1-1", "java-runtime=17"),
            ]},
        )
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("jdk-openjdk", result["stdout"])
        self.assertIn("jre-openjdk", result["stdout"])
        self.assertIn("confirmation is blocked", result["stdout"].lower())
        self.assertIn("marked=aur:plugin", result["stdout"])
        self.assertNotIn("RUN ", result["calls"])

    def test_virtual_extra_partial_sync_enumeration_fails_closed_in_both_orders(self):
        cases = (
            ("a-extra.db", "z-broken.db"),
            ("z-extra.db", "a-broken.db"),
        )
        for valid_db, corrupt_db in cases:
            with self.subTest(valid_db=valid_db, corrupt_db=corrupt_db):
                body = r'''
pacman() {
    local name=${!#}
    if [[ $1 == -Qq && $# -eq 1 ]]; then return 0; fi
    if [[ $1 == -Qq ]]; then return 1; fi
    if [[ $1 == -Sp ]]; then
        [[ $name == java-runtime ]] || return 1
        printf '%s\n' 'jdk-openjdk|17.0.1-1|extra|1024'
        return 0
    fi
    if [[ $1 == -Si ]]; then
        [[ $name == jdk-openjdk ]] || return 1
        printf '%s\n' 'Repository      : extra' 'Name            : jdk-openjdk' \
            'Version         : 17.0.1-1' 'Provides        : java-runtime=17'
        return 0
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
aur_json() {
    printf '%s\n' 'Name=plugin' 'Version=1.0-1' 'Description=Plugin' \
        'Maintainer=maint' 'NumVotes=1' 'LastModified=1700000000' 'OutOfDate=' \
        'Depends=' 'OptDepends=java-runtime: Java support' 'MakeDepends=' 'CheckDepends='
}
pm_install_plan() { pm_install_plan_real "$@"; }
DB_PATH=$TEST_TMP/db
printf '%s\n' 'unreadable sync fixture' >"$DB_PATH/sync/@CORRUPT_DB@"
chmod 000 "$DB_PATH/sync/@CORRUPT_DB@"
PM_MARKED=([aur:plugin]=1)
PM_SELECTION_ORDER=(aur:plugin)
PM_EXTRAS=([aur:plugin]=java-runtime)
PM_TOOL=paru
pm_install_plan_many
printf 'rc=%s\n' "$?"
printf 'provider=%s\n' "${PM_EXTRA_PROVIDER[aur:plugin:java-runtime]}"
printf '%s\n' "$PLAN_TEXT"
printf 'marked='; print_marked
'''.replace("@CORRUPT_DB@", corrupt_db)
                result = run_harness(
                    body,
                    sync_dbs={valid_db: [
                        sync_desc("jdk-openjdk", "17.0.1-1", "java-runtime=17"),
                    ]},
                )
                self.assert_clean(result)
                self.assertIn("rc=1", result["stdout"])
                self.assertIn("could not be independently enumerated", result["stdout"])
                self.assertIn("provider=\n", result["stdout"])
                self.assertNotIn("provider=jdk-openjdk", result["stdout"])
                self.assertIn("marked=aur:plugin", result["stdout"])
                self.assertNotIn("RUN ", result["calls"])

    def test_explicit_exact_extra_keeps_ordinary_path_before_provider_enumeration(self):
        body = r'''
pacman() {
    local name=${!#}
    if [[ $1 == -Sp ]]; then return 1; fi
    if [[ $1 == -Si && $name == java-runtime ]]; then
        printf '%s\n' 'Repository      : extra' 'Name            : java-runtime' \
            'Version         : 17-1' 'Provides        : None'
        return 0
    fi
    return 1
}
DB_PATH=$TEST_TMP/db
PLAN_ROWS=()
pm_add_resolved_extra_row java-runtime aur:plugin extra
printf 'rc=%s\n' "$?"
printf 'provider=%s\n' "${PM_EXTRA_PROVIDER[aur:plugin:java-runtime]}"
printf 'source=%s\n' "${PM_EXTRA_SOURCE[aur:plugin:java-runtime]}"
printf 'rows=%s\n' "${PLAN_ROWS[@]}"
'''
        result = run_harness(
            body,
            sync_dbs={"extra.db": [
                sync_desc("java-runtime", "17-1", "None"),
                sync_desc("jdk-openjdk", "17.0.1-1", "java-runtime=17"),
            ]},
        )
        self.assert_clean(result)
        self.assertIn("rc=0", result["stdout"])
        self.assertIn("provider=java-runtime", result["stdout"])
        self.assertIn("source=repo", result["stdout"])
        self.assertIn("rows=repo|java-runtime||||extra|aur:plugin", result["stdout"])

    def test_repo_app_with_aur_extra_rechecks_helper_before_confirmation(self):
        body = r'''
pacman() {
    local name
    if [[ $1 == -Qq && $# -eq 1 ]]; then
        for name in $TEST_INSTALLED; do printf '%s\n' "$name"; done
        return 0
    fi
    if [[ $1 == -Qq ]]; then
        name=${!#}
        printf 'VERIFY %s\n' "$name" >>"$TEST_CALLS"
        [[ " $TEST_INSTALLED " == *" $name "* ]]
        return
    fi
    if [[ $1 == -Si ]]; then
        name=${!#}
        [[ $name == one ]] || return 1
        printf '%s\n' \
            'Repository      : extra' 'Name            : one' 'Version         : 1.0-1' \
            'Description     : One' 'Depends On      : None' 'Optional Deps   : None' \
            'Download Size   : 1.00 KiB' 'Installed Size  : 2.00 KiB'
        return 0
    fi
    if [[ $1 == -Sp ]]; then
        name=${!#}
        [[ $name == one ]] || return 1
        printf '%s\n' 'one|1.0-1|extra|1024'
        return 0
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() { DEP_HAVE=(); DEP_REPO=(); DEP_AUR=(); }
pm_install_plan() { pm_install_plan_real "$@"; }
pm_choose_installer() {
    printf 'CHOOSE %s\n' "$1" >>"$TEST_CALLS"
    if [[ $1 == aur ]]; then PM_TOOL=paru; else PM_TOOL=pacman; fi
    return 0
}
ui_input() { TUI_INPUT=demo; return 0; }
pm_search() { R_KEYS=(repo:one); R_LABELS=(one); }
ui_multiselect() {
    if [[ ${PM_INSTALL_SUCCESS:-false} == true ]]; then
        PM_ACTION=back
        return 1
    fi
    PM_MARKED=([repo:one]=1)
    PM_SELECTION_ORDER=(repo:one)
    PM_EXTRAS=([repo:one]=aur-extra)
    PM_ACTION=install
    return 0
}
action_install
printf 'action_rc=%s\n' "$?"
'''
        result = run_harness(
            body, installed=("one", "aur-extra"),
            detail_records={"repo:one": {"source": "repo", "name": "one"}},
        )
        self.assert_clean(result)
        self.assertIn("action_rc=0", result["stdout"])
        self.assertIn("CHOOSE repo", result["calls"])
        self.assertIn("CHOOSE aur", result["calls"])
        self.assertIn("DIALOG <Install one>", result["dialogs"])
        self.assertIn("paru (AUR)", result["dialogs"])
        self.assertEqual(result["calls"].count("RUN "), 2, result["calls"])
        repo = result["calls"].index("<sudo>")
        aur = result["calls"].index("<paru>")
        self.assertLess(repo, aur)
        repo_line = next(line for line in result["calls"].splitlines() if "RUN " in line and "<sudo>" in line)
        aur_line = next(line for line in result["calls"].splitlines() if "RUN " in line and "<paru>" in line)
        self.assertIn("<one>", repo_line)
        self.assertNotIn("aur-extra", repo_line)
        self.assertIn("aur-extra", aur_line)
        self.assertNotIn("<one>", aur_line)
        self.assertIn("VERIFY one", result["calls"])
        self.assertIn("VERIFY aur-extra", result["calls"])

    def test_grouped_execution_rejects_pacman_for_aur_without_transactions(self):
        body = r'''
PM_MARKED=([repo:one]=1)
PM_SELECTION_ORDER=(repo:one)
PM_EXTRAS=([repo:one]=aur-extra)
PM_TOOL=pacman
pm_install_plan_many || exit 20
PM_EXTRA_SOURCE=([repo:one:aur-extra]=aur)
pm_execute_install_plan
printf 'rc=%s\n' "$?"
printf 'success=%s\n' "$PM_INSTALL_SUCCESS"
printf 'error=%s\n' "${PM_INSTALL_ERROR:-}"
printf 'unresolved=%s\n' "${UNRESOLVED[*]}"
printf 'logs=%s\n' "${PM_INSTALL_LOGS[*]}"
'''
        result = run_harness(body)
        self.assert_clean(result)
        self.assertIn("rc=1", result["stdout"])
        self.assertIn("success=false", result["stdout"])
        self.assertIn("AUR", result["stdout"])
        self.assertIn("unresolved=AUR", result["stdout"])
        self.assertNotIn("RUN ", result["calls"])
        self.assertNotIn("SUDO", result["calls"])
        self.assertIn("DIALOG <Installation blocked>", result["dialogs"])

    def test_existing_planner_exposes_structured_runtime_build_and_extra_rows(self):
        body = r'''
pacman() {
    if [[ $1 == -Si ]]; then
        printf '%s\n' \
            'Repository      : extra' \
            'Name            : one' \
            'Version         : 1.0-1' \
            'Description     : One' \
            'Depends On      : shared' \
            'Optional Deps   : extra-one: CLI' \
            'Download Size   : 1.00 KiB' \
            'Installed Size  : 2.00 KiB'
        return 0
    fi
    if [[ $1 == -Sp ]]; then
        [[ ${!#} == extra-plugin ]] && return 1
        printf '%s\n' 'one|1.0-1|extra|1024' 'shared|2.0-1|extra|2048' 'extra-one|1.0-1|extra|512'
        return 0
    fi
    return 1
}
pm_about() { return 0; }
pm_dep_users() { return 0; }
pm_classify_deps() {
    DEP_HAVE=() DEP_REPO=() DEP_AUR=()
    local dep
    for dep in "$@"; do
        case $dep in
            meson) DEP_REPO+=("$dep") ;;
            *) DEP_HAVE+=("$dep") ;;
        esac
    done
}
aur_json() {
    printf '%s\n' \
        'Name=plugin' 'Version=1.0-1' 'Description=Plugin' 'Maintainer=maint' \
        'NumVotes=1' 'LastModified=0' 'OutOfDate=' \
        $'Depends=shared' $'OptDepends=extra-plugin: Tools' $'MakeDepends=meson' 'CheckDepends='
}
pm_install_plan_real repo one extra-one || exit 30
printf '%s\n' "${PLAN_ROWS[@]}"
pm_install_plan_real aur plugin extra-plugin || exit 31
printf '%s\n' "${PLAN_ROWS[@]}"
'''
        result = run_harness(body)
        self.assert_clean(result)
        rows = result["stdout"].splitlines()
        self.assertIn("repo|one|1.0-1|extra|1024|selected|repo:one", rows)
        self.assertIn("repo|shared|2.0-1|extra|2048|dependency|repo:one", rows)
        self.assertIn("repo|extra-one|1.0-1|extra|512|extra|repo:one", rows)
        self.assertIn("aur|plugin|1.0-1|AUR||selected|aur:plugin", rows)
        self.assertIn("repo|meson||||build|aur:plugin", rows)
        self.assertIn("aur|extra-plugin|||AUR||extra|aur:plugin", rows)


    def test_use_variant_replaces_only_explicit_targets_strong_component(self):
        records = {
            "repo:demo": {
                "source": "repo", "name": "demo", "package_base": "demo",
                "packager": "Packager", "provides": [], "conflicts": [],
            },
            "aur:demo-bin": {
                "source": "aur", "name": "demo-bin", "package_base": "demo-bin",
                "maintainer": "maint", "provides": ["demo"], "conflicts": [],
            },
            "aur:demo-git": {
                "source": "aur", "name": "demo-git", "package_base": "demo-git",
                "maintainer": "maint", "provides": [], "conflicts": [],
            },
            "aur:demo-cli": {
                "source": "aur", "name": "demo-cli", "package_base": "demo-git",
                "maintainer": "maint", "provides": [], "conflicts": [],
            },
            "repo:other": {"source": "repo", "name": "other"},
        }
        for choice in ("aur:demo-bin", "aur:demo-git"):
            with self.subTest(choice=choice):
                body = r'''
R_KEYS=(repo:demo aur:demo-bin aur:demo-git aur:demo-cli repo:other)
PM_FOCUS=repo:demo
PM_MARKED=([repo:demo]=1 [aur:demo-bin]=1 [aur:demo-git]=1 [aur:demo-cli]=1 [repo:other]=1)
PM_SELECTION_ORDER=(repo:demo aur:demo-bin aur:demo-git aur:demo-cli repo:other)
pm_compare_load || exit 20
printf 'display=%s\n' "${PM_COMPARE_KEYS[*]}"
printf 'replace=%s\n' "${PM_REPLACE_KEYS[*]}"
pm_use_variant ''' + choice + r'''
printf 'rc=%s\n' "$?"
printf 'marked='; print_marked
'''
                result = run_harness(body, detail_records=records)
                self.assert_clean(result)
                self.assertIn("display=repo:demo aur:demo-bin aur:demo-git aur:demo-cli", result["stdout"])
                self.assertIn("replace=repo:demo aur:demo-bin", result["stdout"])
                self.assertIn("rc=0", result["stdout"])
                if choice == "aur:demo-bin":
                    self.assertIn("marked=aur:demo-bin aur:demo-cli aur:demo-git repo:other", result["stdout"])
                else:
                    self.assertIn("marked=aur:demo-bin aur:demo-cli aur:demo-git repo:demo repo:other", result["stdout"])

    def test_action_install_uses_grouped_path_for_multiple_marks(self):
        body = r'''
ui_input() { TUI_INPUT=demo; return 0; }
pm_search() { R_KEYS=(repo:one repo:two); R_LABELS=(one two); }
ui_multiselect() {
    if [[ ${PM_INSTALL_SUCCESS:-false} == true ]]; then
        PM_ACTION=back
        return 1
    fi
    PM_MARKED=([repo:one]=1 [repo:two]=1)
    PM_SELECTION_ORDER=(repo:one repo:two)
    PM_ACTION=install
    return 0
}
action_install
printf 'action_rc=%s\n' "$?"
'''
        result = run_harness(
            body, installed=("one", "two"),
            detail_records={
                "repo:one": {"source": "repo", "name": "one"},
                "repo:two": {"source": "repo", "name": "two"},
            },
        )
        self.assert_clean(result)
        self.assertIn("action_rc=0", result["stdout"])
        self.assertEqual(result["calls"].count("RUN "), 1, result["calls"])
        self.assertIn("<sudo> <pacman> <-S> <--needed> <--> <one> <two>", result["calls"])
        self.assertIn("VERIFY one", result["calls"])
        self.assertIn("VERIFY two", result["calls"])
        self.assertNotIn("not yet implemented", result["dialogs"])


if __name__ == "__main__":
    unittest.main()
