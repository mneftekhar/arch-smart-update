import json
import os
import pty
import re
import select
import signal
import tempfile
import time
from pathlib import Path

from _helpers import SCRIPT


def read_available(fd, duration=0.2):
    output = b""
    deadline = time.monotonic() + duration
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            break
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        deadline = time.monotonic() + 0.08
    return output


def wait_for(fd, needle, timeout=8):
    output = b""
    deadline = time.monotonic() + timeout
    while needle not in output and time.monotonic() < deadline:
        output += read_available(fd, 0.2)
    if needle not in output:
        raise AssertionError("PTY did not render %r; output=%r" % (needle, output[-2000:]))
    return output


def run_scenario(inputs, legacy=False, menu_style="modern"):
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        invocation = r'''ui_multiselect "Results" "Choose packages" \
    @apps "Applications" \
    repo:one "📦 one 1.0 (extra — First package)" \
    repo:two "📦 two 2.0 (extra — Second package)" \
    aur:old "🧩 old 3.0 (AUR — Installed package)"'''
        if legacy:
            invocation = r'''CHOICE=$(ui_choose "Legacy" "Choose one" \
    @apps "Applications" \
    repo:one "📦 one 1.0 (extra — First package)" \
    repo:two "📦 two 2.0 (extra — Second package)" \
    aur:old "🧩 old 3.0 (AUR — Installed package)")'''
        harness = source[:-len(trailer)] + r'''
pacman() {
    if [[ $1 == -Qq ]]; then
        [[ ${!#} == old ]]
        return
    fi
    if [[ $1 == -Q ]]; then
        [[ ${!#} == old ]] || return 1
        printf '%s\n' 'old 0.9-1'
        return 0
    fi
    return 1
}
MENU_STYLE=''' + menu_style + r'''
GUI=false
GUI_TOOL=""
TERM=xterm-256color
TMP=$1
stty rows 24 cols 100 </dev/tty
''' + invocation + r'''
rc=$?
{
    printf 'action=%s\n' "$PM_ACTION"
    printf 'focus=%s\n' "$PM_FOCUS"
    printf 'choice=%s\n' "${CHOICE:-}"
    printf 'keys='
    printf '%s,' "${!PM_MARKED[@]}"
    printf '\n'
} >"$1/result"
exit "$rc"
'''
        script = Path(tmp) / "scenario.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(script), tmp], env)
        output = b""
        try:
            output += wait_for(fd, b"First package")
            for value in inputs:
                os.write(fd, value)
                time.sleep(0.15)
                output += read_available(fd, 0.1)
            deadline = time.monotonic() + 8
            status = None
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    break
                output += read_available(fd, 0.1)
            else:
                raise AssertionError("PTY scenario did not exit: legacy=%r output=%r" % (legacy, output[-1000:]))
            output += read_available(fd, 0.1)
            fields = dict(line.split("=", 1) for line in (Path(tmp) / "result").read_text().splitlines())
            fields["keys"] = sorted(key for key in fields["keys"].split(",") if key)
            fields["status"] = os.WEXITSTATUS(status) if os.WIFEXITED(status) else None
            fields["output"] = output
            return fields
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)


