import os
import pty
import signal
import tempfile
import time
import unittest
from pathlib import Path

from _helpers import SCRIPT
from pty_selection import read_available, wait_for


class NoPythonInstallTests(unittest.TestCase):
    def test_action_basic_search_multiselect_preview_install_and_verify(self):
        source = SCRIPT.read_text(encoding="utf-8")
        trailer = 'main "$@"\n'
        self.assertTrue(source.endswith(trailer))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / "runtime"
            runtime.mkdir()
            state = root / "installed"
            state.write_text("", encoding="utf-8")
            calls = root / "calls"
            dialogs = root / "dialogs"
            harness = source[:-len(trailer)] + r'''
have() {
    [[ $1 == python3 ]] && return 1
    [[ $1 == paru ]] && return 0
    command -v "$1" >/dev/null 2>&1
}
command() {
    if [[ $1 == -v && $2 == python3 ]]; then return 1; fi
    builtin command "$@"
}
python3() {
    printf 'PYTHON_INVOKED\n' >>"$TEST_CALLS"
    return 99
}
curl() { return 1; }
paru() {
    if [[ $1 == -Ssa ]]; then
        printf '%s\n' 'aur/aur-one 3.0-1' '    Community package'
        return 0
    fi
    printf 'UNEXPECTED_PARU %s\n' "$*" >>"$TEST_CALLS"
    return 1
}
pacman() {
    local name=${!#} arg
    case $1 in
        -Qq)
            if [[ $# -eq 1 ]]; then cat "$TEST_STATE"; return 0; fi
            printf 'VERIFY %s\n' "$name" >>"$TEST_CALLS"
            grep -Fxq -- "$name" "$TEST_STATE"
            return
            ;;
        -Q)
            grep -Fxq -- "$name" "$TEST_STATE" || return 1
            printf '%s 1.0-1\n' "$name"
            return 0
            ;;
        -Ss)
            printf '%s\n' 'extra/one 1.0-1' '    First package' \
                'extra/two 2.0-1' '    Second package'
            return 0
            ;;
        -Si)
            case $name in one|two) ;; *) return 1 ;; esac
            printf '%s\n' 'Repository      : extra' "Name            : $name" \
                "Version         : $([[ $name == one ]] && printf 1.0-1 || printf 2.0-1)" \
                "Description     : $name package" 'Architecture    : x86_64' \
                'Licenses        : MIT' 'Depends On      : None' 'Optional Deps   : None' \
                'Download Size   : 1.00 KiB' 'Installed Size  : 2.00 KiB' \
                'Packager        : Test Packager <test@example.invalid>'
            return 0
            ;;
        -Sp)
            case $name in one|two) ;; *) return 1 ;; esac
            printf '%s|1.0-1|extra|1024\n' "$name"
            return 0
            ;;
        -T) return 0 ;;
    esac
    printf 'UNEXPECTED_PACMAN %s\n' "$*" >>"$TEST_CALLS"
    return 1
}
pm_choose_installer() {
    printf 'CHOOSE %s\n' "$1" >>"$TEST_CALLS"
    PM_TOOL=pacman
    [[ $1 == aur ]] && PM_TOOL=paru
    return 0
}
pm_run_logged() {
    local arg after=false
    printf 'RUN' >>"$TEST_CALLS"
    printf ' <%s>' "$@" >>"$TEST_CALLS"
    printf '\n' >>"$TEST_CALLS"
    for arg in "$@"; do
        if [[ $after == true ]]; then printf '%s\n' "$arg" >>"$TEST_STATE"
        elif [[ $arg == -- ]]; then after=true; fi
    done
    return 0
}
ensure_sudo() { return 0; }
session_set() { return 0; }
ui_ask() { return 1; }
ui_dialog() {
    {
        printf 'DIALOG <%s>\n%s\n' "$1" "$2"
        printf 'BUTTONS'
        shift 4
        printf ' <%s>' "$@"
        printf '\n'
    } >>"$TEST_DIALOGS"
    TUI_CHOICE=0
    return 0
}
log_info() { return 0; }
log_step() { return 0; }
log_success() { return 0; }
log_error() { printf 'ERROR %s\n' "$*" >>"$TEST_CALLS"; }
log_warning() { return 0; }
diagnose() { return 0; }
report_diagnosis() { return 0; }
apply_fixes() { return 0; }
TMP=$TEST_TMP
HOME=$TEST_HOME
MENU_STYLE=plain
GUI=false
GUI_TOOL=""
AUR_HELPER=paru
INSTALL_HELPER=paru
action_install
printf 'ACTION_RC=%s\n' "$?"
printf 'REPO=%s\n' "${PM_INSTALL_REPO[*]}"
printf 'AUR=%s\n' "${PM_INSTALL_AUR[*]}"
exit 0
'''
            script = root / "scenario.sh"
            script.write_text(harness, encoding="utf-8")
            env = os.environ.copy()
            env.update(
                TEST_TMP=str(runtime), TEST_HOME=str(root), TEST_STATE=str(state),
                TEST_CALLS=str(calls), TEST_DIALOGS=str(dialogs),
                LC_ALL="C.UTF-8", TERM="xterm-256color",
            )
            pid, fd = pty.fork()
            if pid == 0:
                os.execvpe("bash", ["bash", str(script)], env)
            output = b""
            status = None
            try:
                output += wait_for(fd, b"description):")
                os.write(fd, b"demo\n")
                for action in ("c 1", "d 3", "1", "2", "3", "i", "q"):
                    output += wait_for(fd, b"Selection>")
                    os.write(fd, (action + "\n").encode())
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    done, status = os.waitpid(pid, os.WNOHANG)
                    if done == pid:
                        break
                    output += read_available(fd, 0.1)
                else:
                    self.fail("no-Python PTY action did not exit: %r" % output[-8000:])
                output += read_available(fd, 0.1)
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
            self.assertIsNotNone(status)
            self.assertEqual(os.WEXITSTATUS(status), 0, output.decode(errors="replace"))
            output = output.decode(errors="replace")
            preview = dialogs.read_text() if dialogs.exists() else ""
            log = calls.read_text() if calls.exists() else ""
            self.assertIn("ACTION_RC=0", output)
            self.assertIn("Comparison unavailable", preview, output + log)
            self.assertIn("Similar apps unavailable", preview, output + log)
            self.assertNotIn("★0", output)
            self.assertIn("DIALOG <Install 3 marked packages>", preview, output + log)
            self.assertIn("repo:one", preview)
            self.assertIn("repo:two", preview)
            self.assertIn("aur:aur-one", preview)
            self.assertIn("Not available", preview)
            self.assertNotIn("1970-01-01", preview)
            self.assertEqual(preview.count("DIALOG <Install 3 marked packages>"), 1, preview)
            log = calls.read_text() if calls.exists() else ""
            self.assertNotIn("PYTHON_INVOKED", log)
            self.assertNotIn("UNEXPECTED_", log)
            self.assertIn("<sudo> <pacman> <-S> <--needed> <--> <one> <two>", log)
            self.assertIn("<paru> <-S> <--needed> <--> <aur-one>", log)
            self.assertLess(log.index("<sudo>"), log.index("<paru>"))
            for name in ("one", "two", "aur-one"):
                self.assertIn("VERIFY " + name, log)
            self.assertIn("DIALOG <Installation results>", preview, output + log)
            self.assertIn("Every requested package was verified", preview)


if __name__ == "__main__":
    unittest.main()
