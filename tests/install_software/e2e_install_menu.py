import json
import os
import pty
import re
import select
import signal
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path

from _helpers import SCRIPT, load_library


HOME = "\x1b[H"
END = "\x1b[F"
UP = "\x1b[A"
DOWN = "\x1b[B"
PGDN = "\x1b[6~"
ESC = "\x1b"
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\)|[()][A-Z0-9]|[=>])")


def clean_terminal(data):
    if isinstance(data, (bytes, bytearray)):
        data = bytes(data).decode("utf-8", "replace")
    return ANSI.sub("", data).replace("\r", "")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def require_refreshed_installed_colors(capture):
    tok = b"\x1b[38;5;114m"
    markers = list(re.finditer(r"\[(?:installed|✓ installed|✓| )\]".encode(), capture))
    colored_rows = []
    for index, marker in enumerate(markers):
        if marker.group() != b"[installed]":
            continue
        start = marker.start() - len(tok)
        if capture[start:marker.start()] != tok:
            continue
        end = markers[index + 1].start() if index + 1 < len(markers) else len(capture)
        colored_rows.append(clean_terminal(capture[start:end]))
    for name, version in (
        ("alpha", "1.0-1"),
        ("beta", "2.0-1"),
        ("coreapp", "1.0-1"),
        ("alpha-plugin", "1.0-1"),
    ):
        pattern = re.compile(
            r"\[installed\].*?\b" + re.escape(name) + r"\s+" + re.escape(version)
            + r"\b[^\n]*?installed version " + re.escape(version)
        )
        require(
            any(pattern.search(row) for row in colored_rows),
            "refreshed installed T_OK row missing for " + name,
        )


def fixture_records():
    lib = load_library()
    now = int(time.time())
    day = 86400
    build = int(time.mktime(time.strptime("Sun Jan 7 03:04:05 2024", "%a %b %d %H:%M:%S %Y")))
    records = {}

    def add(key, source, name, **changes):
        record = lib["new_package"](name)
        record.update({
            "source": source,
            "repository": "extra" if source == "repo" else "AUR",
            "package_base": name,
            "version": "1.0-1",
            "description": name + " fixture",
            "updated": now - day,
            "first_submitted": now - 400 * day,
            "maintainer": "Fixture Maintainer" if source == "aur" else None,
            "packager": "Fixture Packager <packager@example.invalid>" if source == "repo" else None,
            "architectures": ["x86_64"],
            "licenses": ["MIT"],
            "depends": [],
            "make_depends": [] if source == "aur" else None,
            "check_depends": [] if source == "aur" else None,
            "optional_depends": [],
            "votes": 10 if source == "aur" else None,
            "popularity": 1.0 if source == "aur" else None,
            "user_share": 1.25,
            "provides": [],
            "conflicts": [],
            "parent": "",
            "category": "app",
        })
        if source == "repo":
            record["_unavailable"] = ["make_depends", "check_depends"]
        record.update(changes)
        records[key] = record

    add(
        "repo:alpha", "repo", "alpha",
        description="Raster photography editor",
        updated=build,
        download_size=1536 * 1024,
        installed_size=4 * 1024 * 1024,
        packager="Example Packager <packager@example.invalid>",
        depends=["runtime-alpha"],
        optional_depends=["alpha-cli: CLI"],
        keywords=["photography"],
        user_share=12.5,
    )
    add(
        "aur:beta", "aur", "beta",
        version="2.0-1",
        description="Structured writing application",
        architectures=["x86_64", "aarch64"],
        licenses=["GPL-3.0-only"],
        maintainer="Beta Maintainer",
        updated=now - 3 * day,
        votes=42,
        popularity=3.25,
        user_share=1.5,
        depends=["runtime-beta"],
        make_depends=["meson"],
        check_depends=["check-beta"],
        optional_depends=["beta-cli: CLI tools"],
        keywords=["writing"],
    )
    add(
        "aur:gamma", "aur", "gamma",
        description="Raster photography workflow",
        updated=now - 2 * day,
        votes=8,
        popularity=0.8,
        keywords=["photography"],
    )
    add(
        "aur:alpha-bin", "aur", "alpha-bin",
        version="2.0-1",
        description="Binary photography editor",
        variant="binary",
        updated=now - day,
        votes=30,
        popularity=2.0,
        provides=["alpha"],
        conflicts=["alpha"],
        depends=["runtime-alpha"],
    )
    add(
        "aur:alpha-source", "aur", "alpha-source",
        version="2.0-1",
        description="Source photography editor",
        updated=now - 5 * day,
        votes=10,
        popularity=1.0,
        provides=["alpha"],
        make_depends=["meson"],
        check_depends=["check-alpha"],
    )
    add(
        "aur:alpha-git", "aur", "alpha-git",
        version="2.r1",
        description="Development photography editor",
        variant="vcs",
        updated=now,
        votes=100,
        popularity=4.0,
        provides=["alpha"],
        conflicts=["alpha"],
        make_depends=["git"],
    )
    add(
        "repo:coreapp", "repo", "coreapp",
        description="Core photography application",
        updated=build,
        download_size=1024,
        installed_size=4096,
    )
    add(
        "aur:installed", "aur", "installed",
        description="Already installed fixture",
        installed=True,
        installed_version="0.9-1",
    )
    add(
        "aur:alpha-plugin", "aur", "alpha-plugin",
        description="Photography plugin for coreapp",
        parent="coreapp",
        category="plugin",
        depends=["coreapp", "runtime-plugin"],
        make_depends=["ninja"],
        check_depends=["check-plugin"],
        optional_depends=["plugin-cli: Plugin tools"],
    )
    return records, now, build