def run_comparison_scenario(inputs):
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        harness = source[:-len(trailer)] + r'''
pacman() {
    if [[ $1 == -Qq ]]; then
        if (( $# == 1 )); then
            printf '%s\n' 'old'
            return 0
        fi
        [[ ${!#} == old ]]
        return
    fi
    if [[ $1 == -Q ]]; then
        if (( $# == 1 )); then
            printf '%s\n' 'old 0.9-1'
            return 0
        fi
        [[ ${!#} == old ]] || return 1
        printf '%s\n' 'old 0.9-1'
        return 0
    fi
    return 1
}
pm_selection_records_load() { return 0; }
pm_execute_install_plan() { : >"$1/unexpected-install"; }
MENU_STYLE=modern
GUI=false
GUI_TOOL=""
TERM=xterm-256color
TMP=$1
stty rows 32 cols 120 </dev/tty
printf '%s\n' '{
  "repo:one": {
    "name":"one", "package_base":"one", "source":"repo", "repository":"extra",
    "version":"1.0-1", "installed":false, "installed_version":"", "updated":100,
    "packager":"Packager", "provides":[], "conflicts":[], "depends":["gtk4"],
    "make_depends":[], "check_depends":[], "architectures":["x86_64"],
    "download_size":1024, "installed_size":4096, "parent":""
  },
  "repo:two": {
    "name":"two", "package_base":"two", "source":"repo", "repository":"extra",
    "version":"2.0-1", "installed":false, "updated":100, "packager":"Packager",
    "provides":[], "conflicts":[], "depends":[], "parent":""
  },
  "aur:one-bin": {
    "name":"one-bin", "package_base":"one-bin", "source":"aur", "repository":"AUR",
    "version":"2.0-1", "installed":false, "updated":1799913600,
    "first_submitted":1700000000, "maintainer":"maint", "votes":30,
    "popularity":2.0, "user_share":1.25, "provides":["one"], "conflicts":["one"],
    "depends":["gtk4"], "make_depends":[], "check_depends":[],
    "architectures":["x86_64"], "parent":""
  },
  "aur:one-git": {
    "name":"one-git", "package_base":"one-git", "source":"aur", "repository":"AUR",
    "version":"2.r1", "installed":false, "updated":1800000000,
    "first_submitted":1700000000, "maintainer":"maint", "votes":100,
    "popularity":4.0, "user_share":2.5, "provides":["one"], "conflicts":["one"],
    "depends":["gtk4"], "make_depends":["git"], "check_depends":[],
    "architectures":["x86_64"], "parent":""
  }
}' >"$1/selection-records.json"
R_KEYS=(repo:one repo:two aur:one-bin aur:one-git)
R_LABELS=(one two one-bin one-git)
PM_FOCUS=repo:one
PM_MARKED=([repo:two]=1 [aur:one-git]=1)
PM_SELECTION_ORDER=(repo:two aur:one-git)
pm_compare_menu
rc=$?
printf '%s' "$PM_COMPARE_TEXT" >"$1/compare-text"
printf '%s\n' "${PM_COMPARE_KEYS[@]}" >"$1/compare-keys"
{
    printf 'recommended=%s\n' "$PM_RECOMMENDED_KEY"
    printf 'keys='
    printf '%s,' "${!PM_MARKED[@]}"
    printf '\n'
} >"$1/result"
exit "$rc"
'''
        script = Path(tmp) / "comparison.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(script), tmp], env)
        output = b""
        try:
            output += wait_for(fd, b"Compare package variants")
            for value in inputs:
                os.write(fd, value)
                time.sleep(0.2)
                output += read_available(fd, 0.15)
            deadline = time.monotonic() + 8
            status = None
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    break
                output += read_available(fd, 0.1)
            else:
                raise AssertionError("PTY comparison did not exit: %r" % output[-2000:])
            output += read_available(fd, 0.1)
            fields = dict(line.split("=", 1) for line in (Path(tmp) / "result").read_text().splitlines())
            fields["keys"] = sorted(key for key in fields["keys"].split(",") if key)
            fields["status"] = os.WEXITSTATUS(status) if os.WIFEXITED(status) else None
            fields["output"] = output
            fields["compare_text"] = (Path(tmp) / "compare-text").read_text()
            fields["compare_keys"] = (Path(tmp) / "compare-keys").read_text().splitlines()
            fields["installed"] = (Path(tmp) / "unexpected-install").exists()
            return fields
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)


