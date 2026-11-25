import json
import os
import shlex
import subprocess
import tempfile
from pathlib import Path
from _helpers import SCRIPT

class SelectionModel:
    def __init__(self, packages):
        self.packages = packages
        self.keys = []
        self.notice = ""

    def toggle(self, key, reinstall=False):
        source = SCRIPT.read_text(encoding="utf-8")
        trailer = 'main "$@"\n'
        assert source.endswith(trailer)
        harness = source[:-len(trailer)] + r'''
pacman() {
    if [[ $1 == -Qq ]]; then
        local name=${!#}
        [[ " $TEST_INSTALLED " == *" $name "* ]]
        return
    fi
    return 1
}
for marked in $TEST_MARKED; do PM_MARKED[$marked]=1; done
pm_toggle_key "$1" "$2"
rc=$?
printf '%s\n' "$PM_NOTICE" >"$TEST_NOTICE"
printf '%s\n' "${!PM_MARKED[@]}" | sort >"$TEST_KEYS"
exit "$rc"
'''
        with tempfile.TemporaryDirectory() as tmp:
            notice = Path(tmp) / "notice"
            keys = Path(tmp) / "keys"
            env = os.environ.copy()
            env.update(
                TEST_INSTALLED=" ".join(name.split(":", 1)[1] for name, installed in self.packages.items() if installed),
                TEST_MARKED=" ".join(self.keys), TEST_NOTICE=str(notice), TEST_KEYS=str(keys),
            )
            script = Path(tmp) / "selection.sh"
            script.write_text(harness, encoding="utf-8")
            result = subprocess.run(
                ["bash", str(script), key, "true" if reinstall else "false"],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
            self.notice = notice.read_text().strip()
            self.keys = [key for key in keys.read_text().splitlines() if key] if keys.exists() else []
            return result.returncode == 0


def run_frontend(mode, actions):
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        choices = root / "choices"
        choices.write_text("\n".join(actions) + "\n", encoding="utf-8")
        (root / "offset").write_text("0", encoding="utf-8")
        harness = source[:-len(trailer)] + r'''
pacman() {
    if [[ $1 == -Qq ]]; then
        [[ ${!#} == old ]]
        return
    fi
    if [[ $1 == -Q ]]; then
        [[ ${!#} == old ]] || return 1
        printf 'Q old\n' >>"$TEST_QUERIES"
        printf '%s\n' 'old 0.9-1'
        return 0
    fi
    printf 'unexpected pacman call: %s\n' "$*" >>"$TEST_CALLS"
    return 1
}
_menu_record() {
    printf 'CALL' >>"$TEST_CALLS"
    printf ' <%s>' "$@" >>"$TEST_CALLS"
    printf '\n' >>"$TEST_CALLS"
}
_menu_choice() {
    local offset choice
    read -r offset <"$TEST_OFFSET"
    choice=$(sed -n "$((offset + 1))p" "$TEST_CHOICES")
    printf '%s\n' "$((offset + 1))" >"$TEST_OFFSET"
    [[ -n $choice ]] || return 1
    printf '%s\n' "$choice"
}
_menu_stub() {
    _menu_record "$@"
    local expect_tag=false arg valid=false choice
    while (( $# )); do
        if [[ $1 == --menu ]]; then
            shift 5
            break
        fi
        shift
    done
    choice=$(_menu_choice) || return 1
    expect_tag=true
    for arg in "$@"; do
        if [[ $expect_tag == true ]]; then
            [[ $arg == "$choice" ]] && valid=true
            expect_tag=false
        else
            expect_tag=true
        fi
    done
    [[ $valid == true ]] || { printf 'invalid choice %s\n' "$choice" >>"$TEST_CALLS"; return 2; }
    printf '%s\n' "$choice" >&2
}
dialog() { _menu_stub "$@"; }
whiptail() { _menu_stub "$@"; }
if [[ $TEST_MODE == whiptail ]]; then
    have() {
        [[ $1 == dialog ]] && return 1
        command -v "$1" >/dev/null 2>&1
    }
fi
zenity() {
    _menu_record "$@"
    _menu_choice
}
MENU_STYLE=$TEST_MODE
GUI=false
GUI_TOOL=""
if [[ $TEST_MODE == zenity ]]; then
    MENU_STYLE=auto
    GUI=true
    GUI_TOOL=zenity
fi
TMP=$TEST_TMP
ui_multiselect "Results" "Choose packages" \
    @apps "Applications" \
    repo:one "📦 one 1.0 (extra — First package)" \
    repo:two "📦 two 2.0 (extra — Second package)" \
    aur:old "🧩 old 3.0 (✔ installed · AUR — Installed package)"
printf '%s\n' "$?" >"$TEST_RC"
printf '%s\n' "$PM_ACTION" >"$TEST_TMP/action"
printf '%s\n' "$PM_FOCUS" >"$TEST_TMP/focus"
printf '%s\n' "$PM_NOTICE" >"$TEST_TMP/notice"
printf '%s\n' "${!PM_MARKED[@]}" | sort >"$TEST_TMP/keys"
exit 0
'''
        script = root / "frontend.sh"
        script.write_text(harness, encoding="utf-8")
        calls = root / "calls"
        env = os.environ.copy()
        env.update(
            HOME=tmp,
            TEST_MODE=mode,
            TEST_TMP=tmp,
            TEST_CHOICES=str(choices),
            TEST_OFFSET=str(root / "offset"),
            TEST_CALLS=str(calls),
            TEST_QUERIES=str(root / "queries"),
            TEST_RC=str(root / "rc"),
            LC_ALL="C.UTF-8",
            TERM="xterm-256color",
        )
        command = "bash %s" % shlex.quote(str(script))
        result = subprocess.run(
            ["script", "-qefc", command, "/dev/null"],
            input="\n".join(actions) + "\n",
            text=True,
            capture_output=True,
            env=env,
            timeout=15,
            check=False,
        )
        return {
            "action": (root / "action").read_text().strip() if (root / "action").exists() else "",
            "focus": (root / "focus").read_text().strip() if (root / "focus").exists() else "",
            "notice": (root / "notice").read_text().strip() if (root / "notice").exists() else "",
            "keys": [key for key in (root / "keys").read_text().splitlines() if key] if (root / "keys").exists() else [],
            "rc": (root / "rc").read_text().strip() if (root / "rc").exists() else "missing",
            "calls": calls.read_text() if calls.exists() else "",
            "queries": (root / "queries").read_text() if (root / "queries").exists() else "",
            "output": result.stdout + result.stderr,
        }


def run_action(actions, confirm=False, initial_marks=(), search_confirm=False, details_fail=False, extras=False, variants=False, use_variant=False, variant_core=False, similar="", nested_similar=False):
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        cache = root / "package-details" / "failures"
        cache.mkdir(parents=True)
        (cache / "aur%3Aold.json").write_text(
            '{"failed_at":9999999999,"record":'
            '{"source":"aur","name":"old","repository":"AUR","version":"3.0",'
            '"parent":"","depends":[],"provides":[],"conflicts":[]}}',
            encoding="utf-8",
        )
        if variants:
            success = root / "package-details"
            for name, updated, votes, popularity in (
                ("one-bin", 1799913600, 30, 2.0),
                ("one-git", 1800000000, 100, 4.0),
            ):
                record = {
                    "name": name,
                    "package_base": name,
                    "source": "aur",
                    "repository": "AUR",
                    "version": "2.r1" if name.endswith("-git") else "2.0-1",
                    "installed": False,
                    "installed_version": "",
                    "votes": votes,
                    "popularity": popularity,
                    "user_share": 1.25,
                    "updated": updated,
                    "first_submitted": 1700000000,
                    "out_of_date": None,
                    "depends": ["gtk4"],
                    "make_depends": ["git"] if name.endswith("-git") else [],
                    "check_depends": [],
                    "architectures": ["x86_64"],
                    "maintainer": "maint",
                    "packager": None,
                    "provides": ["one"],
                    "conflicts": ["one"],
                    "parent": "",
                }
                (success / ("aur%%3A%s.json" % name)).write_text(
                    json.dumps(record), encoding="utf-8"
                )
        if similar:
            success = root / "package-details"
            success.mkdir(parents=True, exist_ok=True)
            related = similar == "current"
            records = {
                "one": {
                    "keywords": ["editor", "photography"],
                    "description": "Raster photography editor",
                    "updated": 100,
                },
                "two": {
                    "keywords": ["photography"] if related else [],
                    "description": "Image photography effects" if related else "A program for notes",
                    "updated": 200,
                },
                "old": {
                    "keywords": ["photography"] if related else [],
                    "description": "Photo negatives" if related else "Unrelated notes",
                    "updated": 150,
                },
                "three": {
                    "keywords": ["photography"],
                    "description": "Image RAW development",
                    "updated": 300,
                },
            }
            for name, changes in records.items():
                record = {
                    "name": name,
                    "package_base": name,
                    "source": "aur",
                    "repository": "AUR",
                    "version": "3.0" if name == "old" else "1.0-1",
                    "installed": False,
                    "installed_version": "",
                    "votes": 20,
                    "popularity": 2.0,
                    "first_submitted": 1600000000,
                    "maintainer": "maint",
                    "depends": [],
                    "make_depends": [],
                    "check_depends": [],
                    "optional_depends": [],
                    "architectures": ["x86_64"],
                    "licenses": ["MIT"],
                    "provides": [],
                    "conflicts": [],
                    "groups": [],
                    "parent": "",
                }
                record.update(changes)
                (success / ("aur%%3A%s.json" % name)).write_text(
                    json.dumps(record), encoding="utf-8"
                )
        bin_dir = root / "bin"
        bin_dir.mkdir()
        pacman = bin_dir / "pacman"
        pacman.write_text(r'''#!/bin/sh
if [ "$1" = -Qq ]; then
    if [ "$#" -eq 1 ]; then
        printf '%s\n' 'old'
        exit 0
    fi
    for name in "$@"; do :; done
    [ "$name" = old ]
    exit
fi
if [ "$1" = -Q ]; then
    if [ "$#" -gt 1 ]; then
        for name in "$@"; do :; done
        [ "$name" = old ] || exit 1
    fi
    printf '%s\n' 'old 0.9-1'
    exit 0
fi
if [ "$1" = -Si ]; then
    [ "${TEST_DETAILS_FAIL:-false}" = true ] && exit 1
    printf '%s\n' \
        'Repository      : extra' \
        'Name            : one' \
        'Version         : 1.0-1' \
        'Description     : First package' \
        'Architecture    : x86_64' \
        'Licenses        : MIT' \
        'Depends On      : None' \
        'Optional Deps   : None' \
        'Download Size   : 1.00 KiB' \
        'Installed Size  : 2.00 KiB' \
        'Packager        : Test Packager <test@example.invalid>' \
        'Build Date      : Sun Jan 7 03:04:05 2024' \
        '' \
        'Repository      : extra' \
        'Name            : two' \
        'Version         : 2.0-1' \
        'Description     : Second package' \
        'Architecture    : x86_64' \
        'Depends On      : None' \
        'Optional Deps   : None' \
        'Download Size   : 2.00 KiB' \
        'Installed Size  : 4.00 KiB' \
        'Packager        : Test Packager <test@example.invalid>' \
        'Build Date      : Sun Jan 7 03:04:05 2024'
    exit 0
fi
printf 'unexpected pacman call: %s\n' "$*" >>"$TEST_CALLS"
exit 1
''', encoding="utf-8")
        pacman.chmod(0o755)
        harness = source[:-len(trailer)] + r'''
ui_input() { TUI_INPUT=demo; return 0; }
ui_ask() {
    printf 'ui_ask %s\n' "$1" >>"$TEST_SEARCH"
    [[ ${TEST_SEARCH_CONFIRM:-false} == true ]]
}
pm_search() {
    printf 'pm_search %s\n' "$1" >>"$TEST_SEARCH"
    if [[ -n ${TEST_SIMILAR:-} ]]; then
        : >"$TMP/search_meta"
        if [[ $1 == photography ]]; then
            case $TEST_SIMILAR in
                followup)
                    printf '%s\n' '{"source":"aur","name":"three","user_share":3.5}' >"$TMP/search_meta.jsonl"
                    R_KEYS=(aur:three)
                    R_LABELS=("🧩 three 1.0-1 (AUR — Image RAW development)")
                    printf '%s\n' 'three|app|||||||' >"$TMP/search_meta" ;;
                failed)
                    R_KEYS=() R_LABELS=() ;;
                *)
                    R_KEYS=(aur:old)
                    R_LABELS=("🧩 old 3.0 (AUR — Unrelated notes)")
                    printf '%s\n' 'old|app|||||||' >"$TMP/search_meta" ;;
            esac
            return 0
        fi
        R_KEYS=(@apps aur:one aur:two aur:old)
        R_LABELS=("Applications" "🧩 one 1.0-1 (AUR — Raster photography editor)" "🧩 two 1.0-1 (AUR — Image photography effects)" "🧩 old 3.0 (AUR — Installed package)")
        printf '%s\n' 'one|app|||||||' 'two|app|||||||' 'old|app|||||||' >"$TMP/search_meta"
        printf '%s\n' \
            '{"source":"aur","name":"one","user_share":1.5}' \
            '{"source":"aur","name":"two","user_share":2.5}' \
            '{"source":"aur","name":"old","user_share":0.5}' >"$TMP/search_meta.jsonl"
        return 0
    fi
    R_KEYS=(@apps repo:one repo:two aur:old)
    R_LABELS=("Applications" "📦 one 1.0 (extra — First package)" "📦 two 2.0 (extra — Second package)" "🧩 old 3.0 (AUR — Installed package)")
    if [[ ${TEST_VARIANTS:-false} == true ]]; then
        R_KEYS+=(aur:one-bin aur:one-git)
        R_LABELS+=("🧩 one-bin 2.0-1 (AUR — Binary variant)" "🧩 one-git 2.r1 (AUR — Development variant)")
    fi
    if [[ ${TEST_VARIANT_CORE:-false} == true ]]; then
        printf '%s\n' 'two|plugin|one-git|||||' >"$TMP/search_meta"
    fi
}
ui_dialog() {
    local cancel=$4 title=$1
    {
        printf 'DIALOG <%s>\n' "$1"
        printf '%s\n' "$2"
        printf 'BUTTONS'
        shift 4
        printf ' <%s>' "$@"
        printf '\n'
    } >>"$TEST_DIALOGS"
    if [[ -n ${TEST_SIMILAR:-} && $title == 'Package details: one' && ! -e $TEST_TMP/similar-opened ]]; then
        : >"$TEST_TMP/similar-opened"
        TUI_CHOICE=0
    elif [[ ${TEST_NESTED_SIMILAR:-false} == true && $title == 'Package details: two' && ! -e $TEST_TMP/nested-similar-opened ]]; then
        : >"$TEST_TMP/nested-similar-opened"
        TUI_CHOICE=0
    elif [[ ${TEST_USE_VARIANT:-false} == true && $title == Variant:\ * ]]; then
        TUI_CHOICE=0
    elif [[ ${TEST_EXTRAS:-false} == true && $title == Install\ * && ! -e $TEST_TMP/extras_chosen && " $* " == *" Extras… "* ]]; then
        : >"$TEST_TMP/extras_chosen"
        TUI_CHOICE=1
    elif [[ ${TEST_CONFIRM:-false} == true && $title == Install\ * ]]; then
        TUI_CHOICE=0
    else
        TUI_CHOICE=$cancel
    fi
    return 0
}
pm_choose_installer() {
    printf 'pm_choose_installer %s\n' "$*" >>"$TEST_INSTALLER"
    PM_TOOL=pacman
    [[ $1 == aur ]] && PM_TOOL=paru
    return 0
}
pm_install_plan() {
    printf 'pm_install_plan %s\n' "$*" >>"$TEST_INSTALLER"
    PLAN_TEXT="Preview for $2"
    PLAN_OPT=()
    [[ ${TEST_EXTRAS:-false} == true ]] && PLAN_OPT=("one-cli|CLI")
    PLAN_MAKE=()
    return 0
}
pm_run_logged() { printf 'pm_run_logged %s\n' "$*" >>"$TEST_INSTALLER"; return 0; }
ensure_sudo() { printf 'ensure_sudo\n' >>"$TEST_INSTALLER"; return 0; }
session_set() { return 0; }
log_info() { return 0; }
log_step() { return 0; }
log_success() { return 0; }
log_error() { return 0; }
MENU_STYLE=plain
GUI=false
GUI_TOOL=""
TMP=$TEST_TMP
for marked in $TEST_INITIAL_MARKED; do PM_MARKED[$marked]=1; done
action_install
printf '%s\n' "$?" >"$TEST_RC"
printf '%s\n' "$PM_ACTION" >"$TEST_TMP/action"
printf '%s\n' "$PM_NOTICE" >"$TEST_TMP/notice"
printf '%s\n' "${!PM_MARKED[@]}" | sort >"$TEST_TMP/keys"
printf '%s\n' "${PM_SIMILAR_KEYS[@]}" >"$TEST_TMP/similar-keys"
: >"$TEST_TMP/similar-reasons"
for key in "${PM_SIMILAR_KEYS[@]}"; do
    printf '%s|%s\n' "$key" "${PM_SIMILAR_REASONS[$key]}" >>"$TEST_TMP/similar-reasons"
done
printf '%s\n' "${R_KEYS[@]}" >"$TEST_TMP/result-keys"
printf '%s\n' "${R_LABELS[@]}" >"$TEST_TMP/result-labels"
printf '%s\n' "${PM_SELECTION_ORDER[@]}" >"$TEST_TMP/selection-order"
[[ ! -r $TMP/search_meta ]] || cp "$TMP/search_meta" "$TEST_TMP/result-meta"
[[ ! -r $TMP/search_meta.jsonl ]] || cp "$TMP/search_meta.jsonl" "$TEST_TMP/result-meta-jsonl"
exit 0
'''
        script = root / "action.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(
            HOME=tmp,
            PATH=str(bin_dir) + os.pathsep + env.get("PATH", ""),
            TEST_TMP=tmp,
            TEST_CALLS=str(root / "calls"),
            TEST_DIALOGS=str(root / "dialogs"),
            TEST_INSTALLER=str(root / "installer"),
            TEST_SEARCH=str(root / "search"),
            TEST_RC=str(root / "rc"),
            TEST_CONFIRM="true" if confirm else "false",
            TEST_INITIAL_MARKED=" ".join(initial_marks),
            TEST_SEARCH_CONFIRM="true" if search_confirm else "false",
            TEST_DETAILS_FAIL="true" if details_fail else "false",
            TEST_EXTRAS="true" if extras else "false",
            TEST_VARIANTS="true" if variants else "false",
            TEST_USE_VARIANT="true" if use_variant else "false",
            TEST_VARIANT_CORE="true" if variant_core else "false",
            TEST_SIMILAR=similar,
            TEST_NESTED_SIMILAR="true" if nested_similar else "false",
            LC_ALL="C.UTF-8",
            TERM="xterm-256color",
        )
        command = "bash %s" % shlex.quote(str(script))
        result = subprocess.run(
            ["script", "-qefc", command, "/dev/null"],
            input="\n".join(actions) + "\n",
            text=True,
            capture_output=True,
            env=env,
            timeout=20,
            check=False,
        )
        installer = root / "installer"
        dialogs = root / "dialogs"
        return {
            "action": (root / "action").read_text().strip() if (root / "action").exists() else "",
            "keys": [key for key in (root / "keys").read_text().splitlines() if key] if (root / "keys").exists() else [],
            "notice": (root / "notice").read_text().strip() if (root / "notice").exists() else "",
            "rc": (root / "rc").read_text().strip() if (root / "rc").exists() else "missing",
            "similar_keys": [key for key in (root / "similar-keys").read_text().splitlines() if key],
            "similar_reasons": dict(
                line.split("|", 1)
                for line in (root / "similar-reasons").read_text().splitlines()
                if line
            ),
            "result_keys": [key for key in (root / "result-keys").read_text().splitlines() if key],
            "result_labels": (root / "result-labels").read_text(),
            "selection_order": [key for key in (root / "selection-order").read_text().splitlines() if key],
            "result_meta": (root / "result-meta").read_text() if (root / "result-meta").exists() else "",
            "result_jsonl": (root / "result-meta-jsonl").read_text() if (root / "result-meta-jsonl").exists() else "",
            "dialogs": dialogs.read_text() if dialogs.exists() else "",
            "installer": installer.read_text() if installer.exists() else "",
            "search": (root / "search").read_text() if (root / "search").exists() else "",
            "calls": (root / "calls").read_text() if (root / "calls").exists() else "",
            "cache": list((root / "package-details").glob("*.json")) if (root / "package-details").exists() else [],
            "output": result.stdout + result.stderr,
        }