def search_metadata(records):
    lines = []
    for key, record in records.items():
        lines.append("|".join([
            record["name"],
            record["category"],
            record["parent"],
            str(record["user_share"]),
            "" if record["votes"] is None else str(record["votes"]),
            str(record["updated"] or 0),
            "",
            "",
            record["alt"],
        ]))
    return "\n".join(lines) + "\n"


HARNESS = r'''
TMP=$1
TEST_TMP=$1
TEST_FIXTURE_META=$2
TEST_EVENTS=$TMP/events
TEST_UI=$TMP/ui.log
TEST_COMMANDS=$TMP/package-queries.log
TEST_STATE=$TMP/installed-state
TEST_SEARCHES=$TMP/searches
MENU_STYLE=modern
GUI=false
GUI_TOOL=""
TERM=xterm-256color
stty rows 70 cols 220 </dev/tty
: >"$TEST_EVENTS"
: >"$TEST_UI"
: >"$TEST_COMMANDS"
: >"$TEST_SEARCHES"

log_info() { printf 'INFO %s\n' "$*" >>"$TMP/diagnostic.log"; }
log_step() { printf 'STEP %s\n' "$*" >>"$TMP/diagnostic.log"; }
log_success() { printf 'SUCCESS %s\n' "$*" >>"$TMP/diagnostic.log"; }
log_error() { printf 'ERROR %s\n' "$*" >>"$TMP/diagnostic.log"; }
log_warning() { printf 'WARNING %s\n' "$*" >>"$TMP/diagnostic.log"; }
session_set() { return 0; }
ensure_sudo() { printf 'SUDO\n' >>"$TEST_EVENTS"; return 0; }
diagnose() { printf 'UNEXPECTED_DIAGNOSE %s\n' "$*" >>"$TEST_EVENTS"; return 1; }
report_diagnosis() { return 0; }
apply_fixes() { printf 'UNEXPECTED_FIX\n' >>"$TEST_EVENTS"; return 1; }
curl() { printf 'FORBIDDEN curl %s\n' "$*" >>"$TEST_EVENTS"; return 97; }
sudo() { printf 'FORBIDDEN sudo %s\n' "$*" >>"$TEST_EVENTS"; return 97; }
paru() { printf 'FORBIDDEN paru %s\n' "$*" >>"$TEST_EVENTS"; return 97; }
yay() { printf 'FORBIDDEN yay %s\n' "$*" >>"$TEST_EVENTS"; return 97; }
pamac() { printf 'FORBIDDEN pamac %s\n' "$*" >>"$TEST_EVENTS"; return 97; }
makepkg() { printf 'FORBIDDEN makepkg %s\n' "$*" >>"$TEST_EVENTS"; return 97; }

fake_installed() {
    local wanted=$1 name version
    while IFS='|' read -r name version; do
        [[ $name == "$wanted" ]] && return 0
    done <"$TEST_STATE"
    return 1
}

fake_version() {
    local wanted=$1 name version
    while IFS='|' read -r name version; do
        [[ $name == "$wanted" ]] && { printf '%s\n' "$version"; return 0; }
    done <"$TEST_STATE"
    return 1
}

pacman() {
    local name format item version size found
    printf 'PACMAN' >>"$TEST_COMMANDS"
    printf ' <%s>' "$@" >>"$TEST_COMMANDS"
    printf '\n' >>"$TEST_COMMANDS"
    if [[ $1 == -Qq ]]; then
        if (( $# == 1 )); then
            while IFS='|' read -r name version; do printf '%s\n' "$name"; done <"$TEST_STATE"
            return 0
        fi
        name=${!#}
        if fake_installed "$name"; then
            [[ ! -e $TMP/install-started ]] || printf 'VERIFY %s\n' "$name" >>"$TEST_EVENTS"
            printf '%s\n' "$name"
            return 0
        fi
        [[ ! -e $TMP/install-started ]] || printf 'VERIFY %s\n' "$name" >>"$TEST_EVENTS"
        return 1
    fi
    if [[ $1 == -Q ]]; then
        if (( $# == 1 )); then
            while IFS='|' read -r name version; do printf '%s %s\n' "$name" "$version"; done <"$TEST_STATE"
            return 0
        fi
        name=${!#}
        fake_installed "$name" || return 1
        printf '%s %s\n' "$name" "$(fake_version "$name")"
        return 0
    fi
    if [[ $1 == -Qi ]]; then
        name=${!#}
        fake_installed "$name" || return 1
        printf '%s\n' 'Name            : '"$name" 'Version         : '"$(fake_version "$name")" 'Required By     : None'
        return 0
    fi
    if [[ $1 == -T ]]; then
        shift
        [[ $1 == -- ]] && shift
        for name in "$@"; do
            fake_installed "$name" || printf '%s\n' "$name"
        done
        return 0
    fi
    if [[ $1 == -Si ]]; then
        name=${!#}
        case $name in
            alpha)
                printf '%s\n' \
                    'Repository      : extra' \
                    'Name            : alpha' \
                    'Version         : 1.0-1' \
                    'Description     : Raster photography editor' \
                    'Architecture    : x86_64' \
                    'Licenses        : MIT' \
                    'Depends On      : runtime-alpha' \
                    'Optional Deps   : alpha-cli: CLI' \
                    'Download Size   : 1.50 MiB' \
                    'Installed Size  : 4.00 MiB' \
                    'Packager        : Example Packager <packager@example.invalid>' \
                    'Build Date      : Sun Jan 7 03:04:05 2024'
                return 0 ;;
            coreapp)
                printf '%s\n' \
                    'Repository      : extra' \
                    'Name            : coreapp' \
                    'Version         : 1.0-1' \
                    'Description     : Core photography application' \
                    'Architecture    : x86_64' \
                    'Licenses        : MIT' \
                    'Depends On      : None' \
                    'Optional Deps   : None' \
                    'Download Size   : 1.00 KiB' \
                    'Installed Size  : 4.00 KiB' \
                    'Packager        : Fixture Packager <packager@example.invalid>' \
                    'Build Date      : Sun Jan 7 03:04:05 2024'
                return 0 ;;
            alpha-cli|beta-cli|plugin-cli|runtime-*|meson|ninja|check-*|git)
                printf '%s\n' \
                    'Repository      : extra' \
                    'Name            : '"$name" \
                    'Version         : 1.0-1' \
                    'Description     : Fixture dependency' \
                    'Depends On      : None' \
                    'Optional Deps   : None'
                return 0 ;;
        esac
        printf 'UNEXPECTED_SI %s\n' "$name" >>"$TEST_EVENTS"
        return 1
    fi
    if [[ $1 == -Sp ]]; then
        shift
        format=%n
        while (( $# )); do
            case $1 in
                --print-format) format=$2; shift 2 ;;
                --) shift; break ;;
                *) shift ;;
            esac
        done
        found=false
        for name in "$@"; do
            case $name in
                alpha) version=1.0-1 size=1572864 ;;
                coreapp) version=1.0-1 size=1024 ;;
                alpha-cli|beta-cli|plugin-cli|runtime-*|meson|ninja|check-*|git) version=1.0-1 size=512 ;;
                *) printf 'UNEXPECTED_SP %s\n' "$name" >>"$TEST_EVENTS"; return 1 ;;
            esac
            found=true
            if [[ $format == *'|'* ]]; then
                printf '%s|%s|extra|%s\n' "$name" "$version" "$size"
            else
                printf '%s\n' "$name"
            fi
            if [[ $name == alpha && $format == *'|'* ]]; then
                printf '%s\n' 'runtime-alpha|1.0-1|extra|512'
            fi
        done
        [[ $found == true ]]
        return
    fi
    printf 'UNEXPECTED_PACMAN %s\n' "$*" >>"$TEST_EVENTS"
    return 96
}

pm_search() {
    printf '%s\n' "$1" >>"$TEST_SEARCHES"
    R_KEYS=(
        @apps
        repo:alpha aur:beta aur:gamma aur:alpha-bin aur:alpha-source aur:alpha-git
        repo:coreapp aur:installed
        @plugins aur:alpha-plugin
    )
    R_LABELS=(
        'Applications & tools'
        '📦 alpha 1.0-1 (extra · 👥 12.5% of Arch users — Raster photography editor)'
        '🧩 beta 2.0-1 (AUR · ★ 42 votes · 👥 1.5% of Arch users — Structured writing application)'
        '🧩 gamma 1.0-1 (AUR · ★ 8 votes — Raster photography workflow)'
        '🧩 alpha-bin 2.0-1 (AUR · ★ 30 votes · ↔ variant — Binary photography editor)'
        '🧩 alpha-source 2.0-1 (AUR · ★ 10 votes · ↔ variant — Source photography editor)'
        '🧩 alpha-git 2.r1 (AUR · ★ 100 votes · ↔ variant — Development photography editor)'
        '📦 coreapp 1.0-1 (extra — Core photography application)'
        '🧩 installed 1.0-1 (✔ installed · AUR — Already installed fixture)'
        '🔌 Plugins & add-ons'
        '🧩 alpha-plugin 1.0-1 (AUR · 🔌 needs coreapp — Photography plugin for coreapp)'
    )
    cp -- "$TEST_FIXTURE_META" "$TMP/search_meta"
}

aur_json() {
    local url=$1 mode=$2 name
    name=${url##*arg%5B%5D=}
    case $name in
        beta)
            printf '%s\n' \
                'Name=beta' 'Version=2.0-1' 'Description=Structured writing application' \
                'Maintainer=Beta Maintainer' 'NumVotes=42' 'Popularity=3.25' \
                'LastModified=1700000000' 'FirstSubmitted=1600000000' 'OutOfDate=' \
                'Depends=runtime-beta' 'MakeDepends=meson' 'CheckDepends=check-beta' \
                'OptDepends=beta-cli: CLI tools' 'License=GPL-3.0-only' ;;
        gamma)
            printf '%s\n' \
                'Name=gamma' 'Version=1.0-1' 'Description=Raster photography workflow' \
                'Maintainer=Fixture Maintainer' 'NumVotes=8' 'Popularity=0.8' \
                'LastModified=1700000000' 'FirstSubmitted=1600000000' 'OutOfDate=' \
                'Depends=' 'MakeDepends=' 'CheckDepends=' 'OptDepends=' 'License=MIT' ;;
        alpha-plugin)
            printf '%s\n' \
                'Name=alpha-plugin' 'Version=1.0-1' 'Description=Photography plugin for coreapp' \
                'Maintainer=Fixture Maintainer' 'NumVotes=10' 'Popularity=1.0' \
                'LastModified=1700000000' 'FirstSubmitted=1600000000' 'OutOfDate=' \
                $'Depends=coreapp\truntime-plugin' 'MakeDepends=ninja' 'CheckDepends=check-plugin' \
                'OptDepends=plugin-cli: Plugin tools' 'License=MIT' ;;
        *) printf 'UNEXPECTED_AUR %s\n' "$url" >>"$TEST_EVENTS"; return 1 ;;
    esac
}

pm_choose_installer() {
    printf 'INSTALLER %s\n' "$1" >>"$TEST_EVENTS"
    PM_TOOL=paru
    return 0
}

pm_run_logged() {
    local log=$1
    shift
    printf 'EXEC' >>"$TEST_EVENTS"
    printf ' <%s>' "$@" >>"$TEST_EVENTS"
    printf '\n' >>"$TEST_EVENTS"
    [[ $1 == /* ]] && printf '%s\n' "$log" >"$TMP/unexpected-log-command"
    : >"$TMP/install-started"
    case " $* " in
        *' sudo pacman -S '*)
            printf '%s\n' 'alpha|1.0-1' 'coreapp|1.0-1' >>"$TEST_STATE"
            return 0 ;;
        *' paru -S '*)
            printf '%s\n' 'alpha-plugin|1.0-1' 'beta|2.0-1' >>"$TEST_STATE"
            return 0 ;;
        *) printf 'UNEXPECTED_EXEC %s\n' "$*" >>"$TEST_EVENTS"; return 95 ;;
    esac
}

eval "$(declare -f ui_dialog | sed '1s/ui_dialog/ui_dialog_real/')"
ui_dialog() {
    local title=$1 rc
    {
        printf '\n<<<DIALOG %s>>>\n' "$1"
        printf '%s\n' "$2"
        printf 'BUTTONS'
        ( shift 4; printf ' <%s>' "$@" )
        printf '\n'
    } >>"$TEST_UI"
    printf 'DIALOG <%s>\n' "$title" >>"$TEST_EVENTS"
    ui_dialog_real "$@"
    rc=$?
    if [[ $title == Install\ * && $TUI_CHOICE == 0 ]]; then
        printf 'CONFIRM <%s>\n' "$title" >>"$TEST_EVENTS"
    fi
    return "$rc"
}

eval "$(declare -f ui_choose | sed '1s/ui_choose/ui_choose_real/')"
ui_choose() {
    {
        printf '\n<<<CHOOSE %s>>>\n' "$1"
        printf '%s\n' "$2"
        printf 'OPTIONS'
        ( shift 2; printf ' <%s>' "$@" )
        printf '\n'
    } >>"$TEST_UI"
    printf 'CHOOSE <%s>\n' "$1" >>"$TEST_EVENTS"
    ui_choose_real "$@"
}

eval "$(declare -f ui_multiselect | sed '1s/ui_multiselect/ui_multiselect_real/')"
ui_multiselect() {
    local marks
    marks=$(printf '%s\n' "${!PM_MARKED[@]}" | sed '/^$/d' | sort | paste -sd, -)
    printf 'MENU <%s> MARKED <%s>\n' "$1" "$marks" >>"$TEST_EVENTS"
    ui_multiselect_real "$@"
}

eval "$(declare -f pm_execute_install_plan | sed '1s/pm_execute_install_plan/pm_execute_install_plan_real/')"
pm_execute_install_plan() {
    local rc
    pm_execute_install_plan_real "$@"
    rc=$?
    {
        printf 'success=%s\n' "$PM_INSTALL_SUCCESS"
        printf 'missing=%s\n' "${PM_VERIFY_MISSING[*]}"
    } >>"$TMP/execution-outcomes"
    return "$rc"
}

action_install
rc=$?
printf '%s\n' "$rc" >"$TMP/action-rc"
printf '%s\n' "${!PM_MARKED[@]}" | sed '/^$/d' | sort >"$TMP/final-marked"
printf '%s\n' "${R_KEYS[@]}" >"$TMP/final-result-keys"
exit "$rc"
'''