def run_similar_scenario(empty=False):
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        cache = Path(tmp) / "package-details"
        cache.mkdir()
        for name in ("one", "two"):
            related = name == "two" and not empty
            record = {
                "name": name,
                "package_base": name,
                "source": "aur",
                "repository": "AUR",
                "version": "1.0-1",
                "description": "Image photography effects" if related else (
                    "A program for notes" if name == "two" else "Raster photography editor"
                ),
                "keywords": ["photography"] if name == "one" or related else [],
                "groups": [],
                "category": "app",
                "updated": 200 if name == "two" else 100,
                "votes": 10,
                "popularity": 1.0,
                "depends": [],
                "provides": [],
                "conflicts": [],
                "parent": "",
            }
            (cache / ("aur%%3A%s.json" % name)).write_text(
                json.dumps(record), encoding="utf-8"
            )
        harness = source[:-len(trailer)] + r'''
pacman() { return 1; }
ui_input() { TUI_INPUT=demo; return 0; }
pm_search() {
    printf '%s\n' "$1" >>"$TMP/searches"
    R_KEYS=(@apps aur:one aur:two)
    R_LABELS=("Applications" "🧩 one 1.0-1 (AUR — Raster photography editor)" "🧩 two 1.0-1 (AUR — Image photography effects)")
    printf '%s\n' 'one|app|||||||' 'two|app|||||||' >"$TMP/search_meta"
}
pm_execute_install_plan() { : >"$1/unexpected-install"; }
MENU_STYLE=modern
GUI=false
GUI_TOOL=""
TERM=xterm-256color
TMP=$1
stty rows 32 cols 120 </dev/tty
action_install
rc=$?
printf '%s\n' "${PM_SIMILAR_KEYS[@]}" >"$1/similar-keys"
: >"$1/similar-reasons"
for key in "${PM_SIMILAR_KEYS[@]}"; do
    printf '%s|%s\n' "$key" "${PM_SIMILAR_REASONS[$key]}" >>"$1/similar-reasons"
done
printf '%s\n' "${!PM_MARKED[@]}" | sort >"$1/marked"
exit "$rc"
'''
        script = Path(tmp) / "similar.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(script), tmp], env)
        output = b""
        try:
            output += wait_for(fd, b"Raster photography editor")
            os.write(fd, b"\r")
            output += wait_for(fd, b"Package details: one")
            os.write(fd, b"\r")
            if empty:
                output += wait_for(fd, b"No reliable similar applications found")
                os.write(fd, b"\r")
            else:
                output += wait_for(fd, b"Similar apps for")
                output += wait_for(fd, b"Shared keyword: photography")
            time.sleep(0.15)
            output += read_available(fd, 0.1)
            os.write(fd, b"\x1b")
            time.sleep(0.2)
            output += read_available(fd, 0.1)
            if not empty:
                os.write(fd, b"\x1b")
            deadline = time.monotonic() + 8
            status = None
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    break
                output += read_available(fd, 0.1)
            else:
                raise AssertionError("PTY similarity scenario did not exit: %r" % output[-2000:])
            output += read_available(fd, 0.1)
            searches = (Path(tmp) / "searches").read_text().splitlines()
            return {
                "status": os.WEXITSTATUS(status) if os.WIFEXITED(status) else None,
                "output": output,
                "similar_keys": [key for key in (Path(tmp) / "similar-keys").read_text().splitlines() if key],
                "similar_reasons": dict(
                    line.split("|", 1)
                    for line in (Path(tmp) / "similar-reasons").read_text().splitlines()
                    if line
                ),
                "marked": [key for key in (Path(tmp) / "marked").read_text().splitlines() if key],
                "searches": searches,
                "installed": (Path(tmp) / "unexpected-install").exists(),
            }
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)


def run_parent_state_scenario():
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "search_meta").write_text(
            "plugin|plugin|core|||||\ncore-provider|app||||||\n", encoding="utf-8"
        )
        (root / "search_meta.jsonl").write_text(
            '{"source":"repo","name":"core-provider","provides":["core=1"]}\n',
            encoding="utf-8",
        )
        harness = source[:-len(trailer)] + r'''
pacman() {
    if [[ $1 == -T ]]; then return 1; fi
    return 1
}
MENU_STYLE=modern
GUI=false
GUI_TOOL=""
TERM=xterm-256color
TMP=$1
PM_MARKED=([repo:core-provider]=1)
stty rows 24 cols 120 </dev/tty
ui_multiselect "Results" "Choose packages" \
    @apps "Applications" \
    aur:plugin "🧩 plugin 1.0" \
    repo:core-provider "📦 core-provider 1.0"
exit "$?"
'''
        script = root / "parent-state.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(script), tmp], env)
        output = b""
        try:
            output += wait_for(fd, b"requires core: core (selected)")
            os.write(fd, b"\x1b")
            deadline = time.monotonic() + 8
            status = None
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    break
                output += read_available(fd, 0.1)
            else:
                raise AssertionError("modern parent-state scenario did not exit")
            output += read_available(fd, 0.1)
            if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 1:
                raise AssertionError("modern parent-state scenario failed: %r" % status)
            return output
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)