class PTYSession:
    def __init__(self, script, runtime, fixture_meta):
        self.output = bytearray()
        self.pending = bytearray()
        self.status = None
        env = os.environ.copy()
        env.update({
            "HOME": str(runtime / "home"),
            "TERM": "xterm-256color",
            "LC_ALL": "C.UTF-8",
        })
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe("bash", ["bash", str(script), str(runtime), str(fixture_meta)], env)

    def poll(self):
        if self.status is None:
            done, status = os.waitpid(self.pid, os.WNOHANG)
            if done == self.pid:
                self.status = status
        return self.status

    def read_available(self, duration=0.2):
        output = b""
        deadline = time.monotonic() + duration
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if not ready:
                break
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            self.output.extend(chunk)
            self.pending.extend(chunk)
            deadline = time.monotonic() + 0.08
        return output

    def take_pending(self):
        output = bytes(self.pending)
        self.pending.clear()
        return output

    def expect(self, needle, timeout=15, context=""):
        text_mode = isinstance(needle, str)
        raw_needle = needle.encode() if text_mode else needle
        received = self.take_pending()
        found = needle in clean_terminal(received) if text_mode else raw_needle in received
        deadline = time.monotonic() + timeout
        while not found and time.monotonic() < deadline:
            self.read_available(0.2)
            received += self.take_pending()
            found = needle in clean_terminal(received) if text_mode else raw_needle in received
            if self.poll() is not None and not found:
                self.read_available(0.1)
                received += self.take_pending()
                found = needle in clean_terminal(received) if text_mode else raw_needle in received
                break
        if not found:
            message = "PTY did not render %r" % needle
            if context:
                message += ": " + context
            if self.status is not None:
                message += "; child status=%r" % self.status
            raise AssertionError(message)
        return received

    def send(self, data, pause=0.12):
        if isinstance(data, str):
            data = data.encode()
        os.write(self.fd, data)
        time.sleep(pause)
        return self.read_available(0.08)

    def wait_exit(self, timeout=10):
        deadline = time.monotonic() + timeout
        while self.poll() is None and time.monotonic() < deadline:
            self.read_available(0.1)
        self.read_available(0.1)
        if self.status is None:
            raise AssertionError("PTY scenario did not exit")
        if not os.WIFEXITED(self.status) or os.WEXITSTATUS(self.status) != 0:
            raise AssertionError("PTY scenario failed with status %r" % self.status)

    def close(self):
        if self.status is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def read(path):
    return Path(path).read_text(encoding="utf-8") if Path(path).exists() else ""