def run_full_panel_scenario():
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "search_meta").write_text("one|app||||||\ntwo|app||||||\n", encoding="utf-8")
        records = []
        for index, name in enumerate(("one", "two"), 1):
            records.append({
                "name": name, "package_base": name, "source": "repo", "repository": "extra",
                "version": f"{index}.0-1", "description": f"Complete metadata for {name}",
                "installed": False, "votes": None, "popularity": None, "user_share": 1.25,
                "updated": 1700000000, "download_size": 1572864, "installed_size": 4194304,
                "depends": ["gtk4"], "optional_depends": ["demo-cli: CLI"],
                "architectures": ["x86_64"], "licenses": ["MIT"], "packager": "Packager",
                "url": f"https://{name}.invalid", "provides": [], "conflicts": [],
                "groups": [], "keywords": [], "category": "app", "addons": ["addon-one"],
            })
        (root / "search_meta.jsonl").write_text(
            "".join(json.dumps(record) + "\n" for record in records), encoding="utf-8"
        )
        harness = source[:-len(trailer)] + r'''
pacman() { return 1; }
pm_about() {
    local name=$1 source=$2
    printf '%s\n' "$source:$name" >>"$TMP/panel-calls"
    sleep 1
    printf 'Complete background details for %s\n' "$name"
    python3 -I -c "$PM_PACKAGE_LIB_PY" --summary-details "$TMP/search_meta" "$source:$name" ""
}
MENU_STYLE=modern
GUI=false
GUI_TOOL=""
TERM=xterm-256color
TMP=$1
stty rows 24 cols 120 </dev/tty
ui_multiselect "Results" "Choose packages" \
    @apps "Applications" \
    repo:one "📦 one 1.0-1" \
    repo:two "📦 two 2.0-1"
exit "$?"
'''
        script = root / "full-panel.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(script), tmp], env)
        output = b""
        try:
            output += wait_for(fd, b"Package: one 1.0-1", timeout=0.75)
            if b"Details: top" not in output:
                output += wait_for(fd, b"Details: top", timeout=0.75)
            started = time.monotonic()
            output = b""
            os.write(fd, b"\x1b[B")
            output += wait_for(fd, b"Package: two 2.0-1", timeout=0.75)
            navigation_seconds = time.monotonic() - started
            output += wait_for(fd, b"Complete background details for two", timeout=6)
            for _ in range(4):
                if b"Details: bottom" in output:
                    break
                os.write(fd, b"]")
                output += read_available(fd, 0.4)
            if b"Details: bottom" not in output:
                raise AssertionError("right panel did not scroll to its bottom: %r" % output[-3000:])
            for expected in (
                b"Architecture: x86_64", b"Package size: 1.5 MiB",
                b"Installed size: 4.0 MiB", b"Licenses: MIT",
                b"Maintainer / packager: Packager", b"Runtime requirements: gtk4",
                b"Optional requirements: demo-cli: CLI", b"Homepage: https://two.invalid",
            ):
                if expected not in output:
                    raise AssertionError("right panel omitted %r; output=%r" % (expected, output[-3000:]))
            os.write(fd, b"[")
            output += read_available(fd, 0.4)
            if output.count(b"Details: top") < 1:
                raise AssertionError("right panel did not return to its top")
            os.write(fd, b"q")
            deadline = time.monotonic() + 8
            status = None
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    break
                output += read_available(fd, 0.1)
            else:
                raise AssertionError("right-panel scenario did not exit")
            calls_path = root / "panel-calls"
            calls = calls_path.read_text().splitlines() if calls_path.exists() else []
            return {
                "output": output,
                "calls": calls,
                "navigation_seconds": navigation_seconds,
                "status": os.WEXITSTATUS(status) if os.WIFEXITED(status) else None,
            }
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)


def main():
    source = SCRIPT.read_text(encoding="utf-8")
    trailer = 'main "$@"\n'
    assert source.endswith(trailer)
    with tempfile.TemporaryDirectory() as tmp:
        result = Path(tmp) / "result"
        harness = source[:-len(trailer)] + r'''
pacman() {
    if [[ $1 == -Qq ]]; then
        [[ ${!#} == old ]]
        return
    fi
    if [[ $1 == -Q ]]; then
        [[ ${!#} == old ]] || return 1
        printf '%s\n' 'old 0.9-1'
        return 0
    fi
    printf 'unexpected pacman call: %s\n' "$*" >&2
    return 1
}
MENU_STYLE=modern
GUI=false
GUI_TOOL=""
TERM=xterm-256color
TMP=$1
stty rows 24 cols 100 </dev/tty
ui_multiselect "Results" "Choose packages" \
    @apps "Applications" \
    repo:one "📦 one 1.0 (extra — First package)" \
    repo:two "📦 two 2.0 (extra — Second package)" \
    aur:old "🧩 old 3.0 (✔ installed · AUR — Installed package)"
rc=$?
{
    printf 'action=%s\n' "$PM_ACTION"
    printf 'focus=%s\n' "$PM_FOCUS"
    printf 'keys='
    printf '%s,' "${!PM_MARKED[@]}"
    printf '\n'
} >"$1/result"
exit "$rc"
'''
        script = Path(tmp) / "selection.sh"
        script.write_text(harness, encoding="utf-8")
        env = os.environ.copy()
        env.update(TERM="xterm-256color", LC_ALL="C.UTF-8")
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", str(script), tmp], env)

        output = b""
        try:
            output += wait_for(fd, "First package".encode())
            os.write(fd, b" ")
            first = wait_for(fd, "[✓]".encode())
            output += first
            if not re.search(rb"\x1b\[48;5;60m(?:\x1b\[[0-9;]*m)+two 2\.0", first):
                raise AssertionError("Space did not advance the highlight to the second row")
            os.write(fd, b" ")
            output += wait_for(fd, "installed version 0.9-1".encode())
            os.write(fd, b"i")
            deadline = time.monotonic() + 8
            status = None
            while time.monotonic() < deadline:
                done, status = os.waitpid(pid, os.WNOHANG)
                if done == pid:
                    break
                output += read_available(fd, 0.1)
            else:
                raise AssertionError("modern multi-select did not submit after two Space presses and i")
            output += read_available(fd, 0.1)
            if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
                raise AssertionError("selection shell failed: status=%r output=%r" % (status, output[-2000:]))
            fields = dict(line.split("=", 1) for line in result.read_text().splitlines())
            keys = sorted(key for key in fields["keys"].split(",") if key)
            if fields["action"] != "install" or keys != ["repo:one", "repo:two"]:
                raise AssertionError("wrong marked submission: %r" % fields)
            if "[installed]" not in output.decode("utf-8", "replace"):
                raise AssertionError("installed row was not presented with [installed]")
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(fd)

    details = run_scenario([b" ", b"\r"])
    if details["action"] != "details" or details["focus"] != "repo:two" or details["keys"] != ["repo:one"]:
        raise AssertionError("modern Enter/details did not preserve selection: %r" % details)
    compare = run_scenario([b" ", b"c"])
    if compare["action"] != "compare" or compare["focus"] != "repo:two" or compare["keys"] != ["repo:one"]:
        raise AssertionError("modern Compare did not preserve selection: %r" % compare)
    reviewed = run_comparison_scenario([b"\x1b[B", b"\r", b"\x1b"])
    if reviewed["keys"] != ["aur:one-git", "repo:two"] or reviewed["installed"]:
        raise AssertionError("reviewing a recommendation mutated selection or installed: %r" % reviewed)
    if reviewed["recommended"] != "aur:one-bin":
        raise AssertionError("wrong PTY recommendation: %r" % reviewed)
    if reviewed["compare_keys"] != ["repo:one", "aur:one-bin", "aur:one-git"]:
        raise AssertionError("comparison changed candidate order: %r" % reviewed["compare_keys"])
    for expected in ("AUR votes: 30", "pkgstats popularity: 1.25", "Build-only requirements: git", "Conflicts with:"):
        if expected not in reviewed["compare_text"]:
            raise AssertionError("comparison omitted %r" % expected)
    used = run_comparison_scenario([b"\x1b[B", b"\r", b"\x1b[D", b"\r"])
    if used["keys"] != ["aur:one-bin", "repo:two"] or used["installed"]:
        raise AssertionError("Use this variant did not replace exactly the family mark: %r" % used)
    escaped = run_scenario([b" ", b"\x1b"])
    if escaped["action"] != "back" or escaped["status"] != 1 or escaped["keys"] != ["repo:one"]:
        raise AssertionError("modern Escape did not leave with state intact: %r" % escaped)
    legacy_space = run_scenario([b" "], legacy=True)
    if legacy_space["choice"] != "repo:one" or legacy_space["status"] != 0:
        raise AssertionError("legacy Space no longer activates one choice: %r" % legacy_space)
    legacy_enter = run_scenario([b"\x1b[B", b"\r"], legacy=True)
    if legacy_enter["choice"] != "repo:two" or legacy_enter["status"] != 0:
        raise AssertionError("legacy Enter no longer activates the highlighted choice: %r" % legacy_enter)
    plain = run_scenario([b"1\n", b"2\n", b"i\n"], menu_style="plain")
    if (plain["action"] != "install" or plain["keys"] != ["repo:one", "repo:two"]
            or plain["status"] != 0):
        raise AssertionError("plain multi-select did not submit both marks: %r" % plain)
    plain_output = plain["output"]
    for expected in ("[✓]".encode(), b"[installed]", b"installed version 0.9-1"):
        if expected not in plain_output:
            raise AssertionError("plain output omitted marker/version %r" % expected)
    plain_text = re.sub(rb"\x1b\[[0-9;]*m", b"", plain_output)
    if any(sequence in plain_text for sequence in (b"\x1b", b"\x9b", b"\x07")):
        raise AssertionError("plain output contains a non-SGR terminal control sequence: %r" % plain_text)
    if re.search(rb"\\(?:x1b|033|e)\[", plain_text):
        raise AssertionError("plain output contains literal terminal escape text: %r" % plain_text)
    similar = run_similar_scenario()
    if (similar["similar_keys"] != ["aur:two"] or similar["marked"]
            or similar["searches"] != ["demo"] or similar["installed"]):
        raise AssertionError("modern Similar apps changed selection or searched unnecessarily: %r" % similar)
    if similar["similar_reasons"].get("aur:two") != "Shared keyword: photography":
        raise AssertionError("modern Similar apps omitted its evidence: %r" % similar)
    similar_empty = run_similar_scenario(empty=True)
    if (similar_empty["similar_keys"] or similar_empty["marked"]
            or similar_empty["searches"] != ["demo", "photography"]
            or similar_empty["installed"]):
        raise AssertionError("modern empty Similar apps violated its search bound: %r" % similar_empty)
    if b"No reliable similar applications found" not in similar_empty["output"]:
        raise AssertionError("modern empty Similar apps omitted the exact empty message")
    run_parent_state_scenario()
    panel = run_full_panel_scenario()
    if panel["status"] != 1 or panel["calls"] != ["repo:one", "repo:two"]:
        raise AssertionError("right-panel background loading or exit failed: %r" % panel)
    if panel["navigation_seconds"] >= 0.75:
        raise AssertionError("right-panel navigation blocked on metadata: %r" % panel["navigation_seconds"])
    for unexpected in (b"Traceback", b'{"name"', b'{"source"'):
        if unexpected in panel["output"]:
            raise AssertionError("right-panel output contains raw diagnostics: %r" % unexpected)

    print("PASS: selection, comparison, Similar apps, full right-panel details, plain-mode control safety, and exact empty behavior")


if __name__ == "__main__":
    main()