def scenario():
    records, now, build = fixture_records()
    lib = load_library()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        runtime = root / "runtime"
        cache = runtime / "package-details"
        home = runtime / "home"
        cache.mkdir(parents=True)
        home.mkdir()
        for key, record in records.items():
            path = cache / (urllib.parse.quote(key, safe="") + ".json")
            path.write_text(json.dumps(record), encoding="utf-8")
        fixture_meta = root / "search-meta.fixture"
        original_meta = search_metadata(records)
        fixture_meta.write_text(original_meta, encoding="utf-8")
        (runtime / "installed-state").write_text("installed|0.9-1\n", encoding="utf-8")
        script = root / "scenario.sh"
        source = SCRIPT.read_text(encoding="utf-8")
        trailer = 'main "$@"\n'
        require(source.endswith(trailer), "smart-update.sh entry point changed")
        script.write_text(source[:-len(trailer)] + HARNESS, encoding="utf-8")
        session = PTYSession(script, runtime, fixture_meta)
        try:
            try:
                session.expect("Install software")
                session.send("fixture\r")
                initial = session.expect("Results for 'fixture'")
                require(b"alpha 1.0-1" in initial, "search results did not include alpha")
                session.send(" ")
                session.expect("[✓]")
                session.send(" ")
                session.expect("Raster photography workflow")
                session.send(END)
                session.send(UP)
                installed = session.expect("installed version 0.9-1")
                require(b"[installed]" in installed, "installed row lacks its literal marker")
                require(
                    b"\x1b[38;5;114m[installed]" in installed,
                    "installed row lacks the exact modern T_OK color",
                )

                session.send(HOME)
                session.expect("Results for 'fixture'")
                session.send("\r")
                official_details = session.expect("Votes: Not used for official packages")
                official_text = clean_terminal(official_details)
                for expected in (
                    "Package: alpha 1.0-1",
                    "Repository: extra",
                    "Architecture: x86_64",
                    "Package size: 1.5 MiB",
                    "Installed size: 4.0 MiB",
                    "Licenses: MIT",
                    "Maintainer / packager: Example Packager <packager@example.invalid>",
                    "First release: Not tracked by pacman",
                    "Latest update: Package build date — " + lib["format_date"](build),
                    "Runtime requirements: runtime-alpha",
                    "Build requirements: Not tracked by pacman",
                    "Check requirements: Not tracked by pacman",
                    "Optional requirements: alpha-cli: CLI",
                    "Votes: Not used for official packages",
                ):
                    require(expected in official_text, "official Details omitted %r" % expected)
                session.send(ESC)
                session.expect("Results for 'fixture'")

                session.send(DOWN)
                session.send("\r")
                aur_details = session.expect("Votes: 42")
                aur_text = clean_terminal(aur_details)
                for expected in (
                    "Package: beta 2.0-1",
                    "Repository: AUR",
                    "Architecture: x86_64, aarch64",
                    "Package size: Not published by AUR",
                    "Installed size: Unknown until built",
                    "Licenses: GPL-3.0-only",
                    "Maintainer / packager: Beta Maintainer",
                    "First release: First submitted to AUR — " + lib["format_date"](records["aur:beta"]["first_submitted"]),
                    "Latest update: AUR recipe update — " + lib["format_date"](records["aur:beta"]["updated"]),
                    "Runtime requirements: runtime-beta",
                    "Build requirements: meson",
                    "Check requirements: check-beta",
                    "Optional requirements: beta-cli: CLI tools",
                    "Votes: 42",
                ):
                    require(expected in aur_text, "AUR Details omitted %r" % expected)
                session.send(ESC)
                session.expect("Results for 'fixture'")

                session.send(HOME)
                session.expect("Results for 'fixture'")
                session.send("c")
                comparison = session.expect("Recommended (advisory): aur:alpha-bin")
                comparison_text = clean_terminal(comparison)
                require("Recommended (advisory): aur:alpha-bin" in comparison_text, "advisory recommendation was not rendered")
                session.send(DOWN)
                session.send("\r")
                reviewed = session.expect("Identity evidence:")
                reviewed_text = clean_terminal(reviewed)
                for expected in (
                    "Variant kind: binary repackaging (inferred from -bin)",
                    "AUR votes: 30",
                    "AUR popularity: 2.0",
                    "pkgstats popularity: 1.25",
                    "Recommendation: aur:alpha-bin",
                    "Only Use this variant changes marks",
                ):
                    require(expected in reviewed_text, "advisory variant review omitted %r" % expected)
                session.send(ESC)
                session.expect("Results for 'fixture'")

                session.send(HOME)
                session.expect("Results for 'fixture'")
                session.send("\r")
                session.expect("Package: alpha 1.0-1")
                session.send("\r")
                similar = session.expect("Shared keyword: photography")
                require(b"gamma" in similar, "Similar apps omitted the evidence-backed gamma row")
                session.send(ESC)
                session.expect("Results for 'fixture'")

                session.send(END)
                session.expect("alpha-plugin")
                session.send(" ")
                session.expect("[✓]")
                session.send("i")
                preview = session.expect("Install 4 marked packages")
                preview_text = clean_terminal(preview)
                require("Auto-added core applications:" in preview_text, "missing core was not announced")
                require("repo:coreapp (required core)" in preview_text, "missing core was not auto-added")
                require("Required core application coreapp was added" in preview_text, "core addition notice is missing")
                for _ in range(5):
                    preview += session.send(PGDN, pause=0.08)
                session.send("\r")
                session.expect("Remove the build-only packages")
                session.send("n")
                session.expect("Every requested package was verified with pacman -Qq.")
                session.send("\r")

                refreshed = session.expect(
                    "Results for 'fixture'",
                    context=(
                        "post-install result reuse is missing: action_install exited instead of "
                        "returning to the original results for another selection"
                    ),
                )
                session.send(HOME)
                refreshed += session.expect("Results for 'fixture'")
                refreshed += session.send(END)
                refreshed_text = clean_terminal(refreshed)
                for name, version in (
                    ("alpha", "1.0-1"),
                    ("beta", "2.0-1"),
                    ("coreapp", "1.0-1"),
                    ("alpha-plugin", "1.0-1"),
                ):
                    pattern = re.compile(
                        r"\[installed\].*?\b" + re.escape(name) + r"\s+[^\n]*?"
                        + r"installed version " + re.escape(version)
                    )
                    require(pattern.search(refreshed_text), "refreshed installed label missing for " + name)
                require_refreshed_installed_colors(refreshed)
                color_stripped = refreshed.replace(b"\x1b[38;5;114m", b"")
                try:
                    require_refreshed_installed_colors(color_stripped)
                except AssertionError as error:
                    negative_control_message = str(error)
                    require(
                        negative_control_message == "refreshed installed T_OK row missing for alpha",
                        "color negative control failed for an unexpected reason: " + negative_control_message,
                    )
                else:
                    raise AssertionError("color-stripped negative control unexpectedly passed")

                session.send(HOME)
                session.expect("Results for 'fixture'")
                session.send(DOWN)
                session.send(DOWN)
                session.send(" ")
                session.expect("[✓]")
                session.send("i")
                second_preview = session.expect("Install gamma")
                require("Selected applications:" in clean_terminal(second_preview), "second selection has no aggregated preview")
                session.send(ESC)
                session.wait_exit()
            except Exception as error:
                events = read(runtime / "events")
                ui = read(runtime / "ui.log")
                terminal = clean_terminal(session.output)
                raise AssertionError(
                    "%s\n--- event log ---\n%s\n--- UI log tail ---\n%s\n--- captured terminal tail ---\n%s"
                    % (error, events, ui[-8000:], terminal[-16000:])
                ) from None
        finally:
            session.close()

        events = read(runtime / "events")
        ui = read(runtime / "ui.log")
        queries = read(runtime / "package-queries.log")
        searches = read(runtime / "searches").splitlines()
        outcomes = read(runtime / "execution-outcomes")
        terminal = clean_terminal(session.output)
        final_marked = read(runtime / "final-marked").splitlines()

        require(read(runtime / "action-rc").strip() == "0", "action_install returned nonzero")
        require(searches == ["fixture"], "result reuse triggered a new search: %r" % searches)
        require(read(runtime / "search_meta") == original_meta, "original search metadata cache was discarded")
        for key in records:
            cached = cache / (urllib.parse.quote(key, safe="") + ".json")
            require(cached.exists(), "metadata cache was discarded for " + key)
        require("FORBIDDEN" not in events, "a real network/package boundary was reached")
        require("UNEXPECTED" not in events, "unexpected external call: " + events)
        require("UNEXPECTED" not in queries, "unexpected pacman query: " + queries)
        require("Traceback" not in terminal, "terminal contains a Python traceback")
        require("{\"name\"" not in terminal and '\"selection-records\"' not in terminal, "terminal contains raw JSON")
        require("No reliable similar applications found" not in terminal, "reliable similar evidence became an empty recommendation")

        confirm = [line for line in events.splitlines() if line.startswith("CONFIRM ")]
        require(confirm == ["CONFIRM <Install 4 marked packages>"], "wrong aggregated confirmations: %r" % confirm)
        exec_lines = [line for line in events.splitlines() if line.startswith("EXEC ")]
        require(len(exec_lines) == 2, "wrong package transaction count: %r" % exec_lines)
        first_confirm = events.index(confirm[0])
        require(all(events.index(line) > first_confirm for line in exec_lines), "package command ran before aggregated confirmation")
        require("<sudo> <pacman>" in exec_lines[0], "official command was not first")
        require("<paru>" in exec_lines[1], "AUR command did not follow official command")
        require("<alpha> <coreapp>" in exec_lines[0], "official command omitted requested packages")
        require("<alpha-plugin> <beta>" in exec_lines[1], "AUR command omitted requested packages")
        for build_only in ("meson", "check-beta", "ninja", "check-plugin"):
            require(all("<%s>" % build_only not in line for line in exec_lines), "build-only dependency became a requested app")
        for unrequested in ("alpha-bin", "alpha-source", "alpha-git", "gamma"):
            require(all("<%s>" % unrequested not in line for line in exec_lines), "recommendation/suggestion auto-installed " + unrequested)
        require("--noconfirm" not in events, "package confirmation flags were disabled")
        require("--removemake" not in events, "declining build cleanup was not honored")
        for name in ("alpha", "beta", "coreapp", "alpha-plugin"):
            require("VERIFY " + name in events, "requested package was not verified: " + name)
        require("success=true" in outcomes, "real execution did not report success")
        require("missing=\n" in outcomes, "verified packages were reported missing")

        require("Selected applications:" in ui, "aggregated preview omitted selected applications")
        require("WILL BE INSTALLED — deduplicated dependency preview" in ui, "aggregated dependency preview is missing")
        require("ONLY NEEDED TO BUILD (not selected applications):" in ui, "build-only preview section is missing")
        require("Known download total:" in terminal, "aggregated preview was not inspected through its total")
        for key in ("repo:alpha", "aur:beta", "aur:alpha-plugin", "repo:coreapp"):
            require(key in ui, "aggregated preview omitted " + key)
        for candidate, kind in (
            ("aur:alpha-bin", "binary repackaging (inferred from -bin)"),
            ("aur:alpha-source", "source/other — verify PKGBUILD"),
            ("aur:alpha-git", "VCS/development (inferred from -git)"),
        ):
            require("Candidate: " + candidate in ui, "comparison omitted " + candidate)
            require(kind in ui, "comparison omitted variant kind " + kind)
        require("AUR popularity: 2.0" in ui, "comparison omitted AUR popularity")
        require("Shared keyword: photography" in terminal, "Similar apps omitted its evidence")

        result_menu_positions = [
            match.start() for match in re.finditer(r"MENU <Results for 'fixture'>", events)
        ]
        require(len(result_menu_positions) >= 2, "original results were not reused")
        post_success = events[result_menu_positions[-1]:]
        require("MARKED <>" in post_success.splitlines()[0], "completed marks were not cleared")
        second = ui.rsplit("<<<DIALOG Install gamma>>>", 1)[-1]
        require("• aur:gamma" in second, "second preview omitted gamma")
        for old in ("repo:alpha", "aur:beta", "aur:alpha-plugin", "repo:coreapp"):
            require(old not in second, "completed transaction silently repeated " + old)
        require(final_marked == ["aur:gamma"], "cancelling the second preview lost its uncompleted mark")
        return {
            "events": events,
            "ui": ui,
            "queries": queries,
            "outcomes": outcomes,
            "terminal": terminal,
            "color_negative_control": negative_control_message,
        }


def main():
    try:
        scenario()
    except AssertionError as error:
        print("FAIL: " + str(error))
        return 1
    print("PASS: complete real-PTY install flow, result reuse, refreshed labels, and offline command ordering")
    return 0


if __name__ == "__main__":
    sys.exit(main())
