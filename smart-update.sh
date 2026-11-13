#!/usr/bin/env bash
# =====================================================================
#  ARCH SMART UPDATE  v4.0
#  A simple, self-repairing updater for Arch Linux (terminal + desktop)
#  MIT License — https://github.com/mneftekhar/arch-smart-update
#
#  - Diagnoses why an update failed (pacman, keyring, mirrors, locks,
#    disk space, file/package conflicts, broken deps, AUR builds, DKMS,
#    hooks, partial upgrades …), explains the most likely cause, and
#    applies the fix (safe fixes automatically, risky ones on request),
#    then retries.
#  - Graphical download progress (terminal bar + optional zenity/yad
#    dialog) with speed and ETA.
#  - Live counter of data downloaded during this run (packages and
#    total network traffic), shown in every step, in the terminal
#    title and in the final summary.
#  - [d]etails at every fix question: what the fix changes and the
#    exact commands it will run. Ctrl+\ = emergency stop, which is
#    postponed (with a warning) while a step that must not be cut off
#    is running.
#  - Blocked / filtered downloads (regional censorship, ISP DPI,
#    throttling): per-file rescue over in-country mirrors, HTTP/1.1,
#    plain HTTP, DNS-over-HTTPS and local proxies (v2ray/clash/Tor),
#    with resume across mirrors. If a file still can't be fetched, the
#    package is held back for this run only when that is provably safe.
#  - Detailed report of everything that touches the update (locks,
#    timers, hooks, services, running programs, network path, mirrors).
#  - Desktop notifications that expire and replace each other.
#  - System DNS down but DNS-over-HTTPS working: pacman resolves mirror
#    names over HTTPS for the run (temporary pacman.conf only).
#
#  Usage: smart-update.sh --help
# =====================================================================

set -o pipefail
shopt -s nullglob

VERSION="4.0.0"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
PROG="${SELF##*/}"
ORIG_ARGS=("$@")
APP_TITLE="Arch Smart Update"

# ----------------------------------------------------------------------
# DEFAULT CONFIGURATION  (override in ~/.config/arch-update.conf)
# ----------------------------------------------------------------------
LOG_DIR="$HOME/.local/log/arch-updates"
CONFIG_FILE="$HOME/.config/arch-update.conf"
NOTIFY_ENABLED=true
AUR_HELPER="paru"            # preferred helper: paru|yay|pikaur|trizen|pamac
AUR_EXTRA_FLAGS=""           # e.g. "--skipreview" for paru, "--devel" for -git pkgs
DRY_RUN=false
ZFS_ENABLED=false
ZFS_DATASETS="rpool/ROOT rpool/HOME"
ZFS_KEEP_SNAPSHOTS=5
SNAPSHOT_TOOL="none"         # none|zfs|snapper|timeshift
PACCACHE_KEEP=3
JOURNAL_KEEP="2weeks"
MIRROR_UPDATE_DAYS=7
MIRROR_COUNTRY=""            # reflector --country value, e.g. "Germany,France"
FORCE_MIRRORS=false
MAX_ATTEMPTS=4               # attempts per step (first try + retries after fixes)
FIX_MODE="ask"               # ask = confirm each fix | auto = apply safe fixes silently | off = diagnose only
ALLOW_RISKY_AUTO=false       # in auto mode, also apply risky fixes without asking
UI_MODE="auto"               # auto|cli|gui
MIN_FREE_MB=1500             # warn / clean when less free space than this
STALE_DAYS=90                # last full upgrade older than this = long-outdated system (extra preparation)
UPDATE_VIEW="panel"          # panel = fixed status panel + condensed output while updating | classic = raw output
INSTALL_HELPER=""            # last tool chosen in "Install software" (pacman, paru, yay…); offered first next time
AUR_BOOTSTRAP="ask"          # ask = offer to install paru/yay when none is found | never
AUR_BOOTSTRAP_BIN=true       # install prebuilt paru-bin/yay-bin (fast) instead of compiling
MENU_STYLE="auto"            # interactive menu: auto|modern (mouse + keyboard UI) | classic (whiptail/dialog) | plain
EXTRA_MIRRORS=""             # extra Server templates tried first for blocked files, e.g. "https://mirror.example/archlinux/$repo/os/$arch"
SNAP_KEEP_ROUTE=false        # true = keep the working Snap Store route found on a filtered network (snapd's background refreshes use it too)
PROXY_URL=""                 # proxy for blocked downloads, e.g. socks5h://127.0.0.1:10808 (local v2ray/xray/sing-box/clash are found automatically)
MIRROR_COUNTRY_CODE=""       # ISO code used for in-country mirrors; empty = guess from the time zone
RESCUE_MAX_MIN=20            # minutes spent per blocked package before giving up
REPORT_MODE="auto"           # auto = detailed report after every run (network probes only when downloads failed) | deep | off
NOTIFY_TIMEOUT=8             # seconds a desktop notification stays visible
RESCUE_DIR="$HOME/.cache/smart-update/partial"
STATE_DIR="$HOME/.local/state/smart-update"
AI_SUGGEST_CMD=""            # optional, e.g. "claude -p": asked for a suggestion on unknown errors (never executed)
DO_OFFICIAL=true
DO_AUR=true
DO_FLATPAK=true
DO_SNAP=true
DO_FIRMWARE=true
DO_CLEANUP=true
DO_HEALTH=true

# shellcheck source=/dev/null
[[ -f $CONFIG_FILE ]] && source "$CONFIG_FILE"
[[ $ZFS_ENABLED == true && $SNAPSHOT_TOOL == none ]] && SNAPSHOT_TOOL="zfs"

# ----------------------------------------------------------------------
# RUNTIME STATE
# ----------------------------------------------------------------------
TMP=""
LOG_FILE=""
GUI=false
GUI_TOOL=""
HELPER="none"
CACHE_DIRS=()
CACHE_DIR="/var/cache/pacman/pkg"
DB_PATH="/var/lib/pacman"
DISTRO_ID=""
RUN_START=$(date +%s)
BASE_NET=0
PKG_DOWNLOADED_BYTES=0
PLOG_START=0
SUDO_PID=""
TICKER_PID=""
PROG_FD=""
PULSE_PID=""
INTERACTIVE_NEXT=0
ATTEMPT_LOG=""
CLEAN_LOG=""
DIAG_DOMAIN="pacman"
TOP_PID=$$
STTY_ORIG=""
KEYGUARD=false
CRIT_KIND=""
RUN_EPOCH=$(date +%s)
declare -a P_CMDS=()
P_UNDO=""
declare -a ISSUES=() FIXES_APPLIED=() UNRESOLVED=() ISSUES_SEEN=() NEWS_TITLES=() REINSTALL_AFTER=() KEYRINGS_TO_UPDATE=()
declare -A FIX_COUNT=()
PAC_OPTS=()                  # extra pacman options for this run (temporary config, slow-network mode)
HOLD_PKGS=()                 # packages held back for this run only (blocked downloads, proven safe)
PAC_DOH=""                   # DNS-over-HTTPS resolver pacman uses this run (system DNS down, DoH works)
DNS_DEAD=false
SKIPPED_DNS=()
BLOCKED_FINAL=()             # packages that could not be downloaded by any route
PAC_PROXY=""                 # proxy that pacman's downloads go through this run (found by the rescue)
RESCUE_PROXY=""
REPORT_FILE=""
REPORT_ONLY=false
SETUP_REQUESTED=""
NOTIFY_ID=""
SLOW_LEVEL=0                 # 0 normal | 1 fewer parallel downloads, no timeout | 2 curl with retries + HTTP/1.1
declare -a SKIP_REPOS=() AUR_IGNORE=()
declare -a UNIGNORE_PKGS=()  # IgnorePkg entries this run upgrades anyway (fix IGNORED_PKG, asked first)
declare -a REBUILD_LIST=()   # "pkg|reason" of AUR packages a library/Python/Perl update broke
MAKEPKG_FORCE=""             # rebuild even when the same version is installed (broken AUR helper)
PACMAN_STATIC_URL="https://pkgbuild.com/~morganamilo/pacman-static/x86_64/bin/pacman-static"
DOWNLOAD_ONLY=false
FIX_YES_ALL=0
MENU_REQUESTED=""
BOOT_PKG=""

# ----------------------------------------------------------------------
# COLOURS
# ----------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[1;33m' BLUE=$'\033[1;34m'
    PURPLE=$'\033[0;35m' CYAN=$'\033[0;36m' GRAY=$'\033[0;90m' BOLD=$'\033[1m' NC=$'\033[0m'
else
    RED="" GREEN="" YELLOW="" BLUE="" PURPLE="" CYAN="" GRAY="" BOLD="" NC=""
fi

# ======================================================================
# SMALL HELPERS
# ======================================================================
have() { command -v "$1" >/dev/null 2>&1; }

human() {  # bytes -> human readable
    awk -v b="${1:-0}" 'BEGIN{ split("B KiB MiB GiB TiB",u); i=1;
        if (b<0) b=0; while (b>=1024 && i<5) { b/=1024; i++ }
        if (i==1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i] }'
}

fmt_secs() {
    local s=${1:-0}
    if (( s >= 3600 )); then printf '%d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60))
    else printf '%02d:%02d' $((s/60)) $((s%60)); fi
}

now_ms() { local t=${EPOCHREALTIME//[.,]/}; echo $(( t / 1000 )); }

repeat_char() { local out="" i; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }

strip_ansi() { sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g; s/\r$//; s/.*\r//'; }

free_mb() { df -Pm "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

gui_escape() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g' <<<"$1"; }

xml_unescape() { sed "s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/\"/g; s/&#39;/'/g" <<<"$1"; }

urlencode() { local s=$1 out="" c i; for ((i = 0; i < ${#s}; i++)); do c=${s:i:1}
    case $c in [a-zA-Z0-9.~_-]) out+=$c ;; ' ') out+='+' ;; *) out+=$(printf '%%%02X' "'$c") ;; esac; done; printf '%s' "$out"; }

# ----------------------------------------------------------------------
# DATA-USAGE ACCOUNTING
# ----------------------------------------------------------------------
net_rx_total() {
    # Sum received bytes on physical interfaces only (avoids double counting VPN/bridges).
    local sum=0 any=0 f ifc
    for f in /sys/class/net/*/statistics/rx_bytes; do
        ifc=${f#/sys/class/net/}; ifc=${ifc%%/*}
        [[ $ifc == lo ]] && continue
        [[ -e /sys/class/net/$ifc/device ]] || continue
        sum=$(( sum + $(<"$f") )); any=1
    done
    if (( ! any )); then
        for f in /sys/class/net/*/statistics/rx_bytes; do
            ifc=${f#/sys/class/net/}; ifc=${ifc%%/*}
            [[ $ifc == lo ]] && continue
            sum=$(( sum + $(<"$f") ))
        done
    fi
    echo "$sum"
}

net_used() { local n; n=$(( $(net_rx_total) - BASE_NET )); (( n < 0 )) && n=0; echo "$n"; }

cache_bytes() {
    local s
    s=$(sudo -n du -sb "${CACHE_DIRS[@]}" 2>/dev/null | awk '{t+=$1} END{print t+0}')
    [[ -z $s || $s == 0 ]] && s=$(du -sb "${CACHE_DIRS[@]}" 2>/dev/null | awk '{t+=$1} END{print t+0}')
    echo "${s:-0}"
}

data_badge() { printf '📶 %s this run' "$(human "$(net_used)")"; }

# ======================================================================
# LOGGING & NOTIFICATIONS
# ======================================================================
_log() { [[ -n $LOG_FILE ]] && printf '%s\n' "$*" | strip_ansi >>"$LOG_FILE"; }

notify() {  # transient notifications that replace each other and always disappear
    local title=$1 message=$2 urgency=${3:-normal} id args=()
    _log "[NOTIFY] $title: $message"
    [[ $NOTIFY_ENABLED == true ]] || return 0
    # KDE Plasma and others never expire "critical" notifications and keep every one in the history
    # panel; use normal/low urgency, an explicit timeout, the transient hint, and replace the last one.
    [[ $urgency == critical ]] && urgency=normal
    if have notify-send; then
        args=(-a "$APP_TITLE" -u "$urgency" -t $(( NOTIFY_TIMEOUT * 1000 )) -i system-software-update
              -h boolean:transient:true -h string:x-canonical-private-synchronous:arch-smart-update)
        [[ -n ${NOTIFY_ID:-} ]] && args+=(-r "$NOTIFY_ID")
        id=$(notify-send -p "${args[@]}" "Arch Update: $title" "$message" 2>/dev/null) \
            || { notify-send "${args[@]}" "Arch Update: $title" "$message" 2>/dev/null; id=""; }
        [[ $id =~ ^[0-9]+$ ]] && NOTIFY_ID=$id
    fi
    # some servers ignore the timeout: close it ourselves when the time is up
    if [[ -n ${NOTIFY_ID:-} && -n $TMP ]] && have gdbus; then
        local seq; seq=$(( $(cat "$TMP/notify_seq" 2>/dev/null || echo 0) + 1 )); echo "$seq" >"$TMP/notify_seq"
        ( trap '' INT QUIT HUP; sleep "$NOTIFY_TIMEOUT"
          [[ $(cat "$TMP/notify_seq" 2>/dev/null) == "$seq" ]] || exit 0   # a newer notification replaced this one
          gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
              --method org.freedesktop.Notifications.CloseNotification "$NOTIFY_ID" >/dev/null 2>&1 ) &
    fi
    return 0
}

log_step() {
    [[ -n $TMP ]] && printf '%s' "$1" >"$TMP/step"
    printf '\n%s[🚀 %s]%s %s%s%s  %s%s%s\n' "$BLUE" "$(date '+%H:%M:%S')" "$NC" "$CYAN" "$1" "$NC" "$GRAY" "$(data_badge)" "$NC"
    _log "[$(date '+%F %T')] STEP: $1  ($(data_badge))"
    [[ -n $TMP ]] && : >"$TMP/substep"
    state_write; panel_draw
}
log_success() { printf '%s[✅]%s %s\n' "$GREEN" "$NC" "$1"; _log "[SUCCESS] $1"; }
log_warning() { printf '%s[⚠️ ]%s %s\n' "$YELLOW" "$NC" "$1"; _log "[WARNING] $1"; }
log_error()   { printf '%s[❌]%s %s\n' "$RED" "$NC" "$1"; _log "[ERROR] $1"; }
log_info()    { printf '%s[ℹ️ ]%s %s\n' "$GRAY" "$NC" "$1"; _log "[INFO] $1"; }
log_fix()     { printf '%s[🔧]%s %s\n' "$PURPLE" "$NC" "$1"; _log "[FIX] $1"; }

# ======================================================================
# EMERGENCY STOP (Ctrl+\) AND PROTECTED STEPS
# ======================================================================
# Ctrl+\  = emergency stop: ends the whole script from anywhere (menu, questions, any step).
# Ctrl+C  = cancel the current action (back to the menu, or end the run).
# Steps that must never be cut off half-way (pacman installing/removing, keyring install,
# mkinitcpio, locale-gen) run "protected": the terminal stops turning these keys into signals,
# a watcher reads them instead, explains why stopping now is unsafe, and performs the stop
# automatically the moment the protected step has finished.
STOP_KEY_LABEL='Ctrl+\'

critical_reason() {  # "what is happening|what an interruption would cause"
    case $1 in
        install)   echo "pacman is installing/upgrading packages.|Half-written libraries and a mix of old and new packages (a partial upgrade): programs can crash, the desktop may not start, and if the kernel, systemd or glibc is being replaced the PC may not boot." ;;
        keyring)   echo "the package-signing keyring is being written.|A half-written keyring makes every later update stop with signature/trust errors until it is rebuilt by hand." ;;
        remove)    echo "pacman is removing packages.|Packages left half-removed and the package database out of step with the files on disk." ;;
        aur)       echo "the AUR helper is installing packages with pacman.|Those packages left half-installed, with missing or mismatched files." ;;
        initramfs) echo "boot images (initramfs) are being written to /boot.|A broken boot image: the PC may not boot until it is repaired from a live USB." ;;
        locale)    echo "language files (locales) are being generated.|A broken locale archive: programs print locale errors or refuse to start." ;;
        *)         echo "a system change is in progress.|An inconsistent system state." ;;
    esac
}

proc_descendants() {  # every descendant PID of $1
    ps -e -o pid=,ppid= 2>/dev/null | awk -v root="$1" '
        { kids[$2] = kids[$2] " " $1 }
        END { n = split(kids[root], q, " "); i = 1
              while (i <= n) { p = q[i++]; print p; m = split(kids[p], c, " "); for (j = 1; j <= m; j++) q[++n] = c[j] } }'
}

ancestor_chain() {  # ancestor_chain PID — PIDs above PID (not PID itself) up to the script's main process
    local p=$1 out=""
    while [[ $p != "$TOP_PID" && $p -gt 1 ]]; do
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null) || break
        [[ -n $p ]] || break
        out+="$p "
    done
    echo "$out"
}

installer_running() {  # is something below us changing installed packages right now? sets CRIT_KIND
    local p c args
    for p in $(proc_descendants "$TOP_PID"); do
        c=$(cat "/proc/$p/comm" 2>/dev/null) || continue
        case $c in
            mkinitcpio|dracut|booster) CRIT_KIND="initramfs"; return 0 ;;
            locale-gen|localedef)      CRIT_KIND="locale"; return 0 ;;
            pacman)
                args=" $(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) "
                if [[ $args =~ \ -(U|R)[a-zA-Z]*\  || $args == *" --upgrade "* || $args == *" --remove "* ]] ||
                   { [[ $args =~ \ -S[a-zA-Z]*\  ]] && ! [[ $args =~ \ -S[a-zA-Z]*[sipwgc][a-zA-Z]*\  ]]; }; then
                    CRIT_KIND=aur; return 0
                fi ;;
        esac
    done
    return 1
}

critical_now() {  # critical_now MODE -> 0 if stopping now would be unsafe (CRIT_KIND says why)
    case ${1:-safe} in
        safe) return 1 ;;
        auto) installer_running ;;
        *)    CRIT_KIND=$1; return 0 ;;
    esac
}

keys_begin() {  # capture Ctrl+C / Ctrl+\ as keys instead of signals
    [[ -n $STTY_ORIG && $KEYGUARD != true ]] || return 1
    stty -isig -icanon -echo min 0 time 2 </dev/tty 2>/dev/null || return 1
    KEYGUARD=true
}

keys_end() { [[ $KEYGUARD == true ]] || return 0; stty "$STTY_ORIG" </dev/tty 2>/dev/null; KEYGUARD=false; }

show_stop_refused() {  # show_stop_refused KIND REQUEST
    local r what why
    r=$(critical_reason "$1"); what=${r%%|*}; why=${r#*|}
    if [[ -s $TMP/stop_pending ]]; then
        printf '\r\n%s[⏳] Stop already queued: waiting until %s%s\r\n' "$YELLOW" "${what%.}" "$NC" >/dev/tty
        return
    fi
    echo "$2" >"$TMP/stop_pending"
    _log "[STOP] $2 requested during a protected step ($1) — postponed"
    {
        printf '\r\n%s╔═ ⚠️  STOP POSTPONED: stopping right now would make your system unstable%s\r\n' "$BOLD$YELLOW" "$NC"
        printf '%s║%s Right now %s\r\n' "$YELLOW" "$NC" "$what"
        fold -s -w 74 <<<"If it were cut off now: $why" | sed "s/^/${YELLOW}║${NC} /; s/\$/\r/"
        printf '%s║%s %sThe script will stop by itself as soon as this step has finished.%s\r\n' "$YELLOW" "$NC" "$BOLD" "$NC"
        printf '%s║%s Until then, do not close this window, log out or power off.\r\n' "$YELLOW" "$NC"
        printf '%s╚══%s\r\n' "$YELLOW" "$NC"
    } >/dev/tty
    notify "Stop postponed" "Waiting for a protected step to finish — stopping now could break the system" critical
}

poll_keys() {  # poll_keys MODE CHILD_PID — waits up to 0.2 s for a key and acts on Ctrl+C / Ctrl+\
    # bash builtins only: while glibc itself is being replaced, starting any program (dd, od, tr…)
    # can fail with "cannot execute: required file not found" (seen in a real 905-package upgrade)
    local k="" req=""
    # no -n, -N, -s or -d: any of them makes bash put the terminal in cbreak mode WITH signals on, which turns
    # Ctrl+\ back into SIGQUIT. The terminal is already -isig -icanon -echo, and on timeout bash keeps the
    # partial input in k.
    IFS= read -r -t 0.2 k </dev/tty 2>/dev/null
    [[ $k == $'\x1c' ]] && req=stop
    [[ -z $req && $k == $'\x03' ]] && req=cancel
    if [[ -n $req ]]; then
        if critical_now "$1"; then show_stop_refused "$CRIT_KIND" "$req"; return 0; fi
        do_stop "$req" "$2"
    elif [[ -s $TMP/stop_pending ]] && ! critical_now "$1"; then
        printf '\r\n%s[✅] The protected part has finished — stopping now as you asked.%s\r\n' "$GREEN" "$NC" >/dev/tty
        do_stop "$(<"$TMP/stop_pending")" "$2"
    fi
    return 0
}

check_pending_stop() {  # a stop was queued during a protected step that has now ended
    [[ -n $TMP && -s $TMP/stop_pending ]] || return 0
    printf '\n%s[✅] The protected step has finished — stopping now as you asked.%s\n' "$GREEN" "$NC" >/dev/tty
    do_stop "$(<"$TMP/stop_pending")" ""
}

kill_tree() {  # TERM a process and everything below it (sudo relays TERM to root children)
    local p pids; pids="$(proc_descendants "$1") $1"
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    sleep 0.5
    for p in $pids; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null; done
    wait "$1" 2>/dev/null
}

release_our_lock() {  # remove a pacman lock left by a step we stopped (never an older, foreign lock)
    local lock="$DB_PATH/db.lck" i
    [[ -e $lock ]] || return 0
    for i in 1 2 3 4 5 6; do pgrep -x pacman >/dev/null || break; sleep 0.5; done
    pgrep -x pacman >/dev/null && return 0
    (( $(stat -c %Y "$lock" 2>/dev/null || echo 0) >= RUN_EPOCH )) || return 0
    sudo -n rm -f "$lock" 2>/dev/null && _log "[STOP] removed the pacman lock left by the stopped step"
}

do_stop() {  # do_stop stop|cancel [CHILD_PID]
    rm -f "$TMP/stop_pending"
    keys_end
    [[ -n ${2:-} ]] && kill_tree "$2"
    release_our_lock
    if [[ $1 == stop ]]; then emergency_stop; else cancel_action; fi
}

cancel_action() {  # what Ctrl+C always did: end this action (the menu catches it), or the run
    local p me=$BASHPID
    printf '\n' >/dev/tty
    # same as a terminal Ctrl+C: SIGINT to the whole script (helper loops ignore it)
    for p in $(proc_descendants "$TOP_PID"); do [[ $p == "$me" ]] || kill -INT "$p" 2>/dev/null; done
    [[ $me == "$TOP_PID" ]] || kill -INT "$TOP_PID" 2>/dev/null
    trap - INT; kill -INT "$BASHPID"
    exit 130
}

emergency_stop() {  # stop everything now (only called when nothing protected is running)
    [[ -n $TMP && -e $TMP/emergency ]] && exit 130
    [[ -n $TMP ]] && : >"$TMP/emergency"
    keys_end; [[ -n $STTY_ORIG ]] && stty "$STTY_ORIG" </dev/tty 2>/dev/null
    local me=$BASHPID chain p
    chain=" $(ancestor_chain "$me") $me "
    for p in $(proc_descendants "$TOP_PID"); do
        [[ $chain == *" $p "* || $(cat "/proc/$p/comm" 2>/dev/null) == tee ]] || kill -TERM "$p" 2>/dev/null   # tee ends by itself
    done
    [[ -n $PROG_FD ]] && { exec {PROG_FD}>&- ; } 2>/dev/null
    release_our_lock
    {
        printf '\n%s╔═ 🛑 EMERGENCY STOP (%s) — everything has been stopped%s\n' "$BOLD$RED" "$STOP_KEY_LABEL" "$NC"
        printf '%s║%s No protected step was running, so packages and boot files are consistent.\n' "$RED" "$NC"
        printf '%s║%s Downloaded packages stay in the cache; the next run continues from there.\n' "$RED" "$NC"
        printf '%s║%s Data downloaded this run: %s   Log: %s\n' "$RED" "$NC" "$(human "$(net_used)")" "${LOG_FILE:-none}"
        (( ${#FIXES_APPLIED[@]} )) && printf '%s║%s Fixes applied before the stop: %s\n' "$RED" "$NC" "$(printf '%s; ' "${FIXES_APPLIED[@]}" | sed 's/; $//')"
        printf '%s╚══%s\n' "$RED" "$NC"
    } 2>/dev/null >/dev/tty
    _log "[STOP] Emergency stop by user"
    for p in $(ancestor_chain "$me"); do [[ $p == "$TOP_PID" ]] || kill -TERM "$p" 2>/dev/null; done
    (( me != TOP_PID )) && kill -TERM "$TOP_PID" 2>/dev/null
    exit 130
}

on_quit_signal() {  # Ctrl+\ outside a protected step arrives as SIGQUIT
    if critical_now auto; then show_stop_refused "$CRIT_KIND" stop; return; fi
    emergency_stop
}

on_term_signal() {
    [[ -n $TMP && -e $TMP/emergency ]] && exit 130
    echo; log_warning "Terminated"; exit 143
}

run_guarded() {  # run_guarded MODE cmd... — MODE: safe | auto | install | keyring | remove | initramfs | locale
    local mode=$1 rc pid rcf
    shift
    if ! keys_begin; then "$@"; rc=$?; check_pending_stop; return "$rc"; fi
    if [[ $mode != safe && $mode != auto ]]; then
        printf '%s[🔒] Protected step: %s waits until it has finished%s\n' "$GRAY" "$STOP_KEY_LABEL" "$NC" >/dev/tty
    fi
    rcf="$TMP/guard.$BASHPID.$RANDOM"
    ( "$@" </dev/null; echo $? >"$rcf" ) &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do poll_keys "$mode" "$pid"; done
    wait "$pid" 2>/dev/null
    keys_end
    rc=""; [[ -s $rcf ]] && rc=$(<"$rcf"); rm -f "$rcf"
    check_pending_stop
    return "${rc:-1}"
}

# ======================================================================
# UI LAYER (CLI + GUI)
# ======================================================================
detect_gui_tool() {
    local t
    for t in zenity yad kdialog; do have "$t" && { GUI_TOOL=$t; return 0; }; done
    return 1
}

ui_ask() {  # ui_ask "question" [y|n]  -> 0 = yes
    local q=$1 def=${2:-y} ans prompt
    if [[ $GUI == true ]]; then
        case $GUI_TOOL in
            zenity)  zenity --question --title="$APP_TITLE" --width=520 --text="$(gui_escape "$q")" 2>/dev/null; return ;;
            yad)     yad --title="$APP_TITLE" --width=520 --image=dialog-question --text="$(gui_escape "$q")" \
                         --button=No:1 --button=Yes:0 2>/dev/null; return ;;
            kdialog) kdialog --title "$APP_TITLE" --yesno "$q" 2>/dev/null; return ;;
        esac
    fi
    if tui_ok; then
        local f=0; [[ $def == n ]] && f=1
        tui_dialog "Question" "$q" "$f" 1 Yes No
        return "$TUI_CHOICE"
    fi
    if [[ -t 0 ]]; then
        prompt="[Y/n]"; [[ $def == n ]] && prompt="[y/N]"
        read -r -p "${YELLOW}?${NC} $q $prompt " ans
        ans=${ans:-$def}
        [[ $ans =~ ^[Yy] ]]; return
    fi
    [[ $def == y ]]
}

ui_message() {  # final summary / important info
    local title=$1 text=$2
    [[ $GUI == true ]] || return 0
    case $GUI_TOOL in
        zenity)  zenity --info --title="$title" --width=560 --no-markup --text="$text" 2>/dev/null ;;
        yad)     yad --title="$title" --width=560 --text="$(gui_escape "$text")" --button=OK:0 2>/dev/null ;;
        kdialog) kdialog --title "$title" --msgbox "$text" 2>/dev/null ;;
    esac
}

progress_open() {  # progress_open "title" [pulsate]
    PROG_FD=""
    [[ $GUI == true ]] || return 0
    local extra=()
    [[ ${2:-} == pulsate ]] && extra=(--pulsate)
    case $GUI_TOOL in
        zenity) exec {PROG_FD}> >(zenity --progress --title="$APP_TITLE" --text="$1" --percentage=0 \
                    --auto-close --no-cancel --width=560 "${extra[@]}" 2>/dev/null) ;;
        yad)    exec {PROG_FD}> >(yad --progress --title="$APP_TITLE" --text="$1" --auto-close \
                    --width=560 --no-buttons "${extra[@]}" 2>/dev/null) ;;
        *)      PROG_FD="" ;;
    esac
}

progress_update() {  # progress_update pct "text"   (pct = -1 for unknown)
    local pct=$1 text=$2 cols w filled
    if [[ -t 1 ]]; then
        cols=$(tput cols 2>/dev/null || echo 100)
        w=$(( cols >= 130 ? 40 : cols >= 100 ? 28 : 18 ))
        (( ${#text} > cols - w - 12 )) && text="${text:0:$(( cols - w - 13 ))}…"
        if (( pct < 0 )); then
            local pos=$(( $(date +%s) % w ))
            printf '\r\033[K %s[%s%s%s]%s  %s' "$CYAN" "$(repeat_char '░' "$pos")" "███" \
                "$(repeat_char '░' $(( w - pos > 3 ? w - pos - 3 : 0 )))" "$NC" "$text"
        else
            filled=$(( pct * w / 100 ))
            printf '\r\033[K %s[%s%s]%s %3d%%  %s' "$CYAN" "$(repeat_char '█' "$filled")" \
                "$(repeat_char '░' $(( w - filled )))" "$NC" "$pct" "$text"
        fi
    fi
    if [[ -n $PROG_FD ]]; then
        { (( pct >= 0 )) && echo "$pct"; echo "# $text"; } 1>&"$PROG_FD" 2>/dev/null || PROG_FD=""
    fi
}

progress_close() {
    [[ -t 1 ]] && printf '\n'
    if [[ -n $PROG_FD ]]; then
        echo 100 1>&"$PROG_FD" 2>/dev/null
        exec {PROG_FD}>&- 2>/dev/null
        PROG_FD=""
    fi
}

gui_pulse_start() {  # pulsating GUI dialog with live data counter while helper output scrolls in the terminal
    [[ $GUI == true ]] || return 0
    progress_open "$1…" pulsate
    [[ -n $PROG_FD ]] || return 0
    local label=$1
    ( trap '' INT QUIT HUP; while kill -0 "$$" 2>/dev/null; do
          echo "# $label — 📶 $(human "$(net_used)") downloaded this run" 1>&"$PROG_FD" 2>/dev/null || exit 0
          sleep 2
      done ) &
    PULSE_PID=$!
}

gui_pulse_stop() {
    [[ -n ${PULSE_PID:-} ]] && kill "$PULSE_PID" 2>/dev/null
    PULSE_PID=""
    [[ -n $PROG_FD ]] && { echo 100 1>&"$PROG_FD" 2>/dev/null; exec {PROG_FD}>&- 2>/dev/null; PROG_FD=""; }
    return 0
}

setup_askpass() {  # GUI without a terminal: let sudo ask for the password in a dialog
    local ap="$TMP/askpass.sh"
    case $GUI_TOOL in
        zenity)  printf '#!/bin/sh
exec zenity --password --title="%s"
' "$APP_TITLE" >"$ap" ;;
        yad)     printf '#!/bin/sh
exec yad --entry --hide-text --title="%s" --text="sudo password"
' "$APP_TITLE" >"$ap" ;;
        kdialog) printf '#!/bin/sh
exec kdialog --password "sudo password for %s"
' "$APP_TITLE" >"$ap" ;;
    esac
    chmod 700 "$ap"
    export SUDO_ASKPASS="$ap"
    sudo() { command sudo -A "$@"; }
}

start_ticker() {  # keeps the terminal title updated with step + data used
    [[ -t 1 ]] || return 0
    (
        trap '' INT QUIT HUP     # keys are for the main script; the emergency stop ends this loop with TERM
        while kill -0 "$$" 2>/dev/null; do
            printf '\033]0;%s — %s — 📶 %s\007' "$APP_TITLE" "$(cat "$TMP/step" 2>/dev/null)" "$(human "$(net_used)")" 2>/dev/null >/dev/tty
            panel_draw
            sleep 2
        done
    ) &
    TICKER_PID=$!
}

relaunch_in_terminal() {
    local t
    for t in kgx gnome-terminal konsole xfce4-terminal kitty alacritty foot wezterm xterm; do
        have "$t" || continue
        export SMART_UPDATE_IN_TERM=1
        case $t in
            kgx|gnome-terminal) exec "$t" -- bash "$SELF" "${ORIG_ARGS[@]}" ;;
            xfce4-terminal)     exec "$t" -x bash "$SELF" "${ORIG_ARGS[@]}" ;;
            wezterm)            exec "$t" start -- bash "$SELF" "${ORIG_ARGS[@]}" ;;
            kitty|foot)         exec "$t" bash "$SELF" "${ORIG_ARGS[@]}" ;;
            *)                  exec "$t" -e bash "$SELF" "${ORIG_ARGS[@]}" ;;
        esac
    done
    return 1
}

gui_choose_tasks() {
    [[ $GUI == true && $GUI_TOOL == zenity ]] || return 0
    local b sel
    b() { [[ $1 == true ]] && echo TRUE || echo FALSE; }
    sel=$(zenity --list --checklist --title="$APP_TITLE" --width=560 --height=460 \
        --text="Choose what to run:" --column=Run --column=Key --column=Task --hide-column=2 --separator=' ' \
        "$(b "$DO_OFFICIAL")" official "Update official packages (pacman)" \
        "$(b "$DO_AUR")"      aur      "Update AUR packages" \
        "$(b "$DO_FLATPAK")"  flatpak  "Update Flatpak apps" \
        "$(b "$DO_SNAP")"     snap     "Update Snap packages" \
        "$(b "$DO_FIRMWARE")" firmware "Check firmware updates" \
        "$(b "$DO_CLEANUP")"  cleanup  "Clean cache, orphans and journal" \
        "$(b "$DO_HEALTH")"   health   "System health report" \
        "$([[ $FIX_MODE == auto ]] && echo TRUE || echo FALSE)" autofix "Apply safe fixes without asking" \
        2>/dev/null) || exit 0
    local k
    for k in official aur flatpak snap firmware cleanup health; do
        local v=false; [[ " $sel " == *" $k "* ]] && v=true
        case $k in
            official) DO_OFFICIAL=$v ;; aur) DO_AUR=$v ;; flatpak) DO_FLATPAK=$v ;; snap) DO_SNAP=$v ;;
            firmware) DO_FIRMWARE=$v ;; cleanup) DO_CLEANUP=$v ;; health) DO_HEALTH=$v ;;
        esac
    done
    [[ " $sel " == *" autofix "* ]] && FIX_MODE=auto
}

# ======================================================================
# ERROR KNOWLEDGE BASE
# ======================================================================
# issue_meta CODE -> sets ITITLE, IWHY, IHINT, IRISK (safe|risky|none)
issue_meta() {
    IRISK=safe
    case $1 in
        SUDO)
            ITITLE="sudo authentication failed or expired"
            IWHY="The command needed root but the sudo session timed out or no password could be asked."
            IHINT="sudo -v   (then re-run)" ;;
        NETWORK)
            ITITLE="Network / DNS resolution problem"
            IWHY="Server names could not be resolved in time ('Resolving timed out', 'dns error'). Usually a slow or filtered DNS server, a VPN/proxy whose DNS is down, or the connection dropped."
            IHINT="ping -c3 archlinux.org; resolvectl status; nmcli general status" ;;
        LOCK)
            ITITLE="Pacman database is locked (db.lck)"
            IWHY="Another package manager (pamac, Discover/PackageKit, another terminal) is running, or a previous run crashed and left a stale lock."
            IHINT="pgrep -a 'pacman|pamac|packagekit'; if none: sudo rm /var/lib/pacman/db.lck" ;;
        DISK)
            ITITLE="Not enough free disk space"
            IWHY="The root, /var or /boot partition is too full to download or unpack the updates."
            IHINT="sudo paccache -rk1; sudo paccache -ruk0; sudo journalctl --vacuum-size=200M; df -h" ;;
        SYNC_DB)
            ITITLE="Package databases could not be synchronised"
            IWHY="A sync database is missing, half-downloaded or has a bad signature. Usually a mirror served a broken/empty file."
            IHINT="sudo rm /var/lib/pacman/sync/*; sudo pacman -Syy" ;;
        KEYRING)
            ITITLE="PGP signature / keyring problem"
            IWHY="Your archlinux-keyring is older than the key that signed a package, the keyring is not initialised, or the system clock is wrong."
            IHINT="sudo pacman -Sy archlinux-keyring && sudo pacman -Su; or: sudo pacman-key --init && sudo pacman-key --populate" ;;
        CORRUPT_PKG)
            ITITLE="Corrupted package file in cache"
            IWHY="A download was interrupted or a mirror served a bad file; pacman refuses it."
            IHINT="Delete the file named in the error from /var/cache/pacman/pkg and retry" ;;
        BLOCKED_DL)
            ITITLE="Some packages cannot be downloaded (filtering, censorship or throttling)"
            IWHY="The same package files failed on several different mirrors (connection resets, timeouts, stalls) while other packages downloaded. That pattern means something between you and the mirrors blocks or throttles these transfers (ISP filtering/DPI, regional censorship, a VPN that drops long downloads), not that the mirrors are broken."
            IHINT="Download the file through another network/proxy into $CACHE_DIR, use an in-country mirror (MIRROR_COUNTRY_CODE), or set PROXY_URL; then run again"
            IRISK=safe ;;
        SLOW_NET)
            ITITLE="Unstable or very slow connection"
            IWHY="Downloads stalled ('Operation too slow', 'Connection timed out', 'HTTP/2 stream reset'). When many different mirrors fail the same way, the problem is the connection (VPN, filtering, weak Wi-Fi), not the mirrors."
            IHINT="sudo pacman -Syu --disable-download-timeout; set ParallelDownloads = 2 in /etc/pacman.conf; use mirrors near you (MIRROR_COUNTRY)" ;;
        THIRDPARTY_DB)
            ITITLE="A third-party repository is unreachable"
            IWHY="An extra repo added to pacman.conf (not core/extra/multilib) could not be downloaded, and pacman refuses to continue when any database fails."
            IHINT="Temporarily comment out that [repo] section in /etc/pacman.conf, update, then re-enable it" ;;
        INFORMANT)
            IRISK=risky
            ITITLE="Unread Arch news is blocking pacman (informant hook)"
            IWHY="The 'informant' package installs a pacman hook that aborts every transaction while there are unread Arch news items."
            IHINT="informant list --unread; sudo informant read --all   (after reading the news)" ;;
        AUR_PKGBUILD)
            IRISK=safe
            ITITLE="An AUR package's build script (PKGBUILD) is invalid"
            IWHY="makepkg refused the PKGBUILD itself (e.g. 'sha256sums does not allow empty values'). Some -bin PKGBUILDs download their checksum list from the internet while being read; when that request is blocked or times out, the list is empty. Otherwise the maintainer published a broken version."
            IHINT="rm -rf ~/.cache/paru/clone/<pkg> (fresh copy), retry; if it persists, read the AUR comments and skip it: paru -Sua --ignore <pkg>" ;;
        AUR_SOURCE)
            ITITLE="An AUR package's upstream download server is unreachable"
            IWHY="makepkg could not download the package's source from its vendor (geo-blocking, firewall/VPN, or the server is down). Rebuilding will not help."
            IHINT="Skip it for now (paru -Sua --ignore <pkg>), try again later or through a VPN" ;;
        LOCALE)
            ITITLE="Your system locale is not generated"
            IWHY="LANG is set (e.g. en_US.UTF-8) but that locale was never generated, so perl, bsdtar and others print 'Setting locale failed' and fall back to C."
            IHINT="Uncomment your locale in /etc/locale.gen, then: sudo locale-gen" ;;
        MIRRORS)
            ITITLE="Mirror is slow, outdated or failing"
            IWHY="Downloads timed out or returned 404/5xx. The mirror is out of sync or overloaded."
            IHINT="sudo reflector --latest 20 --fastest 10 --protocol https --save /etc/pacman.d/mirrorlist; sudo pacman -Syy" ;;
        FILE_CONFLICT)
            IRISK=risky
            ITITLE="File conflicts: files already exist on disk"
            IWHY="Files installed manually (pip, make install, an old AUR build) or a package that was split/renamed own the same paths."
            IHINT="pacman -Qo <path>; if unowned move it away; for owned paths follow the Arch news instructions" ;;
        PKG_CONFLICT)
            IRISK=risky
            ITITLE="Two packages conflict and pacman needs a decision"
            IWHY="A package replaces or conflicts with an installed one. With --noconfirm pacman answers 'No' and aborts."
            IHINT="sudo pacman -Syu   (interactively, answer the 'Remove X?' question)" ;;
        DEPENDENCY)
            ITITLE="Dependency cannot be satisfied"
            IWHY="An installed package (usually from the AUR) pins an old version of a library that the update replaces, or the mirror is mid-sync."
            IHINT="Update/rebuild the blocking AUR package, or remove it, update, and reinstall it" ;;
        TARGET_MISSING)
            IRISK=none
            ITITLE="Package not found in any repository / AUR"
            IWHY="The package was renamed, merged or removed upstream."
            IHINT="pacman -Ss <name>; check https://archlinux.org/packages/ and the AUR; remove it with pacman -Rns" ;;
        AUR_PGP)
            ITITLE="AUR source signature key unknown"
            IWHY="The PKGBUILD verifies upstream sources with a PGP key you have not imported."
            IHINT="gpg --recv-keys <KEYID>   (listed in the PKGBUILD validpgpkeys)" ;;
        AUR_BUILD)
            ITITLE="AUR package failed to build"
            IWHY="Stale build directory, changed checksums, missing make-dependency, or the PKGBUILD is outdated after a library update."
            IHINT="Clean the helper cache for the package and rebuild; read the AUR comments for the package" ;;
        OOM)
            ITITLE="Build ran out of memory"
            IWHY="A large AUR build was killed by the OOM killer."
            IHINT="Build with fewer jobs: MAKEFLAGS=-j2; add swap/zram" ;;
        DKMS)
            IRISK=risky
            ITITLE="DKMS kernel module failed to build"
            IWHY="Kernel headers are missing for an installed kernel, or the module (nvidia, virtualbox, zfs) does not support the new kernel yet."
            IHINT="Install <kernel>-headers for every installed kernel; dkms status" ;;
        HOOK)
            IRISK=risky
            ITITLE="A post-install hook failed (initramfs / bootloader)"
            IWHY="mkinitcpio or another hook returned an error. The packages were installed, but boot files may be stale."
            IHINT="sudo mkinitcpio -P and read its errors before rebooting" ;;
        LOCAL_DB)
            IRISK=none
            ITITLE="Local package database looks damaged"
            IWHY="Files under /var/lib/pacman/local are missing or duplicated (crash during an earlier update, disk error)."
            IHINT="sudo pacman -Dk; reinstall listed packages; check disk health with smartctl" ;;
        PARTIAL)
            ITITLE="Programs are linked to libraries that were replaced"
            IWHY="A library (or Python/Perl) was updated to a new version, but some programs still expect the old one. Repo programs are fixed by finishing the full upgrade; AUR programs must be rebuilt against the new library. Also caused by 'pacman -Sy pkg' or IgnorePkg."
            IHINT="sudo pacman -Syu; then rebuild the AUR packages listed (paru -S --rebuild <pkg>); checkrebuild (rebuild-detector) lists them" ;;
        REMOVED_REPO)
            ITITLE="pacman.conf still lists repositories Arch has removed"
            IWHY="[community] was merged into [extra] and [testing] was split into [core-testing]/[extra-testing] (2023). Systems that were not updated since then still ask for these databases, which no mirror has any more, so every sync fails."
            IHINT="Delete the [community], [community-testing] and [testing] sections from /etc/pacman.conf (or merge /etc/pacman.conf.pacnew), then sudo pacman -Syu" ;;
        IGNORED_PKG)
            IRISK=risky
            ITITLE="A package you hold back (IgnorePkg) blocks the update"
            IWHY="pacman.conf tells pacman never to upgrade some packages, but the update needs a newer version of one of them (a version requirement of another package). Holding a library back while the rest moves on is the classic partial upgrade."
            IHINT="Remove the package from IgnorePkg in /etc/pacman.conf, or let this run upgrade it once" ;;
        PACMAN_BROKEN)
            IRISK=risky
            ITITLE="pacman itself cannot start (broken by a partial upgrade)"
            IWHY="pacman needs a library version that is not installed (an interrupted update, 'pacman -Sy pkg', or a library from outside the repos). Without a working pacman nothing can be repaired the normal way."
            IHINT="Download pacman-static (self-contained, from the AUR maintainer's build) and run: sudo ./pacman-static -Syu" ;;
        NO_SERVERS)
            ITITLE="No mirror is configured for a repository"
            IWHY="The mirror list has no active 'Server =' line (every line commented out, or the file was replaced by an empty .pacnew), so pacman has nowhere to download from."
            IHINT="sudo reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist; or uncomment a Server line" ;;
        AUR_HELPER_BROKEN)
            ITITLE="The AUR helper itself is broken after a pacman update"
            IWHY="paru/yay are linked to pacman's library (libalpm). When pacman gets a new major version, a helper built for the old one can no longer start until it is rebuilt."
            IHINT="Rebuild it: git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -sif   (or paru / yay from source)" ;;
        AUR_DEP_MISSING)
            ITITLE="An AUR package needs a dependency that no longer exists"
            IWHY="One of its dependencies was renamed, merged into another package or deleted from the AUR/repos. The PKGBUILD has not been updated yet, so the helper cannot resolve it."
            IHINT="Read the package's AUR comments; skip it for now (paru -Sua --ignore <pkg>) or remove it" ;;
        SERVICE_FAILED)
            ITITLE="${#FAILED_UNITS[@]} service(s) have failed"
            IWHY="A service stopped with an error — often because it started while its files were being replaced during the update, or hit systemd's restart limit ('start request repeated too quickly'). A clean restart usually brings it back; if it fails again, the service itself has a problem and its log says why."
            IHINT="sudo systemctl reset-failed <unit> && sudo systemctl restart <unit>   (systemctl --user … for user services)" ;;
        AUR_TOOLCHAIN)
            ITITLE="Build tools for AUR packages are missing"
            IWHY="makepkg needs the base-devel group (fakeroot, strip, gcc, make…) and debugedit. They are not installed, or a newer makepkg needs a tool the system did not have before."
            IHINT="sudo pacman -S --needed base-devel debugedit" ;;
        READONLY_FS)
            IRISK=none
            ITITLE="Filesystem is read-only"
            IWHY="The kernel remounted a filesystem read-only after I/O errors, or a snapshot is booted."
            IHINT="journalctl -k | grep -iE 'error|remount'; check the disk and run fsck from a live USB" ;;
        IO_ERROR)
            IRISK=none
            ITITLE="Disk input/output errors"
            IWHY="The storage device returned read/write errors. The disk may be failing."
            IHINT="sudo smartctl -a /dev/sdX (or nvme0); back up your data first" ;;
        CERT)
            ITITLE="TLS certificate check failed"
            IWHY="Wrong system clock, a proxy intercepting HTTPS, or outdated ca-certificates."
            IHINT="timedatectl; sudo timedatectl set-ntp true; check \$https_proxy" ;;
        FLATPAK)
            ITITLE="Flatpak update failed"
            IWHY="A broken ref or a remote that is no longer reachable."
            IHINT="flatpak repair --user; sudo flatpak repair; flatpak remotes" ;;
        SNAP_STORE)
            ITITLE="The Snap Store cannot be reached"
            IWHY="snapd's connection to api.snapcraft.io was cut ('EOF', 'connection reset', 'TLS handshake timeout', 'i/o timeout'). On filtered networks some of Canonical's store servers are blocked at the TLS handshake while others for the same name still answer; it can also be a dropped connection, DNS trouble or an old /etc/hosts entry."
            IHINT="curl -sv https://api.snapcraft.io/ ; pin a working Canonical address in /etc/hosts, or: sudo snap set system proxy.https=http://127.0.0.1:<port>" ;;
        SNAPD_DOWN)
            ITITLE="snapd is not running"
            IWHY="The snap command could not talk to the snapd daemon (/run/snapd.socket is missing or refuses connections): snapd.socket is disabled or the daemon crashed."
            IHINT="sudo systemctl enable --now snapd.socket snapd.apparmor.service" ;;
        SNAP_CHANGE)
            ITITLE="Another snap operation is still running"
            IWHY="snapd runs one change per snap at a time; an automatic refresh or install was already in progress."
            IHINT="snap changes; snap watch --last=auto-refresh   (or sudo snap abort <id> if it is stuck)" ;;
        SNAP_RUNNING)
            ITITLE="Some snaps are open, so snapd will not update them"
            IWHY="snapd refuses to replace a snap while its apps run ('has running apps'), so they don't crash. The other snaps can still be updated."
            IHINT="Close the app, then: sudo snap refresh <name>" ;;
        SNAP_SEED)
            ITITLE="snapd has not finished its first setup (seeding)"
            IWHY="Right after installing or upgrading snapd it 'seeds' its base snaps; until that is done it answers 'too early for operation'."
            IHINT="sudo snap wait system seed.loaded" ;;
        SNAP_CLASSIC)
            ITITLE="Classic snaps need the /snap link"
            IWHY="Snaps with classic confinement (code, android-studio…) must live under /snap. On Arch snapd keeps them in /var/lib/snapd/snap, so /snap has to be a symlink to it."
            IHINT="sudo ln -s /var/lib/snapd/snap /snap" ;;
        SNAP_MOUNT)
            ITITLE="Snaps cannot be mounted (squashfs)"
            IWHY="Every snap is a squashfs image mounted through a loop device. The module is missing — after a kernel update the running kernel's modules are gone until you reboot."
            IHINT="Reboot; or: sudo modprobe squashfs loop && sudo systemctl restart snapd" ;;
        SNAP_SPACE)
            ITITLE="Not enough disk space for snap updates"
            IWHY="snapd keeps up to 3 revisions of every snap plus a download cache under /var/lib/snapd."
            IHINT="snap list --all | grep disabled; sudo snap remove <name> --revision=<rev>; sudo snap set system refresh.retain=2" ;;
        SNAP_APPARMOR)
            ITITLE="snapd's AppArmor profiles are not loaded"
            IWHY="snap-confine refuses to start apps when its AppArmor profile is missing (apparmor or snapd.apparmor.service not running)."
            IHINT="sudo systemctl enable --now apparmor.service snapd.apparmor.service" ;;
        FLATPAK_REMOTE)
            ITITLE="A Flatpak remote is disabled, misconfigured or its signing key is missing"
            IWHY="Flatpak could not use a remote: it is disabled, its address is outdated, its summary is missing or its GPG key is not trusted ('GPG signatures found, but none are in trusted keyring')."
            IHINT="flatpak remotes --show-disabled; flatpak remote-modify --enable flathub; flatpak remote-modify --url=https://dl.flathub.org/repo/ flathub" ;;
        FLATPAK_HELPER)
            ITITLE="Flatpak's system helper does not answer"
            IWHY="System-wide installs go through flatpak-system-helper over D-Bus and polkit; it timed out or is not running."
            IHINT="sudo systemctl restart polkit flatpak-system-helper" ;;
        FLATPAK_SPACE)
            ITITLE="Not enough disk space for Flatpak updates"
            IWHY="Old runtimes nothing uses any more often take gigabytes."
            IHINT="flatpak uninstall --unused; sudo flatpak uninstall --unused" ;;
        FLATPAK_NET)
            ITITLE="Flathub could not be reached"
            IWHY="Flatpak's downloads timed out or the connection dropped (Timeout was reached / Could not connect / Server returned status 5xx)."
            IHINT="curl -I https://dl.flathub.org/repo/summary.idx; try again later" ;;
        DB_VERSION)
            ITITLE="pacman's local database has an old format"
            IWHY="A new pacman version changed the database format and asks for pacman-db-upgrade."
            IHINT="sudo pacman-db-upgrade" ;;
        PACMAN_CONF)
            IRISK=risky
            ITITLE="pacman.conf (or an included file) has an error"
            IWHY="pacman stops when its configuration has an unknown directive or an invalid value — usually an option that was removed in a newer pacman, or a typo."
            IHINT="Fix the line named in the error, or compare with /etc/pacman.conf.pacnew (pacdiff)" ;;
        STALE_HOOK)
            IRISK=risky
            ITITLE="A pacman hook runs a program that no longer exists"
            IWHY="A hook in /etc/pacman.d/hooks (or one left by an uninstalled package) calls a missing program ('call to execv failed'), so every transaction reports an error."
            IHINT="grep -l Exec /etc/pacman.d/hooks/*.hook; move the stale hook away" ;;
        GNUPG_PERMS)
            ITITLE="Your ~/.gnupg has wrong ownership or permissions"
            IWHY="gpg refuses or warns ('unsafe permissions on homedir') when ~/.gnupg is not private or belongs to root (after running gpg with sudo). AUR signature checks then fail."
            IHINT="sudo chown -R \$USER: ~/.gnupg; chmod 700 ~/.gnupg; chmod 600 ~/.gnupg/*" ;;
        GPG_AGENT)
            ITITLE="gpg-agent is stuck or cannot start"
            IWHY="gpg could not talk to its agent, or a stale lock file blocks the keyring."
            IHINT="gpgconf --kill all; sudo gpgconf --homedir /etc/pacman.d/gnupg --kill all" ;;
        BUSY_FILE)
            ITITLE="A file was in use"
            IWHY="A program kept a file open that had to be replaced ('Text file busy' / 'Device or resource busy')."
            IHINT="fuser -v <file>; close the program and retry" ;;
        AUR_ROOT)
            IRISK=none
            ITITLE="makepkg was run as root"
            IWHY="makepkg (and paru/yay) refuse to build as root for safety."
            IHINT="Run the script as your normal user, not with sudo" ;;
        ARCH_INVALID)
            IRISK=none
            ITITLE="Package built for another CPU architecture"
            IWHY="A package's architecture does not match pacman's Architecture setting (often a foreign or x86_64_v3 repository)."
            IHINT="Architecture = auto in /etc/pacman.conf; remove the foreign repo or package" ;;
        MODULES_GONE)
            IRISK=none
            ITITLE="Kernel modules of the running kernel are gone — reboot needed"
            IWHY="The update replaced the kernel; the running kernel's modules were removed, so nothing can load new modules until you reboot."
            IHINT="Reboot" ;;
        PERMISSION)
            IRISK=none
            ITITLE="Permission denied on a system file"
            IWHY="Even root was refused: the file is immutable (chattr +i), on a read-only mount, or blocked by a security module."
            IHINT="lsattr <path>; sudo chattr -i <path>; mount | grep ' ro,'" ;;
        SYMLINKS)
            ITITLE="Broken symlinks that can be repaired"
            IWHY="Links that point to files that no longer exist: leftovers of removed programs, services enabled before they were renamed or uninstalled, missing package files, or a missing default Java / DNS / time zone target."
            IHINT="find /usr/bin /usr/lib /etc -xtype l; pacman -Qo <link>" ;;
        *)
            ITITLE="Unrecognised error"
            IWHY="This failure does not match any known pattern."
            IHINT="Read the key error lines below; check Arch news and the forums" ;;
    esac
}

guess_domain() {  # pacman, aur, snap or flatpak for a saved log: AUR only when makepkg failed and pacman itself did not
    if grep -qE 'snapcraft\.io|snapd|snap "[^"]+"|cannot (refresh|install) "' "$1" && ! grep -qE 'pacman|makepkg' "$1"; then echo snap; return; fi
    if grep -qE 'flatpak|flathub|ostree|\.flatpakrepo' "$1" && ! grep -qE 'pacman|makepkg' "$1"; then echo flatpak; return; fi
    if grep -qE '==> ERROR|makepkg|error making: ' "$1" && ! grep -qE 'failed to commit transaction|failed to synchroni[sz]e|failed retrieving file' "$1"; then
        echo aur; else echo pacman; fi
}

hook_section_error() {  # "==> ERROR:" inside pacman's hook output (makepkg prints the same prefix)
    awk 'tolower($0) ~ /running post-transaction hooks/ {h=1}
         /^==> (Making package|Retrieving sources|Validating source|Extracting sources|Starting (build|prepare|package|check)|Entering fakeroot|Finished making)|^:: (Synchronizing|Starting full|Proceed with)|^resolving dependencies|Failure while downloading|failed to download sources/ {h=0}
         h && /==> ERROR:/ {f=1} END {exit !f}' "$CLEAN_LOG"
}

add_issue() { local c; for c in "${ISSUES[@]}"; do [[ $c == "$1" ]] && return; done; ISSUES+=("$1"); }

diagnose() {  # diagnose LOGFILE [domain]
    local f=$1 dom=${2:-pacman}
    ISSUES=()
    CLEAN_LOG="$f.clean"
    # drop the package list line (matches almost any word) and this script's own annotations
    # ([DIAG] lines quote error patterns), so a saved smart-update log can be re-diagnosed
    strip_ansi <"$f" | grep -vE '^Packages \([0-9]+\) |^\[(DIAG|NOTIFY|INFO|SUCCESS|WARNING|ERROR|RESCUE|FIX)\] |^\[[0-9]{4}-[0-9-]+ [0-9:]+\] ' >"$CLEAN_LOG"
    m() { grep -qiE -- "$1" "$CLEAN_LOG"; }

    m '(^|[/ ])pacman: (error while loading shared libraries|symbol lookup error)|pacman: .*version .* not found' && add_issue PACMAN_BROKEN
    m "database file for '($REMOVED_REPOS)' does not exist|failed retrieving file '($REMOVED_REPOS)\.db'|failed to update ($REMOVED_REPOS) " && add_issue REMOVED_REPO
    m 'no servers configured for repository' && add_issue NO_SERVERS
    m 'a password is required|sudo: .*(incorrect password|no tty present|a terminal is required)' && add_issue SUDO
    local tp_only=0
    if [[ -n $(thirdparty_failed_repos) ]]; then
        add_issue THIRDPARTY_DB
        # every failed download belongs to the third-party repo(s) → the connection itself is fine
        grep -E "failed retrieving file" "$CLEAN_LOG" | grep -vqE "'($(thirdparty_failed_repos | paste -sd'|'))\.db'" || tp_only=1
    fi
    if (( ! tp_only )); then
    m "could not resolve host|couldn't resolve host|temporary failure in name resolution|network is unreachable|no route to host|resolving timed out|dns error|failed to lookup address" && add_issue NETWORK
    m 'informant: Run .informant read|unread news items! Use informant' && add_issue INFORMANT
    m 'unable to lock database|db\.lck' && add_issue LOCK
    m 'not enough free disk space|no space left on device|partition .* (is )?too full' && add_issue DISK
    m 'read-only file system' && add_issue READONLY_FS
    m 'input/output error' && add_issue IO_ERROR
    m 'operation too slow|connection timed out|resolving timed out|HTTP/2 stream .* reset|PROTOCOL_ERROR|transfer closed with|connection reset by peer' && add_issue SLOW_NET
    if m 'failed retrieving file|failed to retrieve some files|returned error: (404|403|5[0-9][0-9])' && (( $(failed_host_count) < 3 )); then
        add_issue MIRRORS   # few hosts failing → mirror problem; many hosts failing → connection problem (SLOW_NET/NETWORK)
    fi
    # the same package files failing on 3+ mirrors → filtered/throttled downloads: fetch those files another way
    [[ -n $(blocked_files) ]] && (( $(failed_host_count) >= 3 )) && add_issue BLOCKED_DL
    fi
    # a missing database of a repo Arch removed is REMOVED_REPO, not a broken download
    if m 'GPGME error|invalid or corrupted database|could not find database|Unrecognized archive format|could not open file .*/sync/' \
       || grep -oiE "database file for '[a-z0-9_-]+' does not exist" "$CLEAN_LOG" | grep -qvE "'($REMOVED_REPOS)'"; then
        add_issue SYNC_DB
    fi
    m 'failed to synchroni[sz]e all databases|failed to update [a-z-]+ \(' && ! m 'failed retrieving file|no servers configured' && add_issue SYNC_DB
    m 'signature from .* is (unknown trust|marginal trust|invalid|expired)|invalid or corrupted package \(PGP signature\)|key .* (could not be looked up|is disabled|could not be imported)|required key missing from keyring|public keyring not found|keyring is not writable' && add_issue KEYRING
    m 'key .* is unknown' && ! m 'Import PGP key' && add_issue KEYRING   # with the import prompt, pacman imports it itself
    m 'file .* is corrupted|invalid or corrupted package \(checksum\)|could not find or read package' && add_issue CORRUPT_PKG
    m 'SSL certificate problem|certificate verify failed|certificate is not yet valid|certificate has expired' && add_issue CERT
    m 'exists in filesystem' && add_issue FILE_CONFLICT
    m 'are in conflict|unresolvable package conflicts' && add_issue PKG_CONFLICT
    if m 'breaks dependency|could not satisfy dependencies|unable to satisfy dependency|cannot resolve ".*", a dependency of'; then
        [[ -n $(ignored_blockers) ]] && add_issue IGNORED_PKG   # the version it needs is held back by IgnorePkg
        add_issue DEPENDENCY
    fi
    m 'could not find all required packages|no AUR package found for|\(wanted by' && add_issue AUR_DEP_MISSING   # pacman never prints these: helper output
    m 'cannot find the (fakeroot|strip|debugedit) binary|(fakeroot|debugedit|makepkg): command not found' && add_issue AUR_TOOLCHAIN
    m '(paru|yay): error while loading shared libraries|libalpm\.so\.[0-9]+: cannot open shared object' && add_issue AUR_HELPER_BROKEN
    m 'target not found' && add_issue TARGET_MISSING
    m 'unknown public key|One or more PGP signatures could not be verified' && add_issue AUR_PGP
    m 'killed|out of memory|signal 9|cannot allocate memory' && [[ $dom == aur ]] && add_issue OOM
    m "$PKGBUILD_BROKEN_RE" && add_issue AUR_PKGBUILD
    if m 'Failure while downloading' || { m 'failed to download sources for' && ! m "unknown public key|PGP signatures|validity check|$PKGBUILD_BROKEN_RE"; }; then add_issue AUR_SOURCE; fi
    if m 'did not pass the validity check|A failure occurred in (prepare|build|package|check|pkgver)\(\)|Failure while building'; then add_issue AUR_BUILD
    elif m 'failed to build|error making:|could not build|Makepkg was unable' && ! m 'Failure while downloading|failed to download sources'; then add_issue AUR_BUILD; fi
    m 'Bad return status for module build|dkms.*(failed|error)|kernel headers for kernel .* cannot be found' && add_issue DKMS
    if { m 'command failed to execute correctly|mkinitcpio: (error|failed)|Image generation FAILED' || hook_section_error; } && ! m 'informant: Run'; then add_issue HOOK; fi
    m 'Setting locale failed|Failed to set default locale|Cannot set the default locale' && add_issue LOCALE
    m 'could not open file .*/local/|missing .* file .*/local/|duplicated database entry|could not read db' && add_issue LOCAL_DB
    m 'error while loading shared libraries|symbol lookup error|undefined symbol' \
        && [[ " ${ISSUES[*]} " != *" PACMAN_BROKEN "* && " ${ISSUES[*]} " != *" AUR_HELPER_BROKEN "* ]] && add_issue PARTIAL
    # ---- Snap ----
    if [[ $dom == snap ]]; then
        m 'cannot communicate with server|dial unix /run/snapd(-snap)?\.socket|snapd (is not|isn.t) running|snapd\.socket.*(refused|no such file)' && add_issue SNAPD_DOWN
        m '(cannot|failed to) (refresh|install|remove|download|query|get)[^:]*: .*(snapcraft\.io|store)|(Post|Get) "https://api\.snapcraft\.io|persistent network error|store is unavailable|cannot get nonce from store|cannot connect to the store|unable to contact snap store|TLS handshake timeout|tls: |i/o timeout|context deadline exceeded|unexpected EOF|connection reset by peer|lookup api\.snapcraft\.io' && add_issue SNAP_STORE
        m 'has "[^"]+" change in progress|change in progress|cannot refresh .*: snap ".*" has changes in progress' && add_issue SNAP_CHANGE
        m 'snap "[^"]+" has running apps' && add_issue SNAP_RUNNING
        m 'too early for operation|device not yet seeded|device model not acknowledged' && add_issue SNAP_SEED
        m 'classic confinement requires snaps under /snap|symlink from /snap to /var/lib/snapd/snap' && add_issue SNAP_CLASSIC
        m "unknown filesystem type 'squashfs'|squashfs.*(not supported|unknown)|cannot mount .*\.snap|failed to setup loop device|snap-[a-z0-9_-]+\.mount.*failed" && add_issue SNAP_MOUNT
        m 'insufficient space|not enough (disk )?space|no space left on device' && add_issue SNAP_SPACE
        m 'snap-confine.*(apparmor|is not confined)|apparmor.*(denied|cannot (load|find) profile)|AppArmor profile.*(not loaded|missing)' && add_issue SNAP_APPARMOR
        m 'x509: certificate' && add_issue CERT
        # the store checks also resolve the name: the generic net/DNS issues would only tune pacman
        if [[ " ${ISSUES[*]} " == *" SNAP_STORE "* ]]; then
            local keep=() x; for x in "${ISSUES[@]}"; do [[ $x =~ ^(NETWORK|SLOW_NET|DISK)$ ]] || keep+=("$x"); done; ISSUES=("${keep[@]}")
        fi
        [[ " ${ISSUES[*]} " == *" SNAP_SPACE "* ]] && { local keep=() x; for x in "${ISSUES[@]}"; do [[ $x == DISK ]] || keep+=("$x"); done; ISSUES=("${keep[@]}"); }
    fi
    # ---- Flatpak ----
    if [[ $dom == flatpak ]]; then
        m 'remote "?[a-z0-9_-]+"? (is disabled|not found)|Can.t fetch summary from disabled remote|No remote refs found|GPG verification enabled, but no summary|GPG signatures found, but none are in trusted keyring|Remote "[^"]+" not found|summary\.sig.*(not found|404)' && add_issue FLATPAK_REMOTE
        m 'GDBus\.Error.*(ServiceUnknown|NoReply|Timeout)|flatpak-system-helper|Failed to connect to bus|polkit.*(not authorized|Authentication)' && add_issue FLATPAK_HELPER
        m 'no space left on device|not enough disk space|insufficient space' && add_issue FLATPAK_SPACE
        m 'Timeout was reached|Could not connect|Server returned status 5[0-9][0-9]|While (pulling|fetching) .*(Connection|Socket|Timeout|reset)|Error receiving data|Socket I/O timed out|Unable to load summary from remote' && add_issue FLATPAK_NET
        m 'Could not resolve hostname|Error resolving' && add_issue NETWORK
        local keep=() x; for x in "${ISSUES[@]}"; do
            [[ $x == SLOW_NET ]] && continue                                            # pacman-only tuning
            [[ $x == DISK && " ${ISSUES[*]} " == *" FLATPAK_SPACE "* ]] && continue
            keep+=("$x"); done; ISSUES=("${keep[@]}")
    fi
    # ---- more pacman / AUR knowledge ----
    m 'database (is )?(incorrect|wrong) version|pacman-db-upgrade|local database is (too old|incompatible)' && add_issue DB_VERSION
    m "config file .*, line [0-9]+:|directive '[^']+' in section '[^']+' not recognized|invalid value for '[^']+'|failed to initialize alpm library" && add_issue PACMAN_CONF
    m 'call to execv failed|error: hook .*(line [0-9]+|invalid|missing)|could not open file .*\.hook' && [[ -n $(stale_hooks) ]] && add_issue STALE_HOOK
    m 'gpg: WARNING: unsafe (permissions|ownership) on homedir|gpg: .*: Permission denied|gpg: failed to create temporary file' && add_issue GNUPG_PERMS
    m "can't connect to the agent|gpg-agent.*(failed|not running|error)|error running '/usr/bin/gpg-agent'|keybox.*(lock|locked)|waiting for lock .*gnupg" && add_issue GPG_AGENT
    m 'Text file busy|Device or resource busy' && add_issue BUSY_FILE
    m 'Running makepkg as root is not allowed|should not (run|be run) as root' && add_issue AUR_ROOT
    m 'package architecture is not valid|does not have a valid architecture' && add_issue ARCH_INVALID
    m 'modprobe: FATAL: Module .* not found in directory /lib/modules|could not insert .*: (Unknown symbol|Exec format error)' && kernel_replaced && add_issue MODULES_GONE
    m '(could not|failed to|cannot) [^:]*(/usr|/etc|/var|/boot)[^:]*: (Permission denied|Operation not permitted)' && ! m 'a password is required|incorrect password' && add_issue PERMISSION
    [[ $dom == flatpak ]] && (( ${#ISSUES[@]} == 0 )) && m 'error' && add_issue FLATPAK

    (( ${#ISSUES[@]} == 0 )) && add_issue UNKNOWN
    local c rest=()
    # when only some files fail on many mirrors, that is the real story: show it first
    # (apply_fixes still runs it last, after the DNS/connection tweaks it benefits from)
    if [[ " ${ISSUES[*]} " == *" BLOCKED_DL "* ]]; then
        for c in "${ISSUES[@]}"; do [[ $c == BLOCKED_DL ]] || rest+=("$c"); done
        ISSUES=(BLOCKED_DL "${rest[@]}")
    fi
    # root causes go first: nothing else can be fixed while pacman cannot start or the config names dead repos
    local front=() first
    for first in PACMAN_BROKEN PACMAN_CONF DB_VERSION REMOVED_REPO NO_SERVERS SNAPD_DOWN GNUPG_PERMS GPG_AGENT AUR_HELPER_BROKEN IGNORED_PKG; do
        [[ " ${ISSUES[*]} " == *" $first "* ]] && front+=("$first")
    done
    if (( ${#front[@]} )); then
        rest=()
        for c in "${ISSUES[@]}"; do [[ " ${front[*]} " == *" $c "* ]] || rest+=("$c"); done
        ISSUES=("${front[@]}" "${rest[@]}")
    fi
    for c in "${ISSUES[@]}"; do ISSUES_SEEN+=("$c"); done
    return 0
}

key_error_lines() {
    grep -iE '(^|[^a-z])(error|fatal|failed|conflict|breaks dependency|exists in filesystem|corrupted|unknown public key|not found)' "$CLEAN_LOG" \
        | grep -viE '^warning: .*(newer than|is up to date)|^ *-> ' | awk '!seen[$0]++' | tail -n 8
}

# ---------- parsers used by details and fixes ----------
parse_file_conflicts() {  # prints "path|owner"
    sed -nE 's/^[^:]+: (\/.+) exists in filesystem( \(owned by ([^)]+)\))?.*$/\1|\3/p' "$CLEAN_LOG" | sort -u
}

parse_dep_blockers() {  # prints names of packages that block (required by X / a dependency of "X")
    { grep -oiE "required by [^ ]+" "$CLEAN_LOG" | awk '{print $3}'
      grep -oiE 'a dependency of "[^"]+"' "$CLEAN_LOG" | awk '{print $4}'; } | sed "s/['\"]//g" | sort -u
}

parse_corrupt_files() {
    { grep -oE 'File [^ ]+\.pkg\.tar[^ ]* is corrupted' "$CLEAN_LOG" | awk '{print $2}'
      grep -oE '/[^ :]+\.pkg\.tar\.[a-z]+' "$CLEAN_LOG" | grep -F "$CACHE_DIR"; } | sort -u
}

parse_pgp_keys() {
    { grep -oiE 'unknown public key [0-9A-F]{8,40}' "$CLEAN_LOG" | awk '{print $4}'
      grep -oiE 'key "?[0-9A-F]{16,40}"? (could not|is unknown)' "$CLEAN_LOG" | grep -oiE '[0-9A-F]{16,40}'; } | sort -u
}

failed_host_count() {
    grep -oE "failed retrieving file '[^']+' from [^ ]+" "$CLEAN_LOG" | awk '{print $NF}' | sort -u | wc -l
}

OFFICIAL_REPOS='core|extra|multilib|core-testing|extra-testing|multilib-testing|gnome-unstable|kde-unstable'
REMOVED_REPOS='community|community-testing|community-staging|testing|staging'   # retired by Arch in 2023
thirdparty_failed_repos() {  # third-party repos whose .db failed while core.db did not
    local failed; failed=$(grep -oE "failed retrieving file '[^']+\.db' from" "$CLEAN_LOG" 2>/dev/null | sed -E "s/.*file '([^']+)\.db'.*/\1/" | sort -u)
    [[ -z $failed ]] && return 0
    grep -qx core <<<"$failed" && return 0   # official repos fail too → connection problem, not the repo
    grep -vxE "$OFFICIAL_REPOS|$REMOVED_REPOS" <<<"$failed"
}

removed_repos_in_conf() { grep -oE '^[[:space:]]*\[[a-z-]+\]' /etc/pacman.conf 2>/dev/null | tr -d '[] \t' | grep -xE "$REMOVED_REPOS"; }

ignored_blockers() {  # IgnorePkg entries named in the dependency errors of the current log
    local ign; ign=$(pacman-conf IgnorePkg 2>/dev/null)
    [[ -n $ign ]] || return 0
    grep -iE 'breaks dependency|unable to satisfy|could not satisfy|cannot resolve|ignoring package upgrade' "$CLEAN_LOG" 2>/dev/null \
        | grep -oE "[A-Za-z0-9@._+-]+" | sort -u | grep -xF -f <(printf '%s\n' $ign)
}

parse_wanted_by() {  # AUR packages whose dependency cannot be found ("foo (wanted by: bar -> baz)")
    grep -oiE '\(wanted by:? [^)]+\)' "$CLEAN_LOG" 2>/dev/null | sed -E 's/^\([Ww]anted by:? //; s/\)$//; s/->/ /g' | tr ' ' '\n' | sed '/^$/d' | sort -u
}

parse_pgp_emails() {  # packagers named in pacman signature errors ("signature from "Name <mail>" is unknown trust")
    grep -oE 'signature from "[^"]*<[^>]+>"' "$CLEAN_LOG" 2>/dev/null | grep -oE '<[^>]+>' | tr -d '<>' | sort -u
}

explain_dep_errors() {  # pacman's dependency errors in plain language
    local line re_inst re_rm re_sat re_res
    re_inst="installing ([^ ]+) \(([^)]+)\) breaks dependency '([^']+)' required by ([^ ]+)"
    re_rm="removing ([^ ]+) breaks dependency '([^']+)' required by ([^ ]+)"
    re_sat="unable to satisfy dependency '([^']+)' required by ([^ ]+)"
    re_res='cannot resolve "([^"]+)", a dependency of "([^"]+)"'
    while IFS= read -r line; do
        if [[ $line =~ $re_inst ]]; then
            echo "'${BASH_REMATCH[4]}' requires ${BASH_REMATCH[3]}, but the update brings ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}."
        elif [[ $line =~ $re_rm ]]; then
            echo "'${BASH_REMATCH[3]}' requires ${BASH_REMATCH[2]}, but the update removes or replaces ${BASH_REMATCH[1]}."
        elif [[ $line =~ $re_sat ]]; then
            echo "'${BASH_REMATCH[2]}' requires ${BASH_REMATCH[1]}, which no repository provides any more (renamed, dropped, or a library version that was replaced)."
        elif [[ $line =~ $re_res ]]; then
            echo "'${BASH_REMATCH[2]}' requires ${BASH_REMATCH[1]}, which cannot be found in any repository."
        fi
    done < <(grep -iE 'breaks dependency|unable to satisfy|cannot resolve' "$CLEAN_LOG" 2>/dev/null) | sort -u | head -8
}

PKGBUILD_BROKEN_RE='does not allow empty values|is not allowed to be empty|Failed to source .*PKGBUILD|PKGBUILD contains CRLF|PKGBUILD: line [0-9]+: syntax error|missing from (source|sha256sums|md5sums) array|Integrity checks \([a-z0-9]+\) differ in size from the source array'
parse_source_fail_pkgs() {
    grep -oE "failed to download sources for '[^']+'" "$CLEAN_LOG" | sed -E "s/.*'([^']+)'/\1/; s/-[^-]+-[^-]+$//" | sort -u
}

active_vpn() {
    local i out=""
    for i in /sys/class/net/*; do i=${i##*/}; [[ $i =~ ^(tun|tap|wg|nordlynx|proton|ppp|tailscale|zt) ]] && out+="$i "; done
    pgrep -x 'v2ray|xray|sing-box|nekoray|clash|clash-verge|hiddify' >/dev/null && out+="(proxy: $(pgrep -lx 'v2ray|xray|sing-box|nekoray|clash|clash-verge|hiddify' | awk '{print $2}' | sort -u | tr '\n' ' '))"
    echo "$out"
}

parse_failed_aur_pkgs() {
    { grep -oE "failed to build '[^']+'" "$CLEAN_LOG" | sed -E "s/failed to build '([^']+)'/\1/"
      grep -oE 'error making: [^ ]+' "$CLEAN_LOG" | awk '{print $3}' | sed -E 's/-exit$//'
      grep -oE 'packages failed to build: .*' "$CLEAN_LOG" | cut -d: -f2- | tr ' ' '\n'; } | sed '/^$/d' | sort -u
}

issue_details() {  # extra, case-specific guesses
    local code=$1 line p o
    case $code in
        BLOCKED_DL)
            dl_failure_summary | sed 's/^/     /'
            p=$(user_country); [[ -n $p ]] && echo "     Your time zone says $(country_name "$p") ($p): mirrors inside the country are usually not filtered and will be tried first."
            [[ -n $(active_vpn) ]] && echo "     VPN/proxy active: $(active_vpn)"
            for p in $(dl_failures | awk -F'|' '$3 == "dns" {print $2}' | sort -u | head -4); do
                dns_poisoned "$p" && echo "     DNS for $p returns a private address → your DNS is poisoned/filtered; DNS-over-HTTPS will be used"
            done ;;
        LOCK)
            local procs; procs=$(pgrep -a -x 'pacman|pamac|pamac-daemon|packagekitd|yay|paru' 2>/dev/null | grep -v "^$$ ")
            if [[ -n $procs ]]; then echo "     Running now: $(tr '\n' ';' <<<"$procs")"
            else echo "     No package manager is running → the lock is stale and safe to remove."; fi ;;
        DISK)
            for p in / /var "$CACHE_DIR" /boot /home; do
                [[ -d $p ]] || continue
                echo "     $(df -Ph "$p" | awk 'NR==2 {printf "%-22s %s free of %s (%s used)", $6, $4, $2, $5}')"
            done | sort -u
            # "No space left" with free space = no free inodes (many small files)
            df -Pi / /var 2>/dev/null | awk 'NR>1 && $5+0 >= 95 {printf "     %s: %s of file slots (inodes) used — no new files can be created even with free space\n", $6, $5}' | sort -u ;;
        FILE_CONFLICT)
            while IFS='|' read -r p o; do
                [[ -z $p ]] && continue
                if [[ -z $o ]]; then o=$(LC_ALL=C pacman -Qoq "$p" 2>/dev/null | head -1); fi
                if [[ -n $o ]]; then echo "     $p  (owned by package '$o' → probably a split/renamed package, see news)"
                else echo "     $p  (not owned by any package → leftover from manual install, safe to move aside)"; fi
            done < <(parse_file_conflicts | head -15) ;;
        DEPENDENCY)
            local foreign rb; foreign=$(pacman -Qmq 2>/dev/null)
            explain_dep_errors | sed 's/^/     • /'
            for p in $(parse_dep_blockers); do
                if grep -qx -- "$p" <<<"$foreign" || [[ $p =~ -(git|bin|svn|hg|bzr)$ ]]; then
                    rb=$(LC_ALL=C pacman -Qi "$p" 2>/dev/null | awk -F': ' '/^Required By/ {print $2}')
                    echo "     → '$p' is an AUR/foreign package built for the old version: it must be removed for the update and rebuilt afterwards."
                    [[ -n $rb && $rb != None* ]] && echo "       Needed by: $rb (they stay installed; only '$p' is removed for a moment)"
                    echo "       AUR page: https://aur.archlinux.org/packages/$p"
                else
                    echo "     → '$p' is a repo package: the mirror is probably mid-sync (half of a coordinated update). Refreshing mirrors usually fixes it."
                fi
            done ;;
        IGNORED_PKG)
            explain_dep_errors | sed 's/^/     • /'
            echo "     Held back in /etc/pacman.conf (IgnorePkg): $(ignored_blockers | tr '\n' ' ')" ;;
        REMOVED_REPO)
            p=$(removed_repos_in_conf | sed 's/.*/[&]/' | tr '\n' ' ')
            if [[ -n $p ]]; then echo "     Removed repositories still in /etc/pacman.conf: $p"
            else echo "     /etc/pacman.conf no longer lists them (already fixed since this log was written)"; fi
            [[ -e /etc/pacman.conf.pacnew ]] && echo "     /etc/pacman.conf.pacnew exists: the current default config from pacman (never merged)." ;;
        PACMAN_BROKEN)
            LC_ALL=C pacman -V 2>&1 | grep -iE 'error|not found' | head -2 | sed 's/^/     /' ;;
        AUR_HELPER_BROKEN)
            local hh; hh=$(find_aur_helper); [[ $hh != none ]] && "$hh" --version 2>&1 | head -2 | sed 's/^/     /'
            echo "     pacman: $(pacman -Q pacman 2>/dev/null)" ;;
        AUR_DEP_MISSING)
            grep -iE 'wanted by' "$CLEAN_LOG" | sort -u | head -5 | sed 's/^/     /'
            for p in $(parse_wanted_by); do pacman -Qq "$p" &>/dev/null && echo "     → $p: https://aur.archlinux.org/packages/$p#comments"; done ;;
        NO_SERVERS)
            grep -oE 'no servers configured for repository: ?[a-z0-9_-]+' "$CLEAN_LOG" | sort -u | sed 's/^/     /'
            echo "     Active Server lines in the mirror list: $(grep -cE '^[[:space:]]*Server' /etc/pacman.d/mirrorlist 2>/dev/null || echo 0)" ;;
        KEYRING)
            [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == no ]] && echo "     → System clock is NOT synchronised; that alone can make valid signatures look invalid."
            local kd; kd=$(LC_ALL=C pacman -Qi archlinux-keyring 2>/dev/null | awk -F': ' '/^Install Date/ {print $2}')
            [[ -n $kd ]] && echo "     archlinux-keyring installed: $kd" ;;
        AUR_BUILD)
            for p in $(parse_failed_aur_pkgs); do echo "     Failed: $p   → https://aur.archlinux.org/packages/${p%%-[0-9]*}#comments"; done ;;
        AUR_PGP)
            for p in $(parse_pgp_keys); do echo "     Missing key: $p"; done ;;
        DKMS)
            local k
            for k in $(installed_kernels); do pacman -Q "$k-headers" &>/dev/null || echo "     → Kernel '$k' has no '$k-headers' installed"; done ;;
        PARTIAL)
            grep -iE 'error while loading shared libraries|symbol lookup error' "$CLEAN_LOG" | head -3 | sed 's/^/     /'
            local lib; lib=$(grep -oE 'loading shared libraries: [^:]+' "$CLEAN_LOG" | head -1 | awk '{print $4}')
            if [[ -n $lib ]]; then
                o=$(pacman -Fq "${lib%.so*}.so" 2>/dev/null | head -3 | tr '\n' ' ')
                echo "     Missing: $lib${o:+  (current version comes from: $o)}"
            fi ;;
        NETWORK|SLOW_NET)
            [[ $code == SLOW_NET && " ${ISSUES[*]} " == *" NETWORK "* ]] && { echo "     (see the network details above)"; return 0; }
            local hc vpn; hc=$(failed_host_count)
            (( hc >= 3 )) && echo "     → $hc different servers failed the same way: the problem is your connection/DNS, not the mirrors."
            local nres; nres=$(grep -ciE 'resolving timed out|dns error|name resolution' "$CLEAN_LOG")
            (( nres > 0 )) && echo "     → $nres DNS lookups timed out (the name server is slow or unreachable)."
            vpn=$(active_vpn); [[ -n $vpn ]] && echo "     → VPN/proxy active: $vpn— its DNS or route is the most likely culprit; try another server or disconnect for the update."
            echo "     Downloaded parts are kept, so each retry resumes instead of starting over." ;;
        THIRDPARTY_DB)
            for p in $(thirdparty_failed_repos); do echo "     → [$p] ($(pacman-conf --repo="$p" Server 2>/dev/null | head -1)) could not be reached"; done ;;
        INFORMANT)
            have informant && informant list --unread 2>/dev/null | head -8 | sed 's/^/     📰 /' ;;
        AUR_PKGBUILD)
            grep -hE "$PKGBUILD_BROKEN_RE" "$CLEAN_LOG" | sort -u | head -3 | sed 's/^/     makepkg: /'
            for p in $(parse_source_fail_pkgs); do echo "     → $p: https://aur.archlinux.org/packages/$p#comments"; done ;;
        AUR_SOURCE)
            for p in $(parse_source_fail_pkgs); do echo "     → $p: source server unreachable"; done
            grep -oE 'Failure while downloading https?://[^/ ]+' "$CLEAN_LOG" | awk '{print $4}' | sort -u | sed 's|^|     host: |' ;;
        LOCALE)
            echo "     LANG=${LANG:-unset}; generated locales: $(locale -a 2>/dev/null | tr '\n' ' ' | cut -c1-80)" ;;
    esac
    # Link to Arch news that mention involved packages
    if (( ${#NEWS_TITLES[@]} )) && [[ $code =~ ^(FILE_CONFLICT|DEPENDENCY|PKG_CONFLICT|KEYRING)$ ]]; then
        local n; for n in "${NEWS_TITLES[@]}"; do echo "     📰 Recent news (may contain the official fix): $n"; done
    fi
}

unknown_guess() {
    local err; err=$(key_error_lines | tail -1)
    echo "     Heuristic guesses:"
    if grep -qiE 'permission denied' "$CLEAN_LOG"; then echo "     • 'Permission denied' → wrong ownership on a file/dir, or something mounted read-only."; fi
    if grep -qiE 'segmentation fault|core dumped' "$CLEAN_LOG"; then echo "     • A tool crashed → possible partial upgrade or bad RAM. pacman-static (AUR) can rescue a broken pacman."; fi
    if grep -qiE 'proxy' "$CLEAN_LOG"; then echo "     • Proxy involved → check http_proxy/https_proxy variables."; fi
    if grep -qiE 'python|pip' "$CLEAN_LOG"; then echo "     • Python involved → leftover pip-installed files in /usr/lib/python3.*/site-packages often break updates."; fi
    echo "     • Transient server problems are common: a retry with fresh databases is attempted automatically."
    if [[ -n $err ]]; then
        echo "     • Search this error: https://bbs.archlinux.org/search.php?action=search&keywords=$(urlencode "${err:0:120}")"
    fi
    echo "     • Check news: https://archlinux.org/news/"
    if [[ -n $AI_SUGGEST_CMD ]]; then
        local cmd; read -ra cmd <<<"$AI_SUGGEST_CMD"
        if have "${cmd[0]}"; then
            echo "     🤖 Asking $AI_SUGGEST_CMD for a suggestion (nothing will be executed)…"
            timeout 120 "${cmd[@]}" "An Arch Linux system update failed. Explain the most likely cause in 3 sentences and give the exact safe commands to fix it. Do not suggest partial upgrades (pacman -Sy pkg). Output:
$(tail -n 60 "$CLEAN_LOG")" 2>/dev/null | sed 's/^/        /' | head -40
        fi
    fi
}

report_diagnosis() {
    local i=0 c label
    printf '\n%s┌─ 🔎 DIAGNOSIS %s%s\n' "$BOLD$YELLOW" "$(repeat_char '─' 40)" "$NC"
    printf '%s│%s Key error lines:\n' "$YELLOW" "$NC"
    key_error_lines | sed "s/^/${YELLOW}│${NC}   /"
    for c in "${ISSUES[@]}"; do
        issue_meta "$c"; i=$(( i + 1 ))
        label="Possible cause"; (( i == 1 )) && label="Most likely cause"
        printf '%s│%s\n%s│ %d. %s:%s %s%s%s\n' "$YELLOW" "$NC" "$YELLOW" "$i" "$label" "$NC" "$BOLD" "$ITITLE" "$NC"
        printf '%s│%s    Why:  %s\n' "$YELLOW" "$NC" "$IWHY"
        issue_details "$c" | sed "s/^/${YELLOW}│${NC}/"
        printf '%s│%s    Manual fix: %s%s%s\n' "$YELLOW" "$NC" "$CYAN" "$IHINT" "$NC"
        if [[ $c == UNKNOWN ]]; then unknown_guess | sed "s/^/${YELLOW}│${NC}/"; fi
        case $IRISK in
            safe)  printf '%s│%s    Auto-fix: available (safe)\n' "$YELLOW" "$NC" ;;
            risky) printf '%s│%s    Auto-fix: available (changes files/packages — needs your OK)\n' "$YELLOW" "$NC" ;;
            none)  printf '%s│%s    Auto-fix: none — needs manual action\n' "$YELLOW" "$NC" ;;
        esac
        _log "[DIAG] $c: $ITITLE — $IWHY — hint: $IHINT"
    done
    printf '%s└%s%s\n' "$YELLOW" "$(repeat_char '─' 55)" "$NC"
}

# ======================================================================
# FIXES  (each returns 0 if it changed something worth a retry)
# ======================================================================
installed_kernels() {
    pacman -Qq 2>/dev/null | grep -xE 'linux|linux-lts|linux-zen|linux-hardened|linux-rt|linux-rt-lts|linux-cachyos[a-z-]*|linux-xanmod[a-z-]*'
}

ensure_clock() {
    have timedatectl || return 1
    [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == no ]] || return 1
    log_fix "Clock not synchronised — enabling NTP"
    sudo timedatectl set-ntp true 2>/dev/null
    local i; for i in 1 2 3 4 5 6; do
        [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]] && break; sleep 2
    done
    return 0
}

net_ok() {  # any HTTP answer from any of several hosts counts; retried, because one failed ping is not "offline"
    local urls=() m u try rounds=${1:-3}
    m=$(awk -F'= *' '/^Server/ {print $2; exit}' /etc/pacman.d/mirrorlist 2>/dev/null); m=${m%%\$*}
    [[ -n $m ]] && urls+=("$m")
    urls+=(https://geo.mirror.pkgbuild.com/ https://archlinux.org/ https://1.1.1.1/)
    for (( try = 1; try <= rounds; try++ )); do
        for u in "${urls[@]}"; do curl -sS --max-time 10 -o /dev/null "$u" 2>/dev/null && return 0; done
        (( try < rounds )) && sleep $(( try * 3 ))
    done
    return 1
}

dns_ok() {  # resolves within 3 s?
    timeout 3 getent hosts "${1:-archlinux.org}" >/dev/null 2>&1
}

build_pacman_conf() {  # temporary pacman.conf for this run: slow-network settings and skipped repos
    local conf="$TMP/pacman.conf" r
    cp /etc/pacman.conf "$conf" || return 1
    for r in "${SKIP_REPOS[@]}"; do
        awk -v r="[$r]" '$0==r {skip=1; next} /^\[/ {skip=0} !skip' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf"
    done
    if (( SLOW_LEVEL >= 1 )); then
        sed -i -E '/^[[:space:]]*#?[[:space:]]*ParallelDownloads/d' "$conf"
        sed -i -E "0,/^\[options\]/s//[options]\nParallelDownloads = $(( SLOW_LEVEL >= 2 ? 1 : 2 ))/" "$conf"
    fi
    if (( SLOW_LEVEL >= 1 )); then
        sed -i -E '/^[[:space:]]*#?[[:space:]]*DisableDownloadTimeout/d' "$conf"
        sed -i -E "0,/^\[options\]/s//[options]\nDisableDownloadTimeout/" "$conf"
    fi
    if [[ -n $PAC_PROXY || -n $PAC_DOH ]] || (( SLOW_LEVEL >= 2 )); then
        write_xfer_script
        local xfer="XferCommand = $TMP/xfer.sh %o %u"
        sed -i -E '/^[[:space:]]*XferCommand/d' "$conf"
        awk -v x="$xfer" '{print} !done && $0 == "[options]" {print x; done=1}' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf"
    fi
    if (( ${#UNIGNORE_PKGS[@]} )); then   # upgrade these once despite IgnorePkg (fix IGNORED_PKG)
        awk -v drop=" ${UNIGNORE_PKGS[*]} " '
            /^[[:space:]]*IgnorePkg[[:space:]]*=/ {
                v=$0; sub(/^[^=]*=/, "", v); n=split(v, w, /[[:space:]]+/); out=""
                for (i = 1; i <= n; i++) if (w[i] != "" && index(drop, " " w[i] " ") == 0) out = out " " w[i]
                print (out == "" ? "#IgnorePkg =" : "IgnorePkg =" out); next }
            { print }' "$conf" >"$conf.tmp" && mv "$conf.tmp" "$conf"
    fi
    PAC_OPTS=(--config "$conf")
    (( SLOW_LEVEL >= 1 )) && PAC_OPTS+=(--disable-download-timeout)
    (( ${#HOLD_PKGS[@]} )) && PAC_OPTS+=(--ignore "$(IFS=,; echo "${HOLD_PKGS[*]}")")
    return 0
}

write_xfer_script() {  # pacman's XferCommand: curl that retries cuts and stalls, but gives up at once on 404/403/410
    # (curl --retry-all-errors retried every missing .db.sig 8 times, minutes of waiting per mirror)
    cat >"$TMP/xfer.sh" <<XFER
#!/bin/bash
out=\$1; url=\$2
echo "  ⬇ \${url##*/}" >&2
for i in 1 2 3 4 5 6 7 8; do
    code=\$(curl -L -C - -f -sS --connect-timeout 30 --speed-limit 1 --speed-time 120 --http1.1${PAC_PROXY:+ -x $PAC_PROXY}${PAC_DOH:+ --doh-url $PAC_DOH} -w '%{http_code}' -o "\$out" "\$url")
    rc=\$?
    (( rc == 0 )) && exit 0
    case \$code in 404|403|410|451) exit 22 ;; esac   # not there / refused: let pacman try the next mirror
    (( rc == 33 )) && rm -f "\$out"                    # server cannot resume: start over
    sleep 5
done
exit 1
XFER
    chmod 755 "$TMP/xfer.sh"
}

refresh_mirrors() {
    local ml=/etc/pacman.d/mirrorlist new="$TMP/mirrorlist.new"
    if have pacman-mirrors; then
        log_fix "Re-ranking mirrors with pacman-mirrors (Manjaro)"
        sudo pacman-mirrors --fasttrack 10 2>&1 | tee -a "$LOG_FILE"; return
    fi
    log_fix "Ranking fresh HTTPS mirrors…"
    if have reflector; then
        local ct=3 dt=5; (( SLOW_LEVEL > 0 )) && { ct=10; dt=20; }
        local args=(--latest 20 --fastest 10 --protocol https --age 12 --connection-timeout "$ct" --download-timeout "$dt" --save "$new")
        local cc; cc=$(user_country)
        if [[ -n $MIRROR_COUNTRY ]]; then args+=(--country "$MIRROR_COUNTRY")
        elif [[ -n $cc ]]; then
            log_info "Trying mirrors inside your country first ($cc): traffic that stays in the country is rarely filtered or throttled"
            reflector "${args[@]}" --country "$cc" 2>&1 | grep -v 'failed to rate' | tee -a "$LOG_FILE"
            (( $(grep -cE '^Server' "$new" 2>/dev/null || echo 0) >= 3 )) || : >"$new"
        fi
        [[ -s $new ]] || reflector "${args[@]}" 2>&1 | grep -v 'failed to rate' | tee -a "$LOG_FILE"
        if [[ ! -s $new ]] && [[ -n $(country_mirrors) ]]; then   # reflector needs archlinux.org; fall back to known in-country mirrors
            country_mirrors | sed 's/^/Server = /' >"$new"
        fi
    else
        curl -fsS --max-time 20 'https://archlinux.org/mirrorlist/?country=all&protocol=https&use_mirror_status=on' 2>/dev/null \
            | sed 's/^#Server/Server/' | grep -E '^Server' | head -10 >"$new"
    fi
    if grep -qE '^Server *= *https?://' "$new" 2>/dev/null; then
        sudo cp -a "$ml" "$ml.smart-update.bak" 2>/dev/null
        sudo install -m644 "$new" "$ml" && log_success "Mirrorlist updated (backup: $ml.smart-update.bak)"
        return 0
    fi
    log_warning "Could not build a new mirror list; keeping the current one"
    return 1
}

remove_corrupt_cached() {
    local f n=0
    while read -r f; do
        [[ -n $f && -e $f ]] || continue
        sudo rm -f -- "$f" "$f.sig" && { log_fix "Removed corrupted cached file $f"; n=$((n + 1)); }
    done < <(parse_corrupt_files)
    (( n > 0 ))   # .part files are kept on purpose: pacman resumes them on the next try
}

fix_SUDO() { log_fix "Re-validating sudo"; sudo -v; }

fix_NETWORK() {
    local i link=0
    if grep -qiE 'resolving timed out|dns error|name resolution|resolve host' "$CLEAN_LOG" 2>/dev/null || ! dns_ok; then
        fix_DNS && return 0
    fi
    log_fix "Waiting for the network to come back (up to 60 s)…"
    for i in $(seq 1 12); do
        if net_ok 1; then   # some host answered (possibly only 1.1.1.1 by IP)
            link=1
            if dns_ok || dns_ok geo.mirror.pkgbuild.com; then log_success "Network and DNS are back"; return 0; fi
            break
        fi
        sleep 5
    done
    (( link )) || ping -c1 -W3 1.1.1.1 &>/dev/null && link=1
    if (( link )); then
        # the old check said "Network is back" here and retried pacman into the same wall 3 times
        log_warning "The internet works by IP address, but host names cannot be looked up: the system DNS is down"
        resolver_state
        if systemctl is-active -q systemd-resolved; then
            log_fix "Flushing systemd-resolved caches"; sudo resolvectl flush-caches 2>/dev/null
            dns_ok && return 0
        fi
        if [[ -z $PAC_DOH ]]; then enable_doh && return 0
        else log_warning "pacman already uses DNS-over-HTTPS ($PAC_DOH) and still failed — the mirrors themselves are unreachable"; fi
    fi
    return 1
}

dns_dead() {  # no answer at all for several well-known names (not just slow)
    local h; for h in archlinux.org geo.mirror.pkgbuild.com "${1:-mirror.pkgbuild.com}"; do timeout 5 getent hosts "$h" >/dev/null 2>&1 && return 1; done
    return 0
}
resolver_state() {  # explain WHY names don't resolve: which DNS servers the system really uses
    local ns ifc pv gw
    ns=$(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
    ifc=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if [[ -z $ns ]]; then
        detail "/etc/resolv.conf lists NO DNS server$( [[ -L /etc/resolv.conf ]] && echo " (it links to $(readlink /etc/resolv.conf))") — every name lookup fails instantly."
    else
        detail "DNS servers in /etc/resolv.conf: $ns"
        [[ $ns == *127.0.0.53* ]] && ! systemctl is-active -q systemd-resolved && detail "   127.0.0.53 is systemd-resolved, but that service is not running."
    fi
    if have nmcli && [[ -n $ifc ]]; then
        detail "NetworkManager DNS for $ifc: $(nmcli -g IP4.DNS device show "$ifc" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//;s/^$/none/')"
        pv=$(nmcli -t -f NAME connection show --active 2>/dev/null | grep -iE 'pvpn|proton|killswitch|ipv6leak' | tr '\n' ' ')
        [[ -n $pv ]] && detail "Leftover VPN kill-switch connections are active: $pv— they block normal DNS when the VPN is off. Reconnect the VPN, or remove them: nmcli connection delete <name>"
    fi
    [[ $gw == 192.168.137.1 ]] && detail "You are on a Windows 'Mobile hotspot' (192.168.137.1): its DNS only works while the Windows side has a working connection/VPN."
    [[ -n $gw ]] && detail "Fix for the whole system: reconnect Wi-Fi (nmcli connection up \"$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)\"), or set DNS in NetworkManager → $ifc → IPv4 → DNS (e.g. $gw, or 1.1.1.1/9.9.9.9 if not filtered)"
}
enable_doh() {  # system DNS is down but DoH answers: let pacman resolve through it (this run only)
    local d; d=$(working_doh)
    [[ -n $d ]] || { log_warning "DNS-over-HTTPS is not reachable either (${DOH_URLS// /, })"; return 1; }
    PAC_DOH=$d; DNS_DEAD=true
    build_pacman_conf
    log_fix "System DNS is down, but DNS-over-HTTPS works ($d): pacman will look up mirror names through it for this run (XferCommand = curl --doh-url …; nothing on the system is changed)"
    log_info "Flatpak, Snap and the AUR cannot use DoH; they are skipped while the system DNS is down"
    return 0
}

fix_DNS() {
    local ok=0 i
    for i in 1 2 3; do dns_ok && ok=$((ok + 1)); done
    if (( ok == 3 )); then log_info "DNS answers quickly right now (the earlier timeouts were intermittent)"; return 0; fi
    log_warning "DNS is slow or failing ($ok/3 lookups answered within 3 s)"
    local vpn; vpn=$(active_vpn); [[ -n $vpn ]] && log_info "VPN/proxy detected: $vpn — reconnecting it or choosing another server often fixes DNS"
    systemctl is-active -q systemd-resolved && { sudo resolvectl flush-caches 2>/dev/null; log_fix "Flushed DNS cache"; }
    local ifc; ifc=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if systemctl is-active -q systemd-resolved && [[ -n $ifc ]] && have resolvectl; then
        if [[ $FIX_MODE != auto || $ALLOW_RISKY_AUTO == true ]] && ui_ask "Temporarily use public DNS (1.1.1.1, 9.9.9.9) on $ifc until it reconnects? Undo anytime: sudo resolvectl revert $ifc" y; then
            sudo resolvectl dns "$ifc" 1.1.1.1 9.9.9.9 8.8.8.8 && log_fix "Public DNS set on $ifc (temporary; revert: sudo resolvectl revert $ifc)"
            dns_ok && return 0
        fi
    else
        log_info "To change DNS: NetworkManager → your connection → IPv4 → DNS servers (e.g. 1.1.1.1, 9.9.9.9)"
    fi
    return 1
}

fix_SLOW_NET() {
    if (( SLOW_LEVEL >= 2 )); then log_warning "Already in maximum slow-network mode"; return 1; fi
    SLOW_LEVEL=$(( SLOW_LEVEL + 1 ))
    build_pacman_conf || return 1
    if (( SLOW_LEVEL == 1 )); then
        log_fix "Slow-network mode 1: no download timeout, only 2 parallel downloads (this run only)"
    else
        log_fix "Slow-network mode 2: downloads through curl with 8 retries, resume and HTTP/1.1 (this run only)"
    fi
    log_info "Already-downloaded parts are kept and resumed"
    return 0
}

fix_THIRDPARTY_DB() {
    local r added=0
    for r in $(thirdparty_failed_repos); do
        [[ " ${SKIP_REPOS[*]} " == *" $r "* ]] && continue
        SKIP_REPOS+=("$r"); added=1
        log_fix "Skipping unreachable third-party repo [$r] for this run (its packages stay at their current version)"
    done
    (( added )) || return 1
    build_pacman_conf
}

fix_INFORMANT() {
    have informant || return 1
    log_fix "Unread Arch news (informant blocks pacman until it is read):"
    sudo informant list --unread 2>/dev/null | sed 's/^/     📰 /'
    echo "     Read in full: informant read   or   https://archlinux.org/news/"
    if ui_ask "Have you read these news items? Mark them read so pacman can continue?" y; then
        sudo informant read --all </dev/null >/dev/null 2>&1 && { log_success "News marked as read"; return 0; }
        log_warning "Could not mark the news as read automatically — run: sudo informant read"
    fi
    return 1
}

fix_AUR_SOURCE() {
    local p added=0
    for p in $(parse_source_fail_pkgs); do
        [[ " ${AUR_IGNORE[*]} " == *" $p "* ]] && continue
        AUR_IGNORE+=("$p"); added=1
        log_fix "Skipping '$p' this run (its download server is unreachable); the other AUR packages will still update"
    done
    (( added ))
}

fix_LOCALE() {
    local want=${LANG:-en_US.UTF-8} base; base=${want%%.*}
    if locale -a 2>/dev/null | grep -qiE "^${base}\.utf-?8$"; then log_info "Locale $want is already generated"; return 1; fi
    if grep -qE "^#[[:space:]]*${base}\.UTF-8 UTF-8" /etc/locale.gen; then
        sudo sed -i -E "s/^#[[:space:]]*(${base}\.UTF-8 UTF-8)/\1/" /etc/locale.gen
    elif ! grep -qE "^${base}\.UTF-8 UTF-8" /etc/locale.gen; then
        echo "${base}.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen >/dev/null
    fi
    log_fix "Generating locale ${base}.UTF-8"
    run_guarded locale sudo locale-gen 2>&1 | tail -2
    return 0
}

check_locale() {
    [[ -n ${LANG:-} && $LANG != C* && $LANG != POSIX ]] || return 0
    local base=${LANG%%.*}
    locale -a 2>/dev/null | grep -qiE "^${base}\.utf-?8$" && return 0
    log_warning "Locale $LANG is not generated (causes 'perl: warning: Setting locale failed' during updates)"
    [[ $DRY_RUN == false ]] && ui_ask "Generate $LANG now?" y && fix_LOCALE
    return 0
}

check_informant() {
    have informant || return 0
    sudo informant check >/dev/null 2>&1 && return 0
    log_warning "informant reports unread Arch news — its pacman hook would abort the update"
    [[ $DRY_RUN == true ]] && return 0
    ISSUES=(INFORMANT); CLEAN_LOG=/dev/null
    fix_INFORMANT || log_warning "News still unread: the update will stop at the informant hook"
}

fix_LOCK() {
    local lock="$DB_PATH/db.lck" i
    for (( i = 0; i < 24; i++ )); do
        [[ -e $lock ]] || return 0
        pgrep -x pacman >/dev/null || break
        (( i == 0 )) && log_fix "Another pacman is running — waiting for it to finish (max 2 min)…"
        sleep 5
    done
    [[ -e $lock ]] || return 0
    if pgrep -x pacman >/dev/null; then
        log_error "pacman is still running: $(pgrep -a -x pacman | tr '\n' ' ')"
        return 1
    fi
    if pgrep -x packagekitd >/dev/null; then
        log_fix "Stopping PackageKit (it can hold the pacman lock)"
        sudo systemctl stop packagekit 2>/dev/null; sleep 2
    fi
    if [[ -e $lock ]]; then
        sudo rm -f "$lock" && log_fix "Removed stale lock $lock"
    fi
    return 0
}

fix_DISK() {
    local before after p
    before=$(free_mb "$CACHE_DIR")
    log_fix "Freeing disk space…"
    if have paccache; then
        sudo paccache -rk1 2>&1 | tail -2
        sudo paccache -ruk0 2>&1 | tail -2
    else
        sudo pacman -Sc --noconfirm 2>&1 | tail -2
    fi
    sudo journalctl --vacuum-size=200M 2>&1 | tail -1
    for p in "$HOME"/.cache/yay/*/ "$HOME"/.cache/paru/clone/*/; do
        rm -rf -- "${p}src" "${p}pkg" "$p"*.pkg.tar.* 2>/dev/null
    done
    remove_corrupt_cached
    local d; for d in "${CACHE_DIRS[@]}"; do sudo find "$d" -maxdepth 2 \( -name '*.part' -o -name 'download-*' \) -exec rm -rf {} + 2>/dev/null; done
    after=$(free_mb "$CACHE_DIR")
    log_success "Free space on $(df -P "$CACHE_DIR" | awk 'NR==2{print $6}'): ${before} MB → ${after} MB"
    if [[ -d /boot ]] && mountpoint -q /boot && (( $(free_mb /boot) < 60 )); then
        log_warning "/boot is nearly full ($(free_mb /boot) MB). Remove unused kernels or disable fallback images in /etc/mkinitcpio.d/*.preset"
    fi
    (( after > before ))
}

fix_SYNC_DB() {
    log_fix "Removing broken sync databases and downloading fresh copies"
    sudo find "$DB_PATH/sync" -maxdepth 1 \( -name '*.part' -o -name '*.lck' \) -delete 2>/dev/null
    if grep -qiE 'GPGME|invalid or corrupted database' "$CLEAN_LOG"; then
        sudo rm -f "$DB_PATH"/sync/*.db "$DB_PATH"/sync/*.sig "$DB_PATH"/sync/*.files 2>/dev/null
        refresh_mirrors
    fi
    sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"
    return 0
}

fix_KEYRING() {
    ensure_clock
    remove_corrupt_cached
    if [[ ! -d /etc/pacman.d/gnupg ]] || grep -qiE 'public keyring not found|keyring is not writable|trustdb' "$CLEAN_LOG"; then
        log_fix "Initialising the pacman keyring"
        run_guarded keyring sudo pacman-key --init 2>&1 | tail -2
    fi
    local rings=() r
    for r in /usr/share/pacman/keyrings/*.gpg; do r=${r##*/}; rings+=("${r%.gpg}"); done
    log_fix "Re-populating keyrings: ${rings[*]:-archlinux}"
    run_guarded keyring sudo pacman-key --populate "${rings[@]}" 2>&1 | tail -2
    local k
    for k in $(parse_pgp_keys); do
        log_fix "Fetching key $k"
        sudo pacman-key --recv-keys "$k" 2>&1 | tail -1
    done
    # long-outdated systems: the keyring package itself is signed by a packager key the old keyring lacks.
    # WKD returns that key with the master-key signatures, so it becomes valid without trusting it by hand.
    for k in $(parse_pgp_emails); do
        log_fix "Looking up the packager key of $k (WKD, verified by the Arch master keys)"
        sudo pacman-key --locate-key "$k" 2>&1 | tail -1
    done
    (( ${FIX_COUNT[KEYRING]:-0} >= 1 )) && { log_fix "Second attempt: rebuilding the keyring trust database"; run_guarded keyring sudo pacman-key --updatedb 2>&1 | tail -2; }
    local kr; kr=$(pacman -Qq 2>/dev/null | grep -E -- '-keyring$')
    [[ -n $kr ]] && log_fix "Updating keyring packages first: $(tr '\n' ' ' <<<"$kr")"
    # shellcheck disable=SC2086
    run_guarded keyring sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Sy --needed --noconfirm $kr 2>&1 | tee -a "$LOG_FILE"
    return 0
}

fix_CORRUPT_PKG() { ensure_clock; remove_corrupt_cached; return 0; }

fix_CERT() { ensure_clock && return 0; log_info "Clock is fine; check proxies or reinstall ca-certificates"; return 1; }

fix_MIRRORS() {
    remove_corrupt_cached
    refresh_mirrors || return 1
    sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"
    return 0
}

fix_FILE_CONFLICT() {
    local backup p o moved=0
    backup="/var/lib/smart-update/conflict-backup/$(date +%Y%m%d-%H%M%S)"
    while IFS='|' read -r p o; do
        [[ -z $p || ! -e $p && ! -L $p ]] && continue
        [[ -z $o ]] && o=$(LC_ALL=C pacman -Qoq "$p" 2>/dev/null | head -1)
        if [[ -n $o ]]; then
            log_warning "Not touching $p (owned by $o). Follow the Arch news / use --overwrite only if the news says so."
            continue
        fi
        sudo mkdir -p "$backup$(dirname "$p")" && sudo mv -- "$p" "$backup$p" && { log_fix "Moved unowned $p → $backup$p"; moved=$((moved + 1)); }
    done < <(parse_file_conflicts)
    (( moved > 0 )) && log_info "Restore with: sudo cp -a $backup/. /"
    (( moved > 0 ))
}

fix_PKG_CONFLICT() {
    if [[ -t 0 ]]; then
        log_fix "Retrying interactively so you can answer pacman's conflict question (usually 'y' to replace)"
        INTERACTIVE_NEXT=1; return 0
    fi
    log_warning "Needs an interactive terminal: run 'sudo pacman -Syu' and answer the question"
    return 1
}

aur_has() {  # aur_has PKG -> 0 on the AUR, 1 not on the AUR, 2 unknown (no answer)
    local out
    out=$(curl -fsS --max-time 15 "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=$(urlencode "$1")" 2>/dev/null) || return 2
    [[ $out == *'"resultcount":0'* ]] && return 1
    [[ $out == *'"resultcount":'* ]] && return 0
    return 2
}

fix_DEPENDENCY() {
    local foreign p blockers=() removed=0 rb rc h
    foreign=$(pacman -Qmq 2>/dev/null)
    for p in $(parse_dep_blockers); do grep -qx -- "$p" <<<"$foreign" && blockers+=("$p"); done
    if (( ${#blockers[@]} == 0 )); then
        log_fix "The package that needs the old version comes from the repos → the mirror is probably mid-sync"
        fix_MIRRORS; return
    fi
    h=$(find_aur_helper)
    for p in "${blockers[@]}"; do
        # never remove something we cannot put back
        aur_has "$p"; rc=$?
        if (( rc == 1 )); then
            log_warning "'$p' is not on the AUR (built by hand or dropped) — not removing it. Rebuild it yourself, or remove it: sudo pacman -R $p"
            continue
        fi
        if [[ $h == none || $h == pamac ]]; then
            log_warning "'$p' must be rebuilt after the update, but no AUR helper (paru/yay) is installed — install one from the menu first"
            continue
        fi
        rb=$(LC_ALL=C pacman -Qi "$p" | awk -F': ' '/^Required By/ {print $2}')
        if [[ -z $rb || $rb == None* ]]; then
            ui_ask "'$p' (AUR) was built for the old version and blocks the update. Remove it, finish the update, then rebuild it from the AUR against the new version?" y || continue
            run_guarded remove sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -R --noconfirm "$p" 2>&1 | tee -a "$LOG_FILE"
        else
            ui_ask "'$p' (AUR) blocks the update, and $rb depend on it. Remove only '$p' for a moment (pacman -Rdd: the packages that need it stay installed), finish the update, then rebuild it right away?" y || continue
            run_guarded remove sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Rdd --noconfirm "$p" 2>&1 | tee -a "$LOG_FILE"
        fi
        if ! pacman -Qq "$p" &>/dev/null; then
            REINSTALL_AFTER+=("$p"); removed=1
            log_fix "Removed $p — it is rebuilt right after the update"
        fi
    done
    (( removed ))
}

# ---------- long-outdated systems, held-back packages, and things that break after an update ----------
fix_REMOVED_REPO() {
    local lst r bak tmp="$TMP/pacman.conf.fixed"
    lst=$(removed_repos_in_conf | tr '\n' ' ')
    [[ -n ${lst// } ]] || { log_info "pacman.conf lists no removed repositories"; return 1; }
    bak="/etc/pacman.conf.smart-update-$(date +%Y%m%d-%H%M%S).bak"
    sudo cp -a /etc/pacman.conf "$bak" || return 1
    cp /etc/pacman.conf "$tmp" || return 1
    for r in $lst; do   # drop the section header and its lines, up to the next blank line or section
        awk -v r="[$r]" '{ t=$0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
                         t == r { skip=1; next }
                         skip && (t == "" || t ~ /^#?[ \t]*\[/) { skip=0 }
                         !skip || t ~ /^#/' "$tmp" >"$tmp.n" && mv "$tmp.n" "$tmp"   # comments are kept
    done
    sudo install -m644 "$tmp" /etc/pacman.conf || return 1
    log_fix "Removed $(for r in $lst; do printf '[%s] ' "$r"; done)from /etc/pacman.conf (backup: $bak)"
    [[ ${PAC_OPTS[0]:-} == --config ]] && build_pacman_conf    # this run's private copy must follow
    sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"
    return 0
}

fix_IGNORED_PKG() {
    local p added=1
    for p in $(ignored_blockers); do
        [[ " ${UNIGNORE_PKGS[*]} " == *" $p "* ]] && continue
        UNIGNORE_PKGS+=("$p"); added=0
    done
    (( added )) && return 1
    build_pacman_conf || return 1
    log_fix "This run upgrades ${UNIGNORE_PKGS[*]} despite IgnorePkg (/etc/pacman.conf itself is unchanged)"
    return 0
}

fix_PACMAN_BROKEN() {
    local ps="$TMP/pacman-static"
    log_fix "Downloading pacman-static (self-contained: it does not use the broken system libraries)"
    curl -fL --retry 3 --connect-timeout 20 --max-time 600 -o "$ps" "$PACMAN_STATIC_URL" 2>&1 | tail -2 || true
    [[ -s $ps ]] || { log_error "Could not download pacman-static from $PACMAN_STATIC_URL"; return 1; }
    chmod 755 "$ps"
    "$ps" -V &>/dev/null || { log_error "The downloaded pacman-static does not run"; return 1; }
    log_fix "Finishing the upgrade with pacman-static (every package signature is still verified)"
    run_guarded install sudo env LC_ALL=C "$ps" "${PAC_OPTS[@]}" -Syu --noconfirm 2>&1 | tee -a "$LOG_FILE"
    if pacman -V &>/dev/null; then log_success "pacman starts again"; return 0; fi
    log_error "pacman still does not start — keep $ps and see https://wiki.archlinux.org/title/Pacman#Pacman_crashes_during_an_upgrade"
    cp -f "$ps" "$STATE_DIR/pacman-static" 2>/dev/null && log_info "A copy was kept: $STATE_DIR/pacman-static"
    return 1
}

fix_NO_SERVERS() {
    refresh_mirrors && { sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"; return 0; }
    [[ $DISTRO_ID == arch ]] || { log_warning "Add a working Server line to /etc/pacman.d/mirrorlist by hand"; return 1; }
    local ml=/etc/pacman.d/mirrorlist
    sudo cp -a "$ml" "$ml.smart-update.bak" 2>/dev/null
    { printf '%s\n' 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch'; cat "$ml" 2>/dev/null; } >"$TMP/mirrorlist.geo"
    sudo install -m644 "$TMP/mirrorlist.geo" "$ml" || return 1
    log_fix "Added Arch's worldwide mirror (geo.mirror.pkgbuild.com) at the top of $ml (backup: $ml.smart-update.bak)"
    sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"
    return 0
}

helper_works() { [[ -z $1 || $1 == none || $1 == pamac ]] && return 0; "$1" --version &>/dev/null; }

fix_AUR_HELPER_BROKEN() {
    local h=${HELPER:-none} v saved=$ATTEMPT_LOG
    [[ $h == none ]] && h=$(find_aur_helper)
    [[ $h == paru || $h == yay ]] || { log_warning "Rebuild your AUR helper by hand"; return 1; }
    for v in "$h-bin" "$h-git" "$h"; do pacman -Qq "$v" &>/dev/null && break; done
    MAKEPKG_FORCE=1
    for BOOT_PKG in "$v" "$h"; do   # the installed variant first; if a prebuilt one is still too old, compile it
        log_fix "Rebuilding $BOOT_PKG against the current pacman"
        ATTEMPT_LOG="$TMP/helper-rebuild-$BOOT_PKG.log"; : >"$ATTEMPT_LOG"
        runner_makepkg
        helper_works "$h" && break
        [[ $BOOT_PKG == "$h" ]] && break
    done
    MAKEPKG_FORCE="" ATTEMPT_LOG=$saved
    helper_works "$h" && { log_success "$h works again"; return 0; }
    return 1
}

fix_AUR_DEP_MISSING() {
    local p added=1
    for p in $(parse_wanted_by); do
        pacman -Qq "$p" &>/dev/null || continue          # only installed packages can be skipped
        [[ " ${AUR_IGNORE[*]} " == *" $p "* ]] && continue
        AUR_IGNORE+=("$p"); added=0
        log_fix "Skipping '$p' this run: a dependency of it no longer exists (https://aur.archlinux.org/packages/$p#comments)"
    done
    return $added
}

fix_AUR_TOOLCHAIN() {
    log_fix "Installing the build tools (base-devel, debugedit)"
    run_guarded install sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -S --needed --noconfirm base-devel debugedit 2>&1 | tee -a "$LOG_FILE"
    return 0
}

find_rebuilds() {  # AUR/foreign packages broken by library or interpreter updates -> REBUILD_LIST ("pkg|reason")
    REBUILD_LIST=()
    local -A why=()
    local foreign p f d cur out repo
    foreign=$(pacman -Qmq 2>/dev/null)
    if have checkrebuild; then
        while read -r repo p; do [[ $repo == foreign ]] && why[$p]="linked to a library that was replaced"; done < <(checkrebuild 2>/dev/null)
    else
        for p in $foreign; do
            while IFS= read -r f; do
                [[ -f $f && ! -L $f ]] || continue
                [[ $(head -c4 "$f" 2>/dev/null) == $'\x7fELF' ]] || continue
                out=$(LC_ALL=C ldd "$f" 2>/dev/null | awk '/not found/ {print $1}' | sort -u | head -3 | tr '\n' ' ')
                [[ -n $out ]] && { why[$p]="needs ${out% } (no longer installed)"; break; }
            done < <(pacman -Qlq "$p" 2>/dev/null | grep -E '^/usr/(bin/[^/]+|lib/[^/]+\.so[^/]*)$' | head -150)
        done
    fi
    # modules installed for an old Python/Perl are invisible to the new interpreter
    cur=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)
    for d in /usr/lib/python3.*/; do
        d=${d%/}; [[ -n $cur && $d != "/usr/lib/python$cur" ]] || continue
        for p in $(pacman -Qqo "$d" 2>/dev/null); do
            grep -qx -- "$p" <<<"$foreign" && why[$p]="${why[$p]:+${why[$p]}; }Python modules for ${d##*/} (now python$cur)"
        done
    done
    cur=$(perl -e 'printf "%vd", $^V' 2>/dev/null); cur=${cur%.*}
    for d in /usr/lib/perl5/5.*/; do
        d=${d%/}; [[ -n $cur && ${d##*/} != "$cur" ]] || continue
        for p in $(pacman -Qqo "$d" 2>/dev/null); do
            grep -qx -- "$p" <<<"$foreign" && why[$p]="${why[$p]:+${why[$p]}; }Perl modules for perl ${d##*/} (now $cur)"
        done
    done
    for p in "${!why[@]}"; do REBUILD_LIST+=("$p|${why[$p]}"); done
    (( ${#REBUILD_LIST[@]} )) && mapfile -t REBUILD_LIST < <(printf '%s\n' "${REBUILD_LIST[@]}" | sort)
    return 0
}

rebuild_pending() {  # rebuild the AUR packages in REINSTALL_AFTER (removed to unblock an update, or broken by one)
    (( ${#REINSTALL_AFTER[@]} )) || return 0
    if [[ $DRY_RUN == true ]]; then log_info "[DRY-RUN] would rebuild: ${REINSTALL_AFTER[*]}"; return 0; fi
    HELPER=$(find_aur_helper)
    if [[ $HELPER == none || $HELPER == pamac ]]; then
        log_warning "Rebuild these by hand (no paru/yay): ${REINSTALL_AFTER[*]}"
        UNRESOLVED+=("Rebuild needed: ${REINSTALL_AFTER[*]}"); return 1
    fi
    helper_works "$HELPER" || { ISSUES=(AUR_HELPER_BROKEN); CLEAN_LOG=/dev/null; report_diagnosis; apply_fixes || return 1; }
    log_step "Rebuilding AUR packages: ${REINSTALL_AFTER[*]}"
    if run_step "AUR rebuild" aur runner_aur_reinstall; then REINSTALL_AFTER=(); return 0; fi
    UNRESOLVED+=("Rebuild needed: ${REINSTALL_AFTER[*]}")
    return 1
}

fix_PARTIAL() {
    local e p todo=()
    if [[ -n $(pacman -Qu 2>/dev/null | head -1) ]]; then
        log_fix "Finishing the full upgrade first (repo programs get their matching libraries)"
        run_guarded install sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syu --noconfirm 2>&1 | tee -a "$LOG_FILE"
    fi
    find_rebuilds
    for e in "${REBUILD_LIST[@]}"; do p=${e%%|*}; [[ $p == *-bin ]] || todo+=("$p"); done
    (( ${#todo[@]} )) || return 0
    log_fix "AUR packages to rebuild against the new libraries: ${todo[*]}"
    REINSTALL_AFTER+=("${todo[@]}")
    rebuild_pending
}

check_rebuilds() {  # after an update: AUR packages that a library / Python / Perl update broke
    log_step "AUR packages that need a rebuild after this update"
    find_rebuilds
    if (( ${#REBUILD_LIST[@]} == 0 )); then log_success "None — every AUR package still finds its libraries"; return 0; fi
    local e p r todo=() bin=()
    for e in "${REBUILD_LIST[@]}"; do
        p=${e%%|*} r=${e#*|}
        log_warning "$p: $r"
        if [[ $p == *-bin ]]; then bin+=("$p"); else todo+=("$p"); fi
    done
    (( ${#bin[@]} )) && log_info "Prebuilt packages (${bin[*]}) cannot be fixed by rebuilding — wait for their AUR update (or check the AUR comments)"
    (( ${#todo[@]} )) || return 0
    [[ $FIX_MODE == off ]] && { log_info "Rebuild with: paru -S --rebuild ${todo[*]}"; return 0; }
    if [[ $DRY_RUN == true ]]; then log_info "[DRY-RUN] would rebuild: ${todo[*]}"; return 0; fi
    if [[ $FIX_MODE == auto ]] || ui_ask "Rebuild ${#todo[@]} AUR package(s) so they work with the new libraries: ${todo[*]}?" y; then
        REINSTALL_AFTER+=("${todo[@]}")
        rebuild_pending
    fi
}

check_boot_images() {  # a kernel whose initramfs is missing or older than the kernel will not boot
    have mkinitcpio || return 0
    if ! [[ -r /boot && -x /boot ]] && ! sudo -n true 2>/dev/null; then return 0; fi
    bt() { if [[ -r /boot && -x /boot ]]; then test "$@"; else sudo -n test "$@" 2>/dev/null; fi; }
    local k preset img kimg stale=()
    for k in $(installed_kernels); do
        preset=/etc/mkinitcpio.d/$k.preset; [[ -r $preset ]] || continue
        img=$(sed -nE 's/^[[:space:]]*default_image="?([^"]+)"?.*/\1/p' "$preset" | head -1)
        kimg=$(sed -nE 's/^[[:space:]]*ALL_kver="?([^"]+)"?.*/\1/p' "$preset" | head -1)
        [[ -n $img ]] || continue          # unified kernel images (default_uki) are not checked
        if ! bt -e "$img" || { [[ -n $kimg ]] && bt "$kimg" -nt "$img"; }; then stale+=("$k"); fi
    done
    (( ${#stale[@]} )) || return 0
    log_warning "Boot image missing or older than its kernel: ${stale[*]} — the system may not boot like this"
    [[ $DRY_RUN == true ]] && return 0
    ISSUES=(HOOK); CLEAN_LOG=/dev/null
    apply_fixes || UNRESOLVED+=("Boot image for ${stale[*]} is missing or outdated: run sudo mkinitcpio -P")
}

check_stale_system() {  # before updating: extra care for a system that was not updated for a long time
    local days last f
    last=$(last_full_upgrade_epoch)
    (( last > 0 )) || return 0
    days=$(( ( $(date +%s) - last ) / 86400 ))
    (( days >= STALE_DAYS )) || return 0
    log_warning "The last full upgrade was $days days ago — this run takes the extra steps a long-outdated system needs:"
    detail <<EOF
• a fresh mirror list (old lists point to dead or out-of-date mirrors)
• repositories Arch has removed are cleaned out of pacman.conf
• keyrings are updated before anything else (new packager keys); missing keys are looked up by email
• Arch news since then is shown below: some updates need a manual step
• afterwards: AUR packages broken by library, Python or Perl updates are found and rebuilt
EOF
    FORCE_MIRRORS=true
    for f in /etc/pacman.conf.pacnew /etc/pacman.d/mirrorlist.pacnew; do
        [[ -e $f ]] && log_info "$f exists: newer defaults from a pacman update that were never merged (sudo pacdiff)"
    done
    (( days > 365 )) && log_info "More than a year: expect many changes. If something fails, the diagnosis below explains it — nothing is installed until downloads and checks pass."
    return 0
}

key_present() { gpg --batch --list-keys "$1" >/dev/null 2>&1; }

fetch_pgp_key() {  # fetch_pgp_key KEYID -> 0 when the key is in the user's keyring afterwards
    local k=$1 u d src extra=()
    key_present "$k" && return 0
    # 1) many PKGBUILDs ship the key next to them
    for d in "$HOME"/.cache/paru/clone/*/keys/pgp "$HOME"/.cache/yay/*/keys/pgp; do
        for src in "$d"/*.asc; do gpg --batch --import "$src" >/dev/null 2>&1; done
    done
    key_present "$k" && { log_success "Key $k imported from the package's own keys/pgp folder"; return 0; }
    # 2) keyservers over plain HTTPS with curl: works with DNS-over-HTTPS and a proxy, unlike dirmngr
    [[ -n $PAC_DOH ]] && extra+=(--doh-url "$PAC_DOH")
    [[ -n ${PAC_PROXY:-${RESCUE_PROXY:-}} ]] && extra+=(-x "${PAC_PROXY:-$RESCUE_PROXY}")
    for u in "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$k" \
             "https://keys.openpgp.org/vks/v1/by-keyid/${k^^}" \
             "https://pgp.mit.edu/pks/lookup?op=get&options=mr&search=0x$k"; do
        (( ${#k} == 40 )) && [[ $u == *keys.openpgp.org* ]] && u="https://keys.openpgp.org/vks/v1/by-fingerprint/${k^^}"
        curl -fsSL --http1.1 --max-time 40 "${extra[@]}" "$u" 2>/dev/null | gpg --batch --import >/dev/null 2>&1
        key_present "$k" && { log_success "Key $k imported from ${u#https://}"; u=${u#https://}; _log "[KEY] $k from ${u%%/*}"; return 0; }
    done
    # 3) gpg's own keyserver access (hkps on port 443)
    for u in hkps://keyserver.ubuntu.com hkps://keys.openpgp.org; do
        timeout 40 gpg --batch --keyserver "$u" --recv-keys "$k" >/dev/null 2>&1
        key_present "$k" && { log_success "Key $k imported from $u"; return 0; }
    done
    return 1
}

fix_AUR_PGP() {  # import every missing key, and VERIFY it arrived; if not, skip the package this run
    local k ok=1 missing=0 p
    for k in $(parse_pgp_keys); do
        log_fix "Fetching the upstream signing key $k (package folder, 3 keyservers over HTTPS, then gpg)"
        if fetch_pgp_key "$k"; then ok=0
        else
            missing=1
            log_warning "Key $k could not be fetched from any source (keyservers blocked or the key is not published there)"
        fi
    done
    if (( missing )); then
        for p in $(parse_source_fail_pkgs); do
            [[ " ${AUR_IGNORE[*]} " == *" $p "* ]] && continue
            AUR_IGNORE+=("$p"); ok=0
            log_fix "Skipping '$p' this run: its signing key is unavailable. Import it later with: gpg --recv-keys $(parse_pgp_keys | head -1)  (or from https://aur.archlinux.org/packages/$p — the PKGBUILD lists validpgpkeys)"
        done
    fi
    return $ok
}

fix_AUR_PKGBUILD() {  # first time: fresh copy of the PKGBUILD; second time: skip the package this run
    local p acted=1
    for p in $(parse_source_fail_pkgs); do
        if (( ${FIX_COUNT[AUR_PKGBUILD]:-0} == 0 )); then
            log_fix "Discarding the cached build folder of $p so the helper fetches the PKGBUILD fresh"
            rm -rf -- "$HOME/.cache/paru/clone/$p" "$HOME/.cache/yay/$p"; acted=0
        elif [[ " ${AUR_IGNORE[*]} " != *" $p "* ]]; then
            AUR_IGNORE+=("$p"); acted=0
            log_fix "Skipping '$p' this run: its PKGBUILD is still invalid (see https://aur.archlinux.org/packages/$p#comments)"
        fi
    done
    return $acted
}

fix_AUR_BUILD() {
    local p d cleaned=0
    for p in $(parse_failed_aur_pkgs); do
        for d in "$HOME"/.cache/paru/clone/*/ "$HOME"/.cache/yay/*/ "$HOME"/.cache/pikaur/build/*/; do
            local base; base=$(basename "$d")
            [[ $p == "$base" || $p == "$base"-[0-9]* ]] || continue
            if [[ -d $d/.git ]]; then git -C "$d" clean -fdxq 2>/dev/null; git -C "$d" reset -q --hard 2>/dev/null
            else rm -rf -- "${d}src" "${d}pkg"; fi
            log_fix "Cleaned build directory $d"; cleaned=1
        done
    done
    (( cleaned ))
}

fix_OOM() { export MAKEFLAGS="-j$(( $(nproc) > 2 ? $(nproc) / 2 : 1 ))"; log_fix "Retrying build with MAKEFLAGS=$MAKEFLAGS"; return 0; }

fix_DKMS() {
    local k need=()
    for k in $(installed_kernels); do pacman -Q "$k-headers" &>/dev/null || need+=("$k-headers"); done
    if (( ${#need[@]} )); then
        log_fix "Installing missing kernel headers: ${need[*]}"
        run_guarded install sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -S --needed --noconfirm "${need[@]}" 2>&1 | tee -a "$LOG_FILE"
        return 0
    fi
    log_warning "Headers are present; the module itself probably does not support the new kernel yet. Keep a fallback kernel (linux-lts) and check the module's AUR page."
    return 1
}

fix_HOOK() {
    if have mkinitcpio; then
        log_fix "Regenerating initramfs images (mkinitcpio -P)"
        run_guarded initramfs sudo mkinitcpio -P 2>&1 | grep -E 'ERROR|WARNING: Possibly missing|Image generation' | tee -a "$LOG_FILE"
        return 0
    fi
    return 1
}

fix_FLATPAK() {
    log_fix "Repairing Flatpak installations"
    flatpak repair --user 2>&1 | tail -2
    sudo flatpak repair 2>&1 | tail -2
    return 0
}

fix_UNKNOWN() {
    case $DIAG_DOMAIN in
        snap)    log_fix "Generic recovery: restarting snapd (when idle) and retrying"; snapd_restart_idle; return 0 ;;
        flatpak) log_fix "Generic recovery: flatpak repair and fresh metadata, then retry"
                 flatpak repair --user &>/dev/null; sudo flatpak repair --system &>/dev/null
                 flatpak update --appstream --noninteractive &>/dev/null; return 0 ;;
        pacman)  ;;
        *)       return 1 ;;
    esac
    log_fix "Generic recovery: forcing a fresh database download and retrying"
    sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Syy --noconfirm 2>&1 | tee -a "$LOG_FILE"
    return 0
}

# ======================================================================
# SNAP — store routes, snapd health, running apps, changes in progress
# ======================================================================
# snapd talks to ONE host for everything: api.snapcraft.io (downloads are then redirected to
# *.cdn.snapcraftcontent.com). Canonical serves that name from several front ends; on filtered
# networks some of them are cut at the TLS handshake ("Post .../v2/snaps/refresh: EOF") while
# others answer normally. The fix probes every known front end and, for this run only, pins
# one that works in /etc/hosts — or, failing that, routes snapd through a working local proxy.
SNAP_API=api.snapcraft.io
SNAP_ROUTE_TAG='# smart-update: temporary Snap Store route'
SNAP_KNOWN_IPS="185.125.188.54 185.125.188.55 185.125.188.59 185.125.188.58 185.125.188.61 185.125.190.105 185.125.190.106 185.125.190.21 185.125.190.22"
SNAP_HOLD=()                 # snaps not refreshed this run because their apps are running

snap_api_probe() {  # snap_api_probe IP|"" [curl args...] -> HTTP code of the refresh endpoint snapd uses (000 = no answer)
    local ip=$1 r=(); shift
    [[ -n $ip ]] && r=(--resolve "$SNAP_API:443:$ip")
    # an empty refresh request: 400 means the store read it (some front ends rate-limit search, not refresh)
    curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "${r[@]}" "$@" -X POST -H 'Snap-Device-Series: 16' \
        -H 'Content-Type: application/json' -d '{"context":[],"actions":[]}' "https://$SNAP_API/v2/snaps/refresh" 2>/dev/null
}
snap_api_ok() { [[ $(snap_api_probe "$@") =~ ^(200|400)$ ]]; }

snap_cdn_ok() {  # snap_cdn_ok IP|"" [curl args...] — can a snap file really be downloaded over this route?
    local ip=$1 r=() url; shift
    [[ -n $ip ]] && r=(--resolve "$SNAP_API:443:$ip")
    url=$(curl -sS --max-time 12 "${r[@]}" "$@" -H 'Snap-Device-Series: 16' \
        "https://$SNAP_API/v2/snaps/info/core?fields=download" 2>/dev/null | grep -oE '"url":"[^"]+"' | head -1 | cut -d'"' -f4)
    [[ -n $url ]] || return 1
    [[ $(curl -sS -o /dev/null --max-time 20 -r 0-1023 -L "${r[@]}" "$@" -w '%{http_code}' "$url" 2>/dev/null) =~ ^20[06]$ ]]
}

snap_official_ips() {  # the addresses the store's name really has (DNS-over-HTTPS: /etc/hosts and a kept route don't count)
    local ips
    ips=$({ curl -sS --max-time 8 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=$SNAP_API&type=A" 2>/dev/null
            curl -sS --max-time 8 "https://8.8.8.8/resolve?name=$SNAP_API&type=A" 2>/dev/null
          } | grep -oE '"data": ?"[0-9.]+"' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | awk '!s[$0]++')
    [[ -n $ips ]] || ips="185.125.190.105 185.125.190.106"   # DoH unreachable: the store's long-standing addresses
    printf '%s\n' $ips
}

snap_store_candidates() {  # every address that may serve api.snapcraft.io: DoH answers, related hosts, known front ends
    snap_official_ips
    local h; for h in $SNAP_API dashboard.snapcraft.io search.apps.ubuntu.com; do
        timeout 5 getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}'
    done
    printf '%s\n' $SNAP_KNOWN_IPS
}

snap_hosts_entries() {  # lines in /etc/hosts that pin api.snapcraft.io and were NOT added by this script
    grep -nE "^[[:space:]]*[0-9a-fA-F.:]+[[:space:]]+([^#]*[[:space:]])?${SNAP_API//./\\.}([[:space:]]|$)" /etc/hosts 2>/dev/null | grep -vF "$SNAP_ROUTE_TAG"
}

snapd_idle() { ! snap changes 2>/dev/null | awk 'NR>1 && ($2=="Doing" || $2=="Undoing" || $2=="Wait") {f=1} END {exit !f}'; }
snapd_restart_idle() {  # restart snapd only when it is not in the middle of a change
    snapd_idle || return 0
    sudo systemctl restart snapd.service 2>/dev/null
    timeout 90 sudo snap wait system seed.loaded &>/dev/null
    return 0
}

snap_store_route() {  # -> "direct" | "pin IP" | "proxy URL"; 1 = no working route
    snap_api_ok "" && snap_cdn_ok "" && { echo direct; return 0; }
    local ip p
    for ip in $(snap_store_candidates | awk '!seen[$0]++'); do
        snap_api_ok "$ip" && snap_cdn_ok "$ip" && { echo "pin $ip"; return 0; }
    done
    for p in $(local_proxies); do
        [[ $p == http://* || $p == https://* ]] || continue   # snapd's proxy setting takes HTTP proxies
        snap_api_ok "" -x "$p" && snap_cdn_ok "" -x "$p" && { echo "proxy $p"; return 0; }
    done
    return 1
}

snap_adopt_kept() {  # a route kept from an earlier run becomes this run's route (so a new one replaces it, never adds to it)
    local f="$STATE_DIR/snap_route_kept"
    [[ -f $f ]] || return 0
    mv -f "$f" "$TMP/snap_route"; [[ -e $f.proxy_prev ]] && mv -f "$f.proxy_prev" "$TMP/snap_proxy_prev"
    return 0
}

snap_route_pin() {  # snap_route_pin IP — /etc/hosts entry for api.snapcraft.io (removed after the Snap step)
    snap_adopt_kept; snap_route_restore quiet
    [[ -e /etc/hosts.smart-update.bak ]] || sudo cp -a /etc/hosts /etc/hosts.smart-update.bak
    printf '%s %s %s\n' "$1" "$SNAP_API" "$SNAP_ROUTE_TAG" | sudo tee -a /etc/hosts >/dev/null || return 1
    echo "pin $1" >"$TMP/snap_route"
    snapd_restart_idle
}

snap_route_proxy() {  # snap_route_proxy URL — snapd uses the proxy (previous setting restored after the Snap step)
    snap_adopt_kept; snap_route_restore quiet
    printf '%s\n%s\n' "$(snap get system proxy.http 2>/dev/null)" "$(snap get system proxy.https 2>/dev/null)" >"$TMP/snap_proxy_prev"
    sudo snap set system proxy.http="$1" proxy.https="$1" || return 1
    echo "proxy $1" >"$TMP/snap_route"
}

snap_route_restore() {  # undo the temporary route; "quiet" = no message, "exit" = never ask for a password
    [[ -n $TMP && -e $TMP/snap_route ]] || return 0
    if [[ ${SNAP_KEEP_ROUTE:-false} == true && $1 != quiet ]]; then
        log_info "Keeping the Snap Store route ($(cat "$TMP/snap_route")) so snapd's background refreshes work too (SNAP_KEEP_ROUTE=true); it is removed by itself once the usual servers answer again"
        mkdir -p "$STATE_DIR" && mv -f "$TMP/snap_route" "$STATE_DIR/snap_route_kept"
        [[ -e $TMP/snap_proxy_prev ]] && mv -f "$TMP/snap_proxy_prev" "$STATE_DIR/snap_route_kept.proxy_prev"
        return 0
    fi
    local s=(sudo); [[ $1 == exit ]] && s=(sudo -n)
    if grep -qF "$SNAP_ROUTE_TAG" /etc/hosts 2>/dev/null; then
        "${s[@]}" sed -i "\\|${SNAP_ROUTE_TAG}\$|d" /etc/hosts 2>/dev/null
    fi
    if [[ -e $TMP/snap_proxy_prev ]]; then
        local ph pp; { read -r ph; read -r pp; } <"$TMP/snap_proxy_prev"
        if [[ -z $ph && -z $pp ]]; then "${s[@]}" snap unset system proxy.http proxy.https 2>/dev/null
        else "${s[@]}" snap set system proxy.http="$ph" proxy.https="$pp" 2>/dev/null; fi
        rm -f "$TMP/snap_proxy_prev"
    fi
    [[ $1 == quiet || $1 == exit ]] || log_info "Removed the temporary Snap Store route (snapd is back to its normal connection)"
    rm -f "$TMP/snap_route"
}

snap_kept_recheck() {  # start of every Snap step: drop a kept route once it is not needed (or no longer works)
    local f="$STATE_DIR/snap_route_kept" r ip c usual=1
    # a tagged /etc/hosts line from an older run without the state file counts as kept too
    if [[ ! -f $f ]] && grep -qF "$SNAP_ROUTE_TAG" /etc/hosts 2>/dev/null; then
        mkdir -p "$STATE_DIR"; echo "pin $(grep -F "$SNAP_ROUTE_TAG" /etc/hosts | awk 'NR==1 {print $1}')" >"$f"
    fi
    [[ -f $f ]] || return 0
    r=$(cat "$f")
    for c in $(snap_official_ips); do
        snap_api_ok "$c" && snap_cdn_ok "$c" && { usual=0; break; }
    done
    if [[ $r == pin\ * ]]; then ip=${r#pin }; else ip=""; fi
    if (( usual == 0 )); then
        log_info "The usual Snap Store servers answer again — removing the kept route ($r); search works normally again"
    elif [[ -n $ip ]] && ! { snap_api_ok "$ip" && snap_cdn_ok "$ip"; }; then
        log_info "The kept Snap Store route ($ip) stopped working — removing it; a new route is found if the refresh fails"
    else
        log_info "Keeping the Snap Store route ($r): the usual servers are still blocked"
        return 0
    fi
    mv -f "$f" "$TMP/snap_route"
    [[ -e $f.proxy_prev ]] && mv -f "$f.proxy_prev" "$TMP/snap_proxy_prev"
    snap_route_restore quiet
    [[ -n $ip ]] && snapd_restart_idle
    return 0
}

fix_SNAP_STORE() {
    local e n ip
    # a hand-made /etc/hosts entry for the store that no longer answers is the most common hidden cause
    while IFS=: read -r n e; do
        [[ -n $n ]] || continue
        ip=$(awk '{print $1}' <<<"$e")
        if ! snap_api_ok "$ip"; then
            [[ -e /etc/hosts.smart-update.bak ]] || sudo cp -a /etc/hosts /etc/hosts.smart-update.bak
            sudo sed -i "${n}s/^/# disabled by smart-update (store does not answer on $ip): /" /etc/hosts
            log_fix "Disabled the old /etc/hosts entry '$e' — the Snap Store does not answer on $ip (backup: /etc/hosts.smart-update.bak)"
        fi
    done < <(snap_hosts_entries)
    log_fix "Testing routes to the Snap Store ($SNAP_API): direct, every Canonical front end, local proxies…"
    local r; r=$(snap_store_route)
    case $r in
        direct)  log_info "The Snap Store answers directly now (the failure was a dropped connection)"
                 snapd_restart_idle; return 0 ;;
        pin\ *)  ip=${r#pin }
                 snap_route_pin "$ip" || return 1
                 log_fix "The usual Snap Store servers are blocked on this network, $ip works: routed snapd there for this run (/etc/hosts, removed afterwards)"
                 return 0 ;;
        proxy\ *) snap_route_proxy "${r#proxy }" || return 1
                 log_fix "Snap Store reachable only through the local proxy ${r#proxy }: snapd uses it for this run"
                 return 0 ;;
    esac
    log_warning "No route to the Snap Store works from this network (every front end and proxy was tried)"
    detail "Direct: $(snap_api_probe "") · DNS: $(timeout 5 getent ahostsv4 $SNAP_API | awk 'NR==1{print $1}')"
    detail "Start a VPN/proxy (it is detected automatically) or set PROXY_URL=http://… in $CONFIG_FILE, then run again"
    return 1
}

fix_SNAPD_DOWN() {
    log_fix "Starting snapd (socket, AppArmor profiles, daemon)"
    sudo systemctl enable --now snapd.socket 2>&1 | tail -2
    [[ -e /usr/lib/systemd/system/snapd.apparmor.service ]] && sudo systemctl enable --now snapd.apparmor.service 2>&1 | tail -1
    sudo systemctl restart snapd.service 2>&1 | tail -2
    timeout 120 sudo snap wait system seed.loaded &>/dev/null
    snap version &>/dev/null && systemctl is-active -q snapd.service
}

fix_SNAP_CHANGE() {
    local id st
    id=$(snap changes 2>/dev/null | awk 'NR>1 && ($2=="Doing" || $2=="Undoing" || $2=="Wait") {print $1}' | tail -1)
    [[ -n $id ]] || { log_info "The other snap change has finished"; return 0; }
    log_fix "Waiting for snap change $id ($(snap changes | awk -v i="$id" '$1==i {$1=$2=$3=$4=""; print}' | sed 's/^ *//')) to finish — up to 5 min"
    timeout 300 snap watch "$id" &>/dev/null
    st=$(snap changes 2>/dev/null | awk -v i="$id" '$1==i {print $2}')
    if [[ $st == Doing || $st == Undoing || $st == Wait ]]; then
        log_fix "Change $id is stuck — aborting it (snapd rolls it back cleanly)"
        sudo snap abort "$id" 2>&1 | tail -1
        timeout 120 snap watch "$id" &>/dev/null
    fi
    return 0
}

fix_SNAP_RUNNING() {
    local n
    mapfile -t SNAP_HOLD < <(grep -oE 'snap "[^"]+" has running apps' "$CLEAN_LOG" | cut -d'"' -f2 | sort -u)
    (( ${#SNAP_HOLD[@]} )) || return 1
    log_fix "Refreshing every other snap now; these wait until you close them: ${SNAP_HOLD[*]}"
    for n in "${SNAP_HOLD[@]}"; do detail "$n: close it, then: sudo snap refresh $n   (snapd also does it by itself once it is closed)"; done
    return 0
}

fix_SNAP_SEED() {
    log_fix "snapd is still setting itself up (seeding) — restarting it and waiting up to 3 min"
    sudo systemctl restart snapd.seeded.service snapd.service 2>/dev/null
    timeout 180 sudo snap wait system seed.loaded &>/dev/null
}

fix_SNAP_CLASSIC() {
    if [[ -L /snap ]]; then sudo ln -sfn /var/lib/snapd/snap /snap
    elif [[ -d /snap ]]; then
        [[ -z $(ls -A /snap 2>/dev/null) ]] || { log_warning "/snap is a non-empty folder; move its contents and run again"; return 1; }
        sudo rmdir /snap && sudo ln -s /var/lib/snapd/snap /snap
    else sudo ln -s /var/lib/snapd/snap /snap; fi
    log_fix "Created /snap → /var/lib/snapd/snap (classic snaps such as code, android-studio, nvim need it)"
}

fix_SNAP_MOUNT() {
    if kernel_replaced; then
        log_warning "snaps are mounted with the squashfs module of the running kernel $(uname -r), which the update removed — a REBOOT fixes this"
        [[ " ${REBOOT_SERVICES[*]} " == *" snapd "* ]] || REBOOT_SERVICES+=("snapd")
        return 1
    fi
    log_fix "Loading the squashfs and loop modules and restarting snapd"
    sudo modprobe squashfs 2>&1 | tail -1; sudo modprobe loop 2>&1 | tail -1
    sudo systemctl restart 'snap-*.mount' 2>/dev/null
    snapd_restart_idle; return 0
}

fix_SNAP_SPACE() {
    local n r freed=0
    log_fix "Freeing space used by snaps: old disabled revisions, snapd's download cache, keep 2 revisions from now on"
    while read -r n r; do
        sudo snap remove "$n" --revision="$r" &>/dev/null && { freed=$(( freed + 1 )); detail "removed $n revision $r"; }
    done < <(snap list --all 2>/dev/null | awk 'NR>1 && /disabled/ {print $1, $3}')
    sudo snap set system refresh.retain=2 2>/dev/null
    sudo find /var/lib/snapd/cache -type f -links 1 -delete 2>/dev/null
    log_info "Removed $freed old revision(s); free on /var/lib/snapd: $(free_mb /var/lib/snapd) MB"
    return 0
}

fix_SNAP_APPARMOR() {
    log_fix "Reloading snapd's AppArmor profiles"
    [[ -e /usr/lib/systemd/system/apparmor.service ]] && sudo systemctl enable --now apparmor.service 2>&1 | tail -1
    [[ -e /usr/lib/systemd/system/snapd.apparmor.service ]] && sudo systemctl enable --now snapd.apparmor.service 2>&1 | tail -1
    sudo systemctl restart snapd.apparmor.service snapd.service 2>/dev/null
    return 0
}

# ======================================================================
# FLATPAK — remotes, the system helper, space, network
# ======================================================================
fix_FLATPAK_REMOTE() {
    local scope r url
    log_fix "Repairing Flatpak remotes (re-enable, reset Flathub's address and signing key, refresh metadata)"
    for scope in --user --system; do
        local s=(); [[ $scope == --system ]] && s=(sudo)
        while read -r r; do
            [[ -n $r ]] || continue
            "${s[@]}" flatpak remote-modify "$scope" --enable "$r" 2>/dev/null
            if [[ $r == flathub ]]; then
                url=$(flatpak remotes "$scope" --columns=name,url 2>/dev/null | awk '$1=="flathub" {print $2}')
                [[ $url == https://dl.flathub.org/repo/ ]] || "${s[@]}" flatpak remote-modify "$scope" --url=https://dl.flathub.org/repo/ flathub 2>/dev/null
                if curl -fsS --max-time 20 -o "$TMP/flathub.gpg" https://dl.flathub.org/repo/flathub.gpg 2>/dev/null; then
                    "${s[@]}" flatpak remote-modify "$scope" --gpg-import="$TMP/flathub.gpg" flathub 2>/dev/null
                fi
            fi
        done < <(flatpak remotes "$scope" --columns=name 2>/dev/null)
        "${s[@]}" flatpak update "$scope" --appstream --noninteractive &>/dev/null
    done
    # no Flathub at all although Flathub apps are installed (e.g. the remote was deleted)
    if ! flatpak remotes --columns=name 2>/dev/null | grep -qx flathub && flatpak list --columns=origin 2>/dev/null | grep -qx flathub; then
        sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>&1 | tail -1
    fi
    return 0
}

fix_FLATPAK_HELPER() {
    log_fix "Restarting Flatpak's system helper and polkit"
    sudo systemctl restart polkit.service 2>/dev/null
    sudo systemctl restart flatpak-system-helper.service 2>/dev/null
    return 0
}

fix_FLATPAK_SPACE() {
    log_fix "Freeing space used by Flatpak: unused runtimes and extensions, leftover objects"
    flatpak uninstall --user --unused -y --noninteractive 2>&1 | tail -1
    sudo flatpak uninstall --system --unused -y --noninteractive 2>&1 | tail -1
    flatpak repair --user &>/dev/null; sudo flatpak repair --system &>/dev/null
    return 0
}

fix_FLATPAK_NET() {
    log_fix "Waiting for Flathub to answer (up to 60 s)…"
    local i
    for i in $(seq 1 12); do
        curl -sS -o /dev/null --max-time 8 https://dl.flathub.org/repo/summary.idx 2>/dev/null && { log_info "Flathub answers again"; return 0; }
        sleep 5
    done
    log_warning "Flathub (dl.flathub.org) does not answer from this network"
    return 1
}

# ======================================================================
# MORE PACMAN / AUR KNOWLEDGE — config, hooks, database version, gpg, busy files
# ======================================================================
fix_DB_VERSION() { log_fix "Upgrading pacman's local database format"; sudo pacman-db-upgrade 2>&1 | tail -3; }

pacman_conf_bad_lines() {  # "file|line|directive" for every 'directive not recognized' error in the log
    grep -oE "config file [^,]+, line [0-9]+: directive '[^']+' in section '[^']+' not recognized" "$CLEAN_LOG" 2>/dev/null \
        | sed -E "s/config file ([^,]+), line ([0-9]+): directive '([^']+)'.*/\1|\2|\3/" | sort -u
}

fix_PACMAN_CONF() {
    local f n d done=0
    while IFS='|' read -r f n d; do
        [[ -f $f ]] || continue
        sudo cp -a "$f" "$f.smart-update-$(date +%Y%m%d-%H%M%S).bak"
        sudo sed -i "${n}s/^/# disabled by smart-update (pacman does not know '$d'): /" "$f" && done=1
        log_fix "Commented out line $n of $f ('$d' is not a pacman option any more; backup kept next to it)"
    done < <(pacman_conf_bad_lines)
    (( done )) || { log_warning "The pacman configuration error has to be fixed by hand: $(grep -m1 -E 'config file|failed to initialize alpm' "$CLEAN_LOG")"; return 1; }
    sudo pacman-conf >/dev/null 2>&1
}

stale_hooks() {  # "hookfile|missing-exec|owner" for pacman hooks whose program no longer exists
    local d h exe
    for d in /etc/pacman.d/hooks /usr/share/libalpm/hooks $(pacman-conf HookDir 2>/dev/null); do
        for h in "$d"/*.hook; do
            [[ -f $h ]] || continue
            exe=$(awk -F'=' '/^[[:space:]]*Exec[[:space:]]*=/ {sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$h" | awk '{print $1}')
            [[ $exe == /bin/sh || $exe == /usr/bin/sh || $exe == /bin/bash || $exe == /usr/bin/bash ]] && continue
            [[ -n $exe && $exe == /* && ! -x $exe ]] && printf '%s|%s|%s\n' "$h" "$exe" "$(pacman -Qqo "$h" 2>/dev/null)"
        done
    done | awk '!seen[$0]++'
}

fix_STALE_HOOK() {
    local h exe own bk n=0
    bk="/var/lib/smart-update/removed/$(date +%Y%m%d-%H%M%S)"
    while IFS='|' read -r h exe own; do
        if [[ -n $own ]]; then
            log_fix "Hook $h (from $own) runs $exe, which is missing — reinstalling $own"
            sudo pacman "${PAC_OPTS[@]}" -S --noconfirm "$own" 2>&1 | tail -2; n=$(( n + 1 ))
        else
            sudo mkdir -p "$bk$(dirname "$h")" && sudo mv -- "$h" "$bk$h" && n=$(( n + 1 ))
            log_fix "Moved the leftover hook $h (it runs $exe, which no package provides any more) → $bk$h"
        fi
    done < <(stale_hooks)
    (( n )) || return 1
    [[ -d $bk ]] && log_info "Restore with: sudo cp -a $bk/. /"
    return 0
}

fix_GNUPG_PERMS() {
    local g=${GNUPGHOME:-$HOME/.gnupg}
    log_fix "Fixing ownership and permissions of $g"
    sudo chown -R "$(id -u):$(id -g)" "$g" && chmod 700 "$g" && find "$g" -type f -exec chmod 600 {} + 2>/dev/null
    find "$g" -mindepth 1 -type d -exec chmod 700 {} + 2>/dev/null
    gpgconf --kill gpg-agent 2>/dev/null; return 0
}

fix_GPG_AGENT() {
    log_fix "Restarting the gpg agents (yours and pacman's)"
    gpgconf --kill all 2>/dev/null
    sudo gpgconf --homedir /etc/pacman.d/gnupg --kill all 2>/dev/null
    find "${GNUPGHOME:-$HOME/.gnupg}" -maxdepth 1 -name '*.lock' -delete 2>/dev/null
    sudo find /etc/pacman.d/gnupg -maxdepth 1 -name '*.lock' -delete 2>/dev/null
    return 0
}

fix_BUSY_FILE() {
    local f
    f=$(grep -oE "[^ ']+: (Text file busy|Device or resource busy)" "$CLEAN_LOG" | head -1 | sed 's/: .*//')
    log_fix "A file was in use${f:+ ($f)}; waiting 10 s and retrying"
    [[ -n $f ]] && have fuser && sudo fuser -v "$f" 2>&1 | tail -n +2 | detail
    sleep 10; return 0
}

# ======================================================================
# BROKEN SYMLINKS — classify every dead link, repair what can be repaired
# ======================================================================
# Kinds: JAVA_TOOL / PKG_BUG / OPTDEP / OWNED (harmless, explained) and
#        JAVA_DEFAULT / REINSTALL / UNIT / RESOLV / LOCALTIME / LEFTOVER (repaired).
declare -a LINKS=()          # "kind|link|target|owner|note"
LINK_FIX_RE='^(JAVA_DEFAULT|REINSTALL|UNIT|RESOLV|LOCALTIME|LEFTOVER)$'

scan_broken_links() {  # -> broken links worth looking at, one per line
    {
        find /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /usr/local/lib /usr/lib /usr/lib32 /opt -maxdepth 3 -xtype l 2>/dev/null
        find /etc /usr/share/applications /usr/share/dbus-1 -xtype l 2>/dev/null
        find "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.config/autostart" "$HOME/.config/systemd/user" -xtype l 2>/dev/null
    } | grep -vE '^/usr/lib/modules/[^/]+/(build|source)$|^/etc/(ssl|ca-certificates)/|^/proc/' | awk '!seen[$0]++'
}

classify_link() {  # classify_link PATH -> "kind|link|target|owner|note"
    local l=$1 t r own base cand opt
    t=$(readlink "$l"); r=$(readlink -m "$l"); own=$(pacman -Qqo "$l" 2>/dev/null)
    base=$(basename "$r")
    case $l in
        /etc/resolv.conf) printf 'RESOLV|%s|%s|%s|%s\n' "$l" "$t" "${own:-}" "no DNS for programs that read resolv.conf"; return ;;
        /etc/localtime)   printf 'LOCALTIME|%s|%s|%s|%s\n' "$l" "$t" "${own:-}" "time zone file is gone"; return ;;
    esac
    if [[ $own == java-*-common || $r == /usr/lib/jvm/* ]]; then
        if [[ ! -d /usr/lib/jvm/default/ || ! -d /usr/lib/jvm/default-runtime/ ]]; then
            printf 'JAVA_DEFAULT|%s|%s|%s|%s\n' "$l" "$t" "$own" "no default Java is set"; return
        fi
        cand=$(for x in /usr/lib/jvm/*/bin/"$base"; do [[ -x $x ]] && basename "$(dirname "$(dirname "$x")")"; done | grep -vE '^default' | paste -sd, -)
        printf 'JAVA_TOOL|%s|%s|%s|%s\n' "$l" "$t" "$own" \
            "$base was removed from newer JDKs (default: $(readlink /usr/lib/jvm/default))${cand:+; installed in $cand}"
        return
    fi
    if [[ -n $own ]]; then
        if pacman -Qlq "$own" 2>/dev/null | grep -qxF "$r"; then
            printf 'REINSTALL|%s|%s|%s|%s\n' "$l" "$t" "$own" "its target is a file of $own that is missing"; return
        fi
        cand=$(pacman -Qlq "$own" 2>/dev/null | grep -E "/$base\$" | grep -vxF "$l" | head -1)
        if [[ -n $cand ]]; then
            printf 'PKG_BUG|%s|%s|%s|%s\n' "$l" "$t" "$own" "packaging bug in $own: the real file is $cand"; return
        fi
        opt=$(LC_ALL=C pacman -Qi "$own" 2>/dev/null | awk '/^Optional Deps/ {f=1} /^Required By/ {f=0} f' \
              | sed -E 's/^Optional Deps *: *//; s/^ +//' | awk -F: '{print $1}' | awk '{print $1}' | grep -v '^None$' \
              | while read -r x; do b=${x//[^a-zA-Z0-9]/}; [[ -n $b && ${base//[^a-zA-Z0-9]/} == *"$b"* ]] && echo "$x"; done | head -1)
        if [[ -n $opt ]]; then
            printf 'OPTDEP|%s|%s|%s|%s\n' "$l" "$t" "$own" "comes from the optional dependency $opt (not installed): sudo pacman -S --asdeps $opt"; return
        fi
        printf 'OWNED|%s|%s|%s|%s\n' "$l" "$t" "$own" "points to a file no installed package has (a feature of $own that needs something else)"
        return
    fi
    if [[ $l =~ ^(/etc/systemd/(system|user)|$HOME/\.config/systemd/user)/ ]]; then
        local u=${l##*/} stem rep=""
        stem=${u%.*}; stem=${stem%@}
        rep=$(find /usr/lib/systemd/system /usr/lib/systemd/user /etc/systemd/system -maxdepth 1 -type f -name "${stem}*.${u##*.}" 2>/dev/null | head -1)
        printf 'UNIT|%s|%s||%s\n' "$l" "$t" \
            "enables $u, which no longer exists${rep:+ (now: $(basename "$rep"), $(systemctl is-enabled "$(basename "$rep")" 2>/dev/null || echo disabled))}"
        return
    fi
    printf 'LEFTOVER|%s|%s||%s\n' "$l" "$t" "not owned by any package — left behind by a removed program or a manual install"
}

collect_links() { LINKS=(); local l; while read -r l; do [[ -n $l ]] && LINKS+=("$(classify_link "$l")"); done < <(scan_broken_links); }

fix_SYMLINKS() {
    local e k l t own note bk n=0 reinstall=() units=0
    bk="/var/lib/smart-update/removed/$(date +%Y%m%d-%H%M%S)"
    for e in "${LINKS[@]}"; do
        IFS='|' read -r k l t own note <<<"$e"
        case $k in
            JAVA_DEFAULT) log_fix "Setting a valid default Java (archlinux-java fix)"; sudo archlinux-java fix 2>&1 | tail -1; n=$(( n + 1 )) ;;
            REINSTALL) [[ " ${reinstall[*]} " == *" $own "* ]] || reinstall+=("$own") ;;
            UNIT|LEFTOVER)
                if [[ $l == "$HOME"/* ]]; then
                    mkdir -p "$STATE_DIR/removed-links$(dirname "${l#"$HOME"}")" && mv -- "$l" "$STATE_DIR/removed-links${l#"$HOME"}" \
                        && { log_fix "Moved dead link ${l/#$HOME/\~} → ${STATE_DIR/#$HOME/\~}/removed-links/"; n=$(( n + 1 )); }
                else
                    sudo mkdir -p "$bk$(dirname "$l")" && sudo mv -- "$l" "$bk$l" && { log_fix "Moved dead link $l → $bk$l"; n=$(( n + 1 )); }
                fi
                [[ $k == UNIT ]] && units=1 ;;
            RESOLV)
                if [[ $t == */systemd/resolve/* ]]; then
                    log_fix "/etc/resolv.conf points to systemd-resolved, which is not running — starting it"
                    sudo systemctl enable --now systemd-resolved.service 2>&1 | tail -1
                    [[ -e /etc/resolv.conf ]] && n=$(( n + 1 ))
                else
                    log_warning "/etc/resolv.conf points to $t, which is missing — the program that writes it (NetworkManager, resolvconf, a VPN) is not running"
                fi ;;
            LOCALTIME)
                log_fix "Reinstalling tzdata (the time zone file $t is missing)"
                sudo pacman "${PAC_OPTS[@]}" -S --noconfirm tzdata 2>&1 | tail -1
                if [[ -e /etc/localtime ]]; then n=$(( n + 1 ))
                else log_warning "Time zone '${t#*/zoneinfo/}' does not exist any more (renamed): pick yours with  timedatectl list-timezones  then  sudo timedatectl set-timezone <Zone>"; fi ;;
        esac
    done
    if (( ${#reinstall[@]} )); then
        log_fix "Reinstalling ${reinstall[*]} (their own files are missing)"
        sudo pacman "${PAC_OPTS[@]}" -S --noconfirm "${reinstall[@]}" 2>&1 | tail -2 && n=$(( n + ${#reinstall[@]} ))
    fi
    if (( units )); then
        sudo systemctl daemon-reload 2>/dev/null; systemctl --user daemon-reload 2>/dev/null
    fi
    [[ -d $bk ]] && log_info "Restore moved links with: sudo cp -a $bk/. /"
    (( n > 0 ))
}

check_symlinks() {  # post-update: report every dead link by kind and repair the repairable ones
    log_step "Broken symlinks"
    collect_links
    (( ${#LINKS[@]} )) || { log_success "None"; return 0; }
    local e k l t own note fixable=0 harmless=0
    for e in "${LINKS[@]}"; do
        IFS='|' read -r k l t own note <<<"$e"
        if [[ $k =~ $LINK_FIX_RE ]]; then fixable=$(( fixable + 1 )); else harmless=$(( harmless + 1 )); fi
    done
    (( fixable )) && log_warning "$fixable broken symlink(s) can be repaired:"
    for e in "${LINKS[@]}"; do
        IFS='|' read -r k l t own note <<<"$e"
        [[ $k =~ $LINK_FIX_RE ]] && printf '%s -> %s  — %s\n' "$l" "$t" "$note"
    done | detail
    if (( harmless )); then
        log_info "$harmless broken symlink(s) are harmless (nothing uses them, or they belong to an optional feature):"
        for e in "${LINKS[@]}"; do
            IFS='|' read -r k l t own note <<<"$e"
            [[ $k =~ $LINK_FIX_RE ]] || printf '%s  — %s\n' "$l" "$note"
        done | awk 'NR <= 15 {print} END {if (NR > 15) print "… and " NR - 15 " more"}' | detail
    fi
    if (( fixable )) && [[ $DRY_RUN == false ]]; then
        local saved_issues=("${ISSUES[@]}")
        ISSUES=(SYMLINKS); ISSUES_SEEN+=(SYMLINKS); CLEAN_LOG=/dev/null
        apply_fixes || UNRESOLVED+=("Broken symlinks: $fixable not repaired (see above)")
        ISSUES=("${saved_issues[@]}")
    fi
}

# ======================================================================
# BLOCKED / FILTERED DOWNLOADS: per-package rescue, safe hold-back
# ======================================================================
# When the same package files fail on many mirrors while others download, something between
# the user and the mirrors filters or throttles them (ISP/DPI, censorship, a VPN dropping long
# transfers). Each blocked file is fetched straight into the pacman cache with a ladder of
# methods; the bytes are identical on every mirror, so a partial download is resumed across
# mirrors and methods. pacman still verifies every package against the signature in its
# database before installing, so the source and transport do not matter for safety.
NEVER_HOLD_RE='^(glibc|lib32-glibc|gcc-libs|lib32-gcc-libs|systemd|systemd-libs|systemd-sysvcompat|pacman|pacman-mirrorlist|archlinux-keyring|filesystem|bash|coreutils|openssl|lib32-openssl|ca-certificates|ca-certificates-mozilla|ca-certificates-utils|libxcrypt|pam|util-linux|util-linux-libs|zlib|xz|zstd|libarchive|curl|libcurl-gnutls|gnupg|gpgme|sudo|shadow|mkinitcpio|dracut|grub|linux-api-headers)$'
DOH_URLS="https://1.1.1.1/dns-query https://9.9.9.9/dns-query https://8.8.8.8/dns-query https://149.112.112.112/dns-query"
KNOWN_PROXY_PORTS="10808 10809 1080 2080 2081 7890 7891 7897 8080 8118 8888 8889 9050 9150 12334 20170 20171 20172 1081 3128"

classify_dl_error() {  # pacman/curl error text -> short class
    case ${1,,} in
        *"resolving timed out"*|*"could not resolve"*|*"resolve host"*|*"name resolution"*) echo dns ;;
        *http/2*|*protocol_error*|*"reset by peer"*|*"recv failure"*|*ssl*|*tls*|*"transfer closed"*|*"empty reply"*) echo reset ;;
        *"connection timed out"*|*"failed to connect"*|*"connection refused"*|*"no route"*|*"network is unreachable"*) echo connect ;;
        *"too slow"*) echo stall ;;
        *"error: 404"*) echo missing ;;
        *"error: 403"*|*"error: 451"*) echo forbidden ;;
        *"error: 5"[0-9][0-9]*) echo server ;;
        *) echo other ;;
    esac
}

dl_failures() {  # "file|host|class" for every failed package download in $CLEAN_LOG
    sed -nE "s/.*failed retrieving file '([^']+)' from ([^ ]+) : (.*)$/\1|\2|\3/p" "$CLEAN_LOG" 2>/dev/null \
        | while IFS='|' read -r f h e; do [[ $f == *.pkg.tar* ]] && printf '%s|%s|%s\n' "${f%.sig}" "$h" "$(classify_dl_error "$e")"; done
}

blocked_files() {  # files that failed and are still not in the cache (pacman often gets a file on the 5th mirror)
    local f; for f in $(dl_failures | cut -d'|' -f1 | sort -u); do [[ -e ${CACHE_DIR:-/nonexistent}/$f ]] || echo "$f"; done
}

dl_failure_summary() {  # human-readable analysis of the failures (for details and the report)
    local t; t=$(dl_failures); [[ -n $t ]] || return 0
    local nf nh; nf=$(cut -d'|' -f1 <<<"$t" | sort -u | wc -l); nh=$(cut -d'|' -f2 <<<"$t" | sort -u | wc -l)
    echo "$nf package file(s) failed on $nh different mirror(s). Errors by type:"
    cut -d'|' -f3 <<<"$t" | sort | uniq -c | sort -rn | awk '{
        d["reset"]="connection cut mid-transfer (HTTP/2 reset, TLS/recv failure) - typical of DPI filtering";
        d["connect"]="could not connect (timeout/refused) - blocked IP or dead route";
        d["dns"]="name lookup timed out - DNS filtered, poisoned or down";
        d["stall"]="transfer started but stalled (<1 B/s) - throttling";
        d["forbidden"]="HTTP 403/451 - refused by a filter or the server";
        d["missing"]="HTTP 404 - mirror is outdated";
        d["server"]="HTTP 5xx - mirror is broken"; d["other"]="other";
        printf "   %4d x %-9s %s\n", $1, $2, d[$2] }'
    echo "Per file:"
    cut -d'|' -f1 <<<"$t" | sort -u | while read -r f; do
        printf '   %s: %s\n' "$f" "$(grep -F "$f|" <<<"$t" | cut -d'|' -f2,3 | tr '\n' ' ' | sed 's/|/=/g')"
    done
}

pending_file_map() {  # "name|base|repo|file|fullsize|sha256" for every pending package (cached for the run)
    local out="$TMP/pending_files" n b r f s h p
    if [[ ! -s $out ]]; then
        # %s is what is LEFT to download: libalpm subtracts the size of a .part file already in the cache.
        # Add it back, or a complete rescue download looks "too big" and is rejected.
        LC_ALL=C pacman "${PAC_OPTS[@]}" -Sup --print-format '%n|%e|%r|%f|%s|%h' 2>/dev/null | grep -E '\|' \
            | while IFS='|' read -r n b r f s h; do
                p=$(stat -c %s "$CACHE_DIR/$f.part" 2>/dev/null || echo 0)
                [[ -e $CACHE_DIR/$f ]] && p=0
                [[ $h =~ ^[0-9a-f]{64}$ ]] || h=""
                printf '%s|%s|%s|%s|%s|%s\n' "$n" "$b" "$r" "$f" "$(( ${s:-0} + p ))" "$h"
              done >"$out"
    fi
    cat "$out" 2>/dev/null
}

user_country() {  # ISO country code: MIRROR_COUNTRY_CODE, else derived offline from the time zone
    [[ -n ${MIRROR_COUNTRY_CODE:-} ]] && { echo "$MIRROR_COUNTRY_CODE"; return; }
    local tz; tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [[ -z $tz ]] && tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    awk -v tz="$tz" '!/^#/ && $3 == tz {print $1; exit}' /usr/share/zoneinfo/zone.tab 2>/dev/null
}

country_name() { awk -F'\t' -v c="$1" '$1 == c {print $2; exit}' /usr/share/zoneinfo/iso3166.tab 2>/dev/null; }

country_mirrors() {  # mirrors inside the user's country (not crossing the national border = usually not filtered)
    local cc name f txt=""
    [[ -e $TMP/country_mirrors ]] && { cat "$TMP/country_mirrors"; return; }
    cc=$(user_country); name=$(country_name "$cc")
    if [[ -n $name ]]; then
        for f in /etc/pacman.d/mirrorlist.pacnew /etc/pacman.d/mirrorlist; do
            [[ -r $f ]] && txt+=$(awk -v n="## $name" '$0 == n {on=1; next} /^## / {on=0} on && /Server *=/ {sub(/^#* */, ""); sub(/^Server *= */, ""); print}' "$f")$'\n'
        done
        if [[ -z ${txt//$'\n'/} ]]; then   # pristine list from the cached pacman-mirrorlist package
            f=""; local cand
            for cand in "$CACHE_DIR"/pacman-mirrorlist-*.pkg.tar.*; do
                [[ -f $cand && $cand != *.sig ]] || continue
                [[ -z $f || $cand -nt $f ]] && f=$cand
            done
            [[ -n $f ]] && txt=$(bsdtar -xOf "$f" etc/pacman.d/mirrorlist 2>/dev/null \
                | awk -v n="## $name" '$0 == n {on=1; next} /^## / {on=0} on && /Server *=/ {sub(/^#* */, ""); sub(/^Server *= */, ""); print}')
        fi
    fi
    if [[ -z ${txt//$'\n'/} && -n $cc ]]; then
        txt=$(curl -fsS --max-time 15 "https://archlinux.org/mirrorlist/?country=$cc&protocol=https&protocol=http" 2>/dev/null | sed -nE 's/^#?Server *= *//p')
    fi
    printf '%s\n' "$txt" | sed '/^$/d' | awk '!seen[$0]++' >"$TMP/country_mirrors"
    cat "$TMP/country_mirrors"
}

mirror_templates() {  # every Server template worth trying, most promising first
    { local m; for m in $EXTRA_MIRRORS; do echo "$m"; done
      country_mirrors
      awk -F'= *' '/^[[:space:]]*Server/ {print $2}' /etc/pacman.d/mirrorlist 2>/dev/null
      echo 'https://geo.mirror.pkgbuild.com/$repo/os/$arch'
    } | sed 's/[[:space:]]*$//' | awk 'NF && !seen[$0]++'
}

local_proxies() {  # working local/system proxies, as curl -x values (cached for the run)
    [[ -e $TMP/proxies ]] && { cat "$TMP/proxies"; return; }
    local p ports cand=() c
    [[ -n ${PROXY_URL:-} ]] && cand+=("$PROXY_URL")
    [[ -n ${https_proxy:-${HTTPS_PROXY:-}} ]] && cand+=("${https_proxy:-$HTTPS_PROXY}")
    [[ -n ${all_proxy:-${ALL_PROXY:-}} ]] && cand+=("${all_proxy:-$ALL_PROXY}")
    ports=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E '^(127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\*):[0-9]+$' | sed 's/.*://' | sort -un)
    for p in $ports; do
        [[ " $KNOWN_PROXY_PORTS " == *" $p "* ]] && cand+=("socks5h://127.0.0.1:$p" "http://127.0.0.1:$p")
    done
    : >"$TMP/proxies"
    for c in "${cand[@]}"; do
        curl -sS -o /dev/null --max-time 10 -x "$c" https://geo.mirror.pkgbuild.com/ 2>/dev/null && echo "$c" >>"$TMP/proxies"
    done
    awk '!seen[$0]++' "$TMP/proxies"
}

probe_url() {  # probe_url [curl args] URL -> "<http code or reason> <first-byte seconds or ->"
    local out rc
    out=$(curl -sS -o /dev/null --max-time 12 -w '%{http_code} %{time_starttransfer}' "$@" 2>/dev/null); rc=$?
    [[ -z $out && $rc == 0 ]] && { echo "no-reply -"; return; }
    if (( rc == 0 )) || [[ ${out%% *} != 000 && -n $out ]]; then echo "$out"; return; fi
    case $rc in
        6) echo "DNS-fail -" ;; 7) echo "refused -" ;; 28) echo "timeout -" ;; 35|60) echo "TLS-fail -" ;;
        52|56) echo "reset -" ;; 47) echo "redirects -" ;; *) echo "err$rc -" ;;
    esac
}

working_doh() {  # first DNS-over-HTTPS resolver that answers (cached)
    [[ -s $TMP/doh ]] && { cat "$TMP/doh"; return; }
    local d; : >"$TMP/doh"
    for d in $DOH_URLS; do
        curl -sS -o /dev/null --max-time 8 --doh-url "$d" https://geo.mirror.pkgbuild.com/ 2>/dev/null && { echo "$d" >"$TMP/doh"; break; }
    done
    cat "$TMP/doh"
}

dns_poisoned() {  # does the system resolver answer a public mirror with a private/bogus address?
    local ip; ip=$(timeout 5 getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}')
    [[ $ip =~ ^(10\.|127\.|0\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]
}

_rescue_try() {  # _rescue_try PART EXPECTED LABEL curl-args... ; keeps resuming while it makes progress
    local part=$1 size=$2 label=$3 before after rounds=0 rc
    shift 3
    while (( rounds < 40 )); do
        before=$(stat -c %s "$part" 2>/dev/null || echo 0)
        (( size > 0 && before >= size )) && return 0
        printf '\r     ⬇ %-58.58s %3d%% ' "$label" $(( size > 0 ? before * 100 / size : 0 )) 2>/dev/null >/dev/tty
        curl -fL -sS -C - --connect-timeout 20 --speed-limit 1024 --speed-time 45 --max-time 600 \
            --retry 2 --retry-delay 2 -o "$part" "$@" 2>>"$TMP/rescue.err"; rc=$?
        after=$(stat -c %s "$part" 2>/dev/null || echo 0)
        _log "[RESCUE] $label rc=$rc bytes=$before->$after/$size"
        (( size > 0 && after >= size )) && { printf '\r     ⬇ %-58.58s 100%%\n' "$label" 2>/dev/null >/dev/tty; return 0; }
        (( rc == 0 && size <= 0 )) && return 0
        (( rc == 33 || rc == 36 )) && { rm -f "$part"; return 1; }   # server cannot resume: restart elsewhere
        (( after > before )) || break                              # no progress: give up on this route
        rounds=$(( rounds + 1 ))
    done
    printf '\r%80s\r' '' 2>/dev/null >/dev/tty
    return 1
}

_rescue_install() {  # _rescue_install PART SIZE FILE [SHA256] — a verified download goes into the pacman cache
    local part=$1 size=$2 f=$3 sha=${4:-} have_sz
    have_sz=$(stat -c %s "$part" 2>/dev/null || echo 0)
    if [[ -n $sha ]]; then
        (( size > 0 && have_sz < size )) && return 1                       # not finished yet
        if [[ $(sha256sum "$part" 2>/dev/null | awk '{print $1}') != "$sha" ]]; then
            log_warning "$f: checksum does not match the package database (corrupt or tampered copy) — discarding it"
            _log "[RESCUE] $f: sha256 mismatch, size $have_sz (expected $size)"; rm -f "$part"; return 1
        fi
    elif (( size > 0 && have_sz != size )); then
        (( have_sz > size )) && { _log "[RESCUE] $f: $have_sz bytes, expected $size — discarding"; rm -f "$part"; }
        return 1
    fi
    sudo install -m644 "$part" "$CACHE_DIR/$f" && rm -f "$part" && { log_success "Downloaded $f into the package cache${sha:+ (checksum verified)}"; return 0; }
    return 1
}

_rescue_sig() {  # _rescue_sig FILE curl-args... URL — fetch the detached FILE.sig over the route that worked
    local f=$1; shift
    [[ -e $CACHE_DIR/$f.sig ]] && return 0
    local args=("$@") tmp="$RESCUE_DIR/$f.sig.part"
    args[-1]="${args[-1]}.sig"
    if curl -fL -sS --http1.1 --connect-timeout 20 --max-time 120 --retry 3 -o "$tmp" "${args[@]}" 2>>"$TMP/rescue.err" && [[ -s $tmp ]]; then
        sudo install -m644 "$tmp" "$CACHE_DIR/$f.sig" && rm -f "$tmp" && _log "[RESCUE] $f.sig fetched"
    else
        rm -f "$tmp"; _log "[RESCUE] $f.sig not available on that route (pacman will fetch it, or the signature is in the database)"
    fi
    return 0
}

rescue_file() {  # rescue_file FILE REPO SIZE [SHA256] -> 0 when FILE is complete in the pacman cache
    local f=$1 repo=$2 size=$3 sha=${4:-} arch part url host t doh p i n=0 urls=() labels=() args=() pids=() deadline
    local -a proxy=()
    arch=$(uname -m)
    [[ -e $CACHE_DIR/$f ]] && return 0
    mkdir -p "$RESCUE_DIR"; part="$RESCUE_DIR/$f.part"; rm -f "$TMP"/probe.*
    # a copy finished on an earlier run? install it without downloading anything
    if [[ -s $part ]] && _rescue_install "$part" "$size" "$f" "$sha"; then return 0; fi
    # start from pacman's own partial download when it is further along (saves data; same bytes everywhere)
    local cp_sz; cp_sz=$(stat -c %s "$CACHE_DIR/$f.part" 2>/dev/null || echo 0)
    if (( cp_sz > $(stat -c %s "$part" 2>/dev/null || echo 0) )); then
        { cp -f "$CACHE_DIR/$f.part" "$part" 2>/dev/null || sudo cat "$CACHE_DIR/$f.part" >"$part"; } \
            && log_info "Resuming $f from pacman's partial download ($(human "$cp_sz") of $(human "$size") already here)"
    fi
    deadline=$(( $(date +%s) + RESCUE_MAX_MIN * 60 ))
    while read -r t; do
        url=${t//\$repo/$repo}; url=${url//\$arch/$arch}; urls+=("${url%/}/$f")
    done < <(mirror_templates)
    doh=$(working_doh); mapfile -t proxy < <(local_proxies)
    # every route = one way to reach one mirror; probed in parallel with a 1-byte range request
    _add_route() { labels+=("$1"); shift; local IFS=$'\x1f'; args+=("$*"); }
    for url in "${urls[@]}"; do
        host=${url#*://}; host=${host%%/*}
        _add_route "$host · HTTP/1.1" --http1.1 "$url"
        [[ $url == https://* ]] && _add_route "$host · plain HTTP" --http1.1 "http://${url#https://}"
        [[ -n $doh ]] && _add_route "$host · DNS-over-HTTPS" --http1.1 --doh-url "$doh" "$url"
    done
    for p in "${proxy[@]:0:2}"; do
        for url in "${urls[@]:0:6}"; do host=${url#*://}; host=${host%%/*}; _add_route "$host · proxy $p" --http1.1 -x "$p" "$url"; done
    done
    log_info "Rescuing $f ($(human "$size")): probing ${#labels[@]} routes over ${#urls[@]} mirrors${doh:+, DNS-over-HTTPS available}${proxy[0]:+, proxy ${proxy[0]}}"
    for i in "${!labels[@]}"; do
        ( IFS=$'\x1f' read -ra a <<<"${args[$i]}"
          r=$(curl -sS -o /dev/null -r 0-0 --connect-timeout 10 --max-time 15 -w '%{http_code} %{time_starttransfer}' "${a[@]}" 2>/dev/null)
          [[ $r == 20[06]\ * ]] && echo "${r#* } $i" >"$TMP/probe.$i" ) &
        pids+=("$!"); n=$(( n + 1 ))
        (( n % 16 == 0 )) && { wait "${pids[@]}" 2>/dev/null; pids=(); }   # never a bare wait: the script has long-running helpers
    done
    (( ${#pids[@]} )) && wait "${pids[@]}" 2>/dev/null
    local order=() ok_urls=()
    mapfile -t order < <(cat /dev/null "$TMP"/probe.* 2>/dev/null | sort -n | awk '{print $2}')
    _log "[RESCUE] $f: ${#order[@]} of ${#labels[@]} routes answered"
    if (( ${#order[@]} == 0 )); then
        log_warning "No route answered for $f (every mirror, plain HTTP, DNS-over-HTTPS${proxy[0]:+ and proxy})"
        return 1
    fi
    printf '     %s answer: %s\n' "${#order[@]} route(s)" "$(for i in "${order[@]:0:4}"; do printf '%s; ' "${labels[$i]}"; done)" 2>/dev/null >/dev/tty
    # aria2c pulls pieces from several answering mirrors at once (short connections survive throttling)
    if have aria2c && [[ ! -s $part ]]; then
        for i in "${order[@]}"; do [[ ${labels[$i]} == *HTTP/1.1 || ${labels[$i]} == *"plain HTTP" ]] && ok_urls+=("${args[$i]##*$'\x1f'}"); done
        if (( ${#ok_urls[@]} > 1 )); then
            printf '     ⬇ %s via aria2c from %d mirrors at once…\n' "$f" "${#ok_urls[@]}" 2>/dev/null >/dev/tty
            if timeout $(( RESCUE_MAX_MIN * 30 )) aria2c -q -c --allow-overwrite=true --auto-file-renaming=false --max-tries=5 --retry-wait=3 \
                    --timeout=30 --connect-timeout=15 --lowest-speed-limit=1K --split=6 --max-connection-per-server=1 \
                    --min-split-size=4M --dir="$RESCUE_DIR" --out="$f.aria" "${ok_urls[@]:0:8}" 2>>"$TMP/rescue.err"; then
                mv -f "$RESCUE_DIR/$f.aria" "$part" && _rescue_install "$part" "$size" "$f" "$sha" && { _rescue_sig "$f" "${ok_urls[0]}"; return 0; }
            fi
            _log "[RESCUE] $f: aria2c multi-mirror download failed"
        fi
    fi
    # one route at a time, fastest first; a partial file is resumed across routes (same bytes everywhere)
    for i in "${order[@]}"; do
        (( $(date +%s) > deadline )) && { log_warning "Time limit for $f reached (RESCUE_MAX_MIN=$RESCUE_MAX_MIN)"; break; }
        IFS=$'\x1f' read -ra a <<<"${args[$i]}"
        if _rescue_try "$part" "$size" "$f · ${labels[$i]}" "${a[@]}" && _rescue_install "$part" "$size" "$f" "$sha"; then
            [[ ${labels[$i]} == *"· proxy "* ]] && RESCUE_PROXY=${labels[$i]##*· proxy }
            _rescue_sig "$f" "${a[@]}"
            return 0
        fi
    done
    return 1
}

pkg_siblings() {  # pending packages built from the same source (pkgbase) or the lib32-/64-bit twin
    local n=$1 base map; map=$(pending_file_map)
    base=$(awk -F'|' -v n="$n" '$1 == n {print $2; exit}' <<<"$map")
    { [[ -n $base ]] && awk -F'|' -v b="$base" '$2 == b {print $1}' <<<"$map"
      awk -F'|' -v n="$n" '$1 == "lib32-" n || "lib32-" $1 == n {print $1}' <<<"$map"; echo "$n"; } | sort -u
}

hold_check() {  # hold_check pkg... -> prints the closed hold set; returns 1 (and prints the reason) if unsafe
    local set=() p out dep round=0 add
    for p in "$@"; do mapfile -t -O "${#set[@]}" set < <(pkg_siblings "$p"); done
    mapfile -t set < <(printf '%s\n' "${set[@]}" | sort -u)
    while (( round < 8 )); do
        for p in "${set[@]}"; do
            [[ $p =~ $NEVER_HOLD_RE ]] && { echo "UNSAFE: '$p' is a core system package; holding it back can break the system"; return 1; }
        done
        (( ${#set[@]} > 40 )) && { echo "UNSAFE: holding these back would hold ${#set[@]} packages (too many depend on them)"; return 1; }
        out=$(LC_ALL=C pacman "${PAC_OPTS[@]}" -Sup --noconfirm --ignore "$(IFS=,; echo "${set[*]}")" --print-format '%n' 2>&1)
        if ! grep -qiE 'cannot resolve|could not satisfy|unresolvable|breaks dependency' <<<"$out"; then
            printf '%s\n' "${set[@]}"; return 0
        fi
        # "unable to satisfy dependency 'x>=2' required by Y" -> Y needs the new version: hold Y too
        # "installing Y (2-1) breaks dependency 'Y=1-1' required by X" (X held) -> hold Y too
        add=$( { grep -oE 'a dependency of "[^"]+"|required by [^ ]+' <<<"$out" | grep -oE '"[^"]+"|by [^ ]+$' | tr -d '"' | sed 's/^by //'
                 grep -oE 'installing [^ ]+ \(' <<<"$out" | awk '{print $2}'; } | sort -u | grep -vxF -f <(printf '%s\n' "${set[@]}"))
        [[ -z $add ]] && { echo "UNSAFE: pacman says other updates need the new version: $(grep -iE 'cannot resolve|satisfy|breaks' <<<"$out" | head -2 | tr '\n' ' ')"; return 1; }
        for dep in $add; do mapfile -t -O "${#set[@]}" set < <(pkg_siblings "$dep"); done
        mapfile -t set < <(printf '%s\n' "${set[@]}" | sort -u)
        round=$(( round + 1 ))
    done
    echo "UNSAFE: the dependency chain is too long to hold back safely"; return 1
}

fix_BLOCKED_DL() {
    local map f row name repo size sha rescued=() still_blocked=() hold rc
    map=$(pending_file_map)
    [[ -n $map ]] || { log_warning "Could not list the pending package files"; return 1; }
    log_fix "Fetching the blocked packages one by one (other mirrors, in-country mirrors, HTTP/1.1, DNS-over-HTTPS, plain HTTP, proxy)"
    local cc; cc=$(user_country)
    [[ -n $cc ]] && log_info "Country from your time zone: $cc ($(country_name "$cc")) — $(country_mirrors | wc -l) mirror(s) inside the country will be tried first"
    for f in $(blocked_files); do
        row=$(awk -F'|' -v f="$f" '$4 == f' <<<"$map")
        [[ -n $row ]] || continue
        IFS='|' read -r name _ repo _ size sha <<<"$row"
        if rescue_file "$f" "$repo" "$size" "$sha"; then rescued+=("$name"); else still_blocked+=("$name"); fi
    done
    (( ${#rescued[@]} )) && log_success "Rescued: ${rescued[*]}"
    [[ -n ${RESCUE_PROXY:-} ]] && log_info "The proxy $RESCUE_PROXY worked; the rest of this run's pacman downloads will use it too" && PAC_PROXY=$RESCUE_PROXY
    if (( ${#still_blocked[@]} == 0 )); then build_pacman_conf; return 0; fi
    log_warning "Still blocked after every method: ${still_blocked[*]}"
    # first time, and the connection fixes (longer timeouts, fewer parallel downloads, other mirrors/DNS)
    # were just applied: let pacman retry with them before deciding to hold anything back
    if (( ${FIX_COUNT[BLOCKED_DL]:-0} == 0 )) && [[ " ${ISSUES[*]} " =~ \ (NETWORK|SLOW_NET|MIRRORS)\  ]]; then
        log_info "Retrying once with the connection fixes first; if these files are still blocked, I will check whether they can safely be held back for this run."
        return 3
    fi
    hold=$(hold_check "${still_blocked[@]}"); rc=$?
    if (( rc != 0 )); then
        log_error "Cannot skip them: ${hold#UNSAFE: }"
        log_info "Nothing has been installed yet (all downloads finish before any install), so your system is unchanged and consistent."
        log_info "Ways forward: connect a proxy/VPN that works and run again (it is detected automatically), set PROXY_URL or EXTRA_MIRRORS in $CONFIG_FILE, or download these files on another network and copy them into $CACHE_DIR:"
        for f in $(blocked_files); do awk -F'|' -v f="$f" -v a="$(uname -m)" '$4 == f {printf "     https://geo.mirror.pkgbuild.com/%s/os/%s/%s  (%s bytes)\n", $3, a, $4, $5}' <<<"$map"; done
        BLOCKED_FINAL=("${still_blocked[@]}")
        return 1
    fi
    log_warning "Holding back for THIS RUN only: $(tr '\n' ' ' <<<"$hold")"
    echo "     Safe because: pacman found no other update that needs their new versions, no core system package is"
    echo "     involved, and packages from the same source (or their 32-bit twin) are held together."
    echo "     They keep their current version and are tried first on the next run."
    if [[ $FIX_MODE == auto && $ALLOW_RISKY_AUTO != true ]] || ! ui_ask "Hold these back and continue the update without them?" y; then
        BLOCKED_FINAL=("${still_blocked[@]}"); return 1
    fi
    mapfile -t -O "${#HOLD_PKGS[@]}" HOLD_PKGS <<<"$hold"
    mkdir -p "$STATE_DIR"
    { date '+%F %T'; printf '%s\n' "$hold"; } | paste -sd' ' >>"$STATE_DIR/held-packages.log"
    printf '%s\n' "$hold" >"$STATE_DIR/held-last-run"
    rm -f "$TMP/pending_files"
    build_pacman_conf
}

check_held_last_run() {  # reminder at start of a run
    [[ -s $STATE_DIR/held-last-run ]] || return 0
    log_warning "Held back on the last run (blocked downloads): $(tr '\n' ' ' <<<"$(cat "$STATE_DIR/held-last-run")") — they will be updated now if they can be downloaded"
    rm -f "$STATE_DIR/held-last-run"
}

# ======================================================================
# DETAILED SYSTEM REPORT: everything that can affect an update, and why
# ======================================================================
explain_service() {  # known failing units → plain explanation and safe action
    case $1 in
        archlinux-keyring-wkd-sync.service) echo "Refreshes Arch packager keys from openpgpkey.archlinux.org (WKD). It fails when that site is blocked, filtered or offline. Harmless for updates: keys also come with the archlinux-keyring package. Clear it: sudo systemctl reset-failed $1 (or run it through a proxy: sudo systemctl edit $1 → Environment=https_proxy=…)." ;;
        drkonqi-coredump-pickup.service) echo "KDE's crash reporter: it failed while collecting a crash dump of some KDE program. Not related to updates. Clear it: systemctl --user reset-failed $1" ;;
        app-*@*.service) echo "A desktop application started as a user service ($(sed -E 's/^app-([^@]+)@.*/\1/' <<<"$1")) exited with an error or crashed. Not related to updates. Clear it: systemctl --user reset-failed $1" ;;
        reflector.service) echo "Reflector could not rank mirrors (usually archlinux.org is unreachable from here). Your old mirrorlist stays in use." ;;
        pacman-filesdb-refresh.service) echo "Background 'pacman -Fy' could not download the file databases (network/mirror). Harmless." ;;
        packagekit.service) echo "PackageKit (Discover's backend) failed. If it runs during an update it can hold the pacman lock." ;;
        *) echo "" ;;
    esac
}

detail() {  # detail "text" | stdin → indented on screen AND in the log
    local line
    if (( $# )); then printf '%s\n' "$*" | detail; return; fi
    while IFS= read -r line; do printf '     %s\n' "$line"; _log "    $line"; done
}

write_report() {  # write_report [deep] — a full picture of the system for this run
    local deep=${1:-} out t
    out="$LOG_DIR/report_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$LOG_DIR"
    log_step "Writing the detailed system report"
    {
    rsec() { printf '\n==== %s ====\n' "$1"; }
    printf 'Arch Smart Update %s — detailed report — %s\n' "$VERSION" "$(date '+%F %T %Z')"
    printf 'Run log: %s\n' "${LOG_FILE:-none}"

    rsec "1. This run"
    # the same issue is seen once per failed attempt: count instead of repeating it
    printf 'Issues detected: %s\n' "$( (( ${#ISSUES_SEEN[@]} )) && printf '%s\n' "${ISSUES_SEEN[@]}" | awk 'NF {c[$0]++; if (!s[$0]++) o[++n]=$0} END {for (i=1;i<=n;i++) printf "%s%s ", o[i], (c[o[i]]>1 ? " x" c[o[i]] : "")}' || echo none)"
    printf 'Fixes applied:   %s\n' "$( (( ${#FIXES_APPLIED[@]} )) && printf '%s\n' "${FIXES_APPLIED[@]}" | awk 'NF {c[$0]++; if (!s[$0]++) o[++n]=$0} END {for (i=1;i<=n;i++) printf "%s%s; ", o[i], (c[o[i]]>1 ? " (x" c[o[i]] ")" : "")}' || echo none)"
    printf 'Unresolved:      %s\n' "$( (( ${#UNRESOLVED[@]} )) && printf '%s; ' "${UNRESOLVED[@]}" || echo none)"
    printf 'Held back:       %s\n' "${HOLD_PKGS[*]:-none}"
    printf 'Still blocked:   %s\n' "${BLOCKED_FINAL[*]:-none}"
    printf 'Slow-network level %s; proxy for pacman: %s; DNS-over-HTTPS for pacman: %s; skipped repos: %s\n' "$SLOW_LEVEL" "${PAC_PROXY:-none}" "${PAC_DOH:-no}" "${SKIP_REPOS[*]:-none}"
    (( ${#SKIPPED_DNS[@]} )) && printf 'Skipped because the system DNS was down: %s\n' "${SKIPPED_DNS[*]}"
    printf 'Data downloaded this run: %s (packages %s)\n' "$(human "$(net_used)")" "$(human "$PKG_DOWNLOADED_BYTES")"

    rsec "2. Machine"
    printf 'Kernel running: %s   installed: %s\n' "$(uname -r)" "$(pacman -Q linux linux-lts linux-zen linux-hardened 2>/dev/null | tr '\n' ' ')"
    [[ -d /usr/lib/modules/$(uname -r) ]] || echo "!! The running kernel's modules are gone (kernel was updated): reboot before loading new drivers"
    printf 'Uptime/load: %s\n' "$(uptime 2>/dev/null)"
    free -h 2>/dev/null
    df -h / /boot /home "$CACHE_DIR" 2>/dev/null | awk '!seen[$0]++'
    for t in /sys/class/power_supply/*; do
        [[ -r $t/type ]] || continue
        case $(cat "$t/type") in
            Battery) printf 'Battery %s: %s%% (%s)\n' "${t##*/}" "$(cat "$t/capacity" 2>/dev/null)" "$(cat "$t/status" 2>/dev/null)" ;;
            Mains)   printf 'AC power: %s\n' "$( [[ $(cat "$t/online" 2>/dev/null) == 1 ]] && echo connected || echo 'NOT connected — a power loss during install can break the system')" ;;
        esac
    done

    rsec "3. Package manager state"
    if [[ -e $DB_PATH/db.lck ]]; then echo "!! pacman lock present: $DB_PATH/db.lck ($(stat -c %y "$DB_PATH/db.lck" 2>/dev/null))"; else echo "No pacman lock"; fi
    echo "Other package tools running right now (they can hold the lock or change packages during the update):"
    pgrep -a -x 'pacman|paru|yay|pikaur|trizen|pamac|pamac-daemon|pamac-manager|packagekitd|discover|plasma-discover|octopi|gnome-software|flatpak|snapd|makepkg|reflector|mkinitcpio|dkms' 2>/dev/null \
        | while read -r t rest; do
            printf '   %s %s\n' "$t" "$rest"
            case $rest in
                *plasma-discover*--headless-update*) echo "      → KDE Discover's automatic background update. It updates through PackageKit, which takes the pacman lock, so it can collide with this run, and it may install updates at shutdown. Turn it off: System Settings → Software Update → Apply system updates: Manually (or: kwriteconfig6 --file PlasmaDiscoverUpdates --group Global --key UseUnattendedUpdates false)." ;;
                *plasma-discover*|*discover*) echo "      → KDE Discover is open; if it starts an update it holds the pacman lock." ;;
                *packagekitd*) echo "      → PackageKit (used by Discover/GNOME Software) — holds the pacman lock while it refreshes or installs." ;;
                *pamac*) echo "      → Pamac (Manjaro's package manager) can refresh databases or update in the background; Arch does not support mixing it with pacman updates." ;;
                *snapd*) echo "      → The Snap daemon: it refreshes snaps on its own schedule (snap refresh --time); it does not touch pacman." ;;
                *flatpak*) echo "      → A Flatpak operation is running; it does not touch pacman." ;;
            esac
          done | grep . || echo "   none"
    echo "Package-related timers:"
    systemctl list-timers --all --no-pager 2>/dev/null | grep -E 'reflector|paccache|pacman|archlinux-keyring|packagekit|pamac|man-db|updatedb' | sed 's/^/   /'
    echo "pacman.conf options in effect:"
    pacman-conf 2>/dev/null | grep -E '^(Architecture|ParallelDownloads|XferCommand|DisableDownloadTimeout|SigLevel|IgnorePkg|IgnoreGroup|NoUpgrade|NoExtract|CacheDir|HookDir)' | sed 's/^/   /'
    echo "Repositories: $(pacman-conf --repo-list 2>/dev/null | tr '\n' ' ')"
    echo "Mirrors in use: $(grep -cE '^[[:space:]]*Server' /etc/pacman.d/mirrorlist 2>/dev/null) (first: $(awk -F'= *' '/^[[:space:]]*Server/ {print $2; exit}' /etc/pacman.d/mirrorlist 2>/dev/null)); mirrorlist changed $(stat -c %y /etc/pacman.d/mirrorlist 2>/dev/null | cut -d. -f1)"
    t=$(user_country); echo "Country guessed from time zone: ${t:-unknown} $(country_name "$t"); in-country mirrors known: $(country_mirrors | wc -l)"
    echo "Partial downloads waiting to resume:"
    { find "${CACHE_DIRS[@]}" -maxdepth 1 -name '*.part' -printf '   %s bytes  %p\n' 2>/dev/null; find "$RESCUE_DIR" -maxdepth 1 -name '*.part' -printf '   %s bytes  %p\n' 2>/dev/null; } | head -20
    echo "Foreign (AUR/local) packages: $(pacman -Qmq 2>/dev/null | wc -l)"
    echo "Pending updates: $(pacman -Qu 2>/dev/null | wc -l)"
    echo "Hooks that run on every transaction (a failing hook makes the whole install fail):"
    { local hk n=0; for hk in /etc/pacman.d/hooks/*.hook; do echo "   custom: $hk"; done
      for hk in /usr/share/libalpm/hooks/*.hook; do n=$(( n + 1 )); done; echo "   packaged hooks: $n"; }
    have informant && echo "informant (blocks pacman while Arch news is unread): $(informant check >/dev/null 2>&1 && echo 'no unread news' || echo 'UNREAD NEWS — pacman will refuse to install')"
    have dkms && { echo "DKMS modules (rebuilt on kernel updates; need matching headers):"; dkms status 2>/dev/null | sed 's/^/   /'; }
    echo "Kernels and headers:"; for t in $(installed_kernels); do printf '   %s %s / headers: %s\n' "$t" "$(pacman -Q "$t" 2>/dev/null | cut -d' ' -f2)" "$(pacman -Q "$t-headers" 2>/dev/null | cut -d' ' -f2 || echo none)"; done

    rsec "4. Running programs that the pending update replaces"
    echo "(they keep running the old version until restarted; long-running ones may misbehave after the update)"
    local exes owners pend hit stale l
    exes=$(for t in /proc/[0-9]*/exe; do readlink "$t" 2>/dev/null; done | sed 's/ (deleted)$//' | sort -u)
    pend=$(pacman -Qqu 2>/dev/null | sort -u)
    if [[ -n $exes && -n $pend ]]; then
        # shellcheck disable=SC2086
        owners=$(LC_ALL=C pacman -Qqo $exes 2>/dev/null | sort -u)
        hit=$(comm -12 <(echo "$owners") <(echo "$pend") | sed '/^$/d')
        if [[ -n $hit ]]; then sed 's/^/   pending update for running program: /' <<<"$hit" | head -40; else echo "   none of the running programs is in the pending update"; fi
    else
        echo "   no pending updates"
    fi
    # already updated but still running the old (deleted) binary -> restart these (or reboot)
    stale=$(for t in /proc/[0-9]*/exe; do l=$(readlink "$t" 2>/dev/null) && [[ $l == *" (deleted)" ]] && echo "${l% (deleted)}"; done | sort | uniq -c | sort -rn | head -20)
    [[ -n $stale ]] && { echo "Still running an old, replaced binary (restart these programs or reboot):"; sed 's/^/   /' <<<"$stale"; }

    rsec "5. Failed services (and what they mean)"
    for t in $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do
        printf '   [system] %s\n      why: %s\n' "$t" "$(explain_service "$t")"
        journalctl -u "$t" -n 6 --no-pager 2>/dev/null | sed 's/^/      | /'
    done
    for t in $(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do
        printf '   [user] %s\n      why: %s\n' "$t" "$(explain_service "$t")"
        journalctl --user -u "$t" -n 6 --no-pager 2>/dev/null | sed 's/^/      | /'
    done

    rsec "6. Network path"
    ip -brief address 2>/dev/null | sed 's/^/   /'
    echo "Default route: $(ip route show default 2>/dev/null | head -2 | tr '\n' ';')"
    t=$(ip route show default 2>/dev/null | awk '{print $5; exit}'); [[ -n $t ]] && echo "MTU on $t: $(cat "/sys/class/net/$t/mtu" 2>/dev/null)"
    echo "VPN / proxy software active: $(active_vpn)"
    echo "Proxy variables: http_proxy=${http_proxy:-} https_proxy=${https_proxy:-} all_proxy=${all_proxy:-} (sudo drops these unless configured)"
    echo "Local listening ports that look like proxies: $(ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un | while read -r t; do [[ " $KNOWN_PROXY_PORTS " == *" $t "* ]] && printf '%s ' "$t"; done)"
    echo "DNS:"; { resolvectl status 2>/dev/null | grep -E 'DNS Servers|Current DNS|DNS over TLS' | sort -u; grep -E '^nameserver' /etc/resolv.conf 2>/dev/null; } | sed 's/^/   /' | grep . || echo "   (no DNS server configured at all)"
    resolver_state 2>/dev/null | sed 's/^ */   /'
    echo "IPv6 default route: $(ip -6 route show default 2>/dev/null | head -1 | grep -q . && echo yes || echo no)"

    if [[ -n $deep ]]; then
        rsec "7. Reachability of each mirror (DNS, poisoning, HTTPS, plain HTTP, HTTP/1.1)"
        local doh; doh=$(working_doh)
        printf '   %-34s %-16s %-6s %-12s %-12s %-12s %s\n' host "system DNS" poison "https" "http" "https+DoH" "first byte (s)"
        local m h ip code1 code2 code3 tt
        for m in $( { awk -F'= *' '/^[[:space:]]*Server/ {print $2}' /etc/pacman.d/mirrorlist 2>/dev/null; country_mirrors; echo 'https://geo.mirror.pkgbuild.com/'; } | awk '!s[$0]++' | head -14); do
            h=${m#*://}; h=${h%%/*}
            ip=$(timeout 5 getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
            read -r code1 tt < <(probe_url --http1.1 "https://$h/")
            read -r code2 _ < <(probe_url "http://$h/")
            if [[ -n $doh ]]; then read -r code3 _ < <(probe_url --http1.1 --doh-url "$doh" "https://$h/"); else code3="no-DoH"; fi
            printf '   %-34s %-16s %-6s %-12s %-12s %-12s %s\n' "$h" "${ip:-NO ANSWER}" "$( [[ -z $ip ]] && echo "-" || { dns_poisoned "$h" && echo YES || echo no; })" "$code1" "$code2" "$code3" "$tt"
        done
        echo "DNS-over-HTTPS that works from here: $(working_doh || true)"
        echo "Working proxies: $(local_proxies | tr '\n' ' ')"
        echo "archlinux.org (news, mirror status, keys): $(probe_url --http1.1 https://archlinux.org/ | cut -d" " -f1)"
        echo "openpgpkey.archlinux.org (WKD key refresh): $(probe_url --http1.1 https://openpgpkey.archlinux.org/ | cut -d" " -f1)"
        echo "aur.archlinux.org: $(probe_url --http1.1 https://aur.archlinux.org/ | cut -d" " -f1)"
        echo "flathub: $(probe_url --http1.1 https://dl.flathub.org/ | cut -d" " -f1)"
    fi

    rsec "8. Download failures in this run (per file, per mirror)"
    local lg; for lg in "$TMP"/attempt_runner_download_*.log "$TMP"/attempt_runner_install_*.log; do
        [[ -e $lg ]] || continue
        CLEAN_LOG="$lg.clean"; [[ -e $CLEAN_LOG ]] || strip_ansi <"$lg" >"$CLEAN_LOG"
        t=$(dl_failure_summary); [[ -n $t ]] && { echo "-- ${lg##*/}"; echo "$t"; }
    done
    [[ -s $TMP/rescue.err ]] && { echo "-- rescue attempts (curl/aria2 errors):"; sort "$TMP/rescue.err" | uniq -c | sort -rn | head -15; }
    grep -h '^\[RESCUE\]' "$LOG_FILE" 2>/dev/null | tail -40
    echo
    echo "Verdict:"
    report_verdict
    } >"$out" 2>&1
    log_success "Detailed report: $out"
    REPORT_FILE=$out
}

report_verdict() {  # plain-language conclusions from what was collected
    local t
    if (( ${#BLOCKED_FINAL[@]} )); then
        echo " - These packages could not be downloaded by any route: ${BLOCKED_FINAL[*]}. The same files failing on many mirrors while others download points to filtering/censorship or deliberate throttling between you and the mirrors."
    fi
    t=$(grep -h 'Resolving timed out' /dev/null "$TMP"/attempt_*.log 2>/dev/null | wc -l)
    (( t > 0 )) && echo " - $t DNS timeouts: your DNS server is slow/filtered. DNS-over-HTTPS or a different DNS server fixes this."
    t=$(grep -hE 'HTTP/2 stream .* reset|PROTOCOL_ERROR' /dev/null "$TMP"/attempt_*.log 2>/dev/null | wc -l)
    (( t > 0 )) && echo " - $t HTTP/2 resets: a middlebox kills HTTP/2 streams. Forcing HTTP/1.1 (slow-network mode 2 or the rescue) avoids this."
    [[ -n $(active_vpn) ]] && echo " - A VPN/proxy is active ($(active_vpn)). If downloads fail through it, try split-tunnelling the mirrors or updating without it; if they fail without it, use it (set PROXY_URL)."
    t=$(grep -hc 'Could not resolve host' /dev/null "$TMP"/attempt_*.log 2>/dev/null | awk '{s+=$1} END {print s+0}')
    if (( t > 0 )) || dns_dead; then
        echo " - The system DNS gave no answer at all$( (( t > 0 )) && echo " ($t 'Could not resolve host' errors)"). $( grep -qE '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null || echo '/etc/resolv.conf has no DNS server: the Wi-Fi/VPN connection left it empty. ')Reconnect the network or set a DNS server in NetworkManager.$( [[ -n $(working_doh) ]] && echo " DNS-over-HTTPS works from here, so pacman can still update through it (done automatically)." )"
    fi
    (( ${#SKIPPED_DNS[@]} )) && echo " - Skipped while DNS was down: ${SKIPPED_DNS[*]} — run again once DNS works."
    pgrep -fa 'plasma-discover --headless-update' >/dev/null && echo " - KDE Discover's background updater is running; it can take the pacman lock during this script. Set Software Update → 'Manually' if you update with this script."
    (( ${#HOLD_PKGS[@]} )) && echo " - Held back this run (safe, re-tried next run): ${HOLD_PKGS[*]}"
    return 0
}

# ======================================================================
# FIX DETAILS: what each fix repairs and the exact commands it will run
# ======================================================================
_plan_mirrors() {  # commands used by refresh_mirrors
    local ml=/etc/pacman.d/mirrorlist
    if have pacman-mirrors; then P_CMDS+=("sudo pacman-mirrors --fasttrack 10|Manjaro's own mirror ranking"); return; fi
    if have reflector; then
        local ct=3 dt=5; (( SLOW_LEVEL > 0 )) && { ct=10; dt=20; }
        P_CMDS+=("reflector --latest 20 --fastest 10 --protocol https --age 12 --connection-timeout $ct --download-timeout $dt${MIRROR_COUNTRY:+ --country $MIRROR_COUNTRY} --save <temp file>|ranks fresh HTTPS mirrors into a temporary file")
    else
        P_CMDS+=("@curl 'https://archlinux.org/mirrorlist/?country=all&protocol=https&use_mirror_status=on' → first 10 servers into a temp file|reflector is not installed")
    fi
    P_CMDS+=("sudo cp -a $ml $ml.smart-update.bak|backup of your current list"
             "sudo install -m644 <temp file> $ml|only if the new list really contains servers")
    P_UNDO="sudo cp $ml.smart-update.bak $ml"
}

_plan_dns() {
    local ifc; ifc=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    P_CMDS+=("getent hosts archlinux.org|3 tries, 3 s each; checks whether DNS answers")
    P_CMDS+=("sudo resolvectl flush-caches|only if systemd-resolved is running")
    P_CMDS+=("sudo resolvectl dns ${ifc:-<interface>} 1.1.1.1 9.9.9.9 8.8.8.8|only if DNS still fails and you say yes; temporary, until the connection reconnects")
    P_UNDO="sudo resolvectl revert ${ifc:-<interface>}   (or simply reconnect the network)"
}

fix_plan() {  # fix_plan CODE — prints the plan; uses the current log for package names, files, keys
    local c=$1 i=0 entry cmd cond x lst h=$HELPER
    [[ -z $h || $h == none ]] && h=$AUR_HELPER
    P_CMDS=(); P_UNDO=""; local what="" touches="" note=""
    [[ -n $CLEAN_LOG ]] || CLEAN_LOG=/dev/null
    case $c in
        SUDO) what="Your sudo login timed out, so pacman could not run as root."
            P_CMDS=("sudo -v|asks for your password once"); touches="Nothing." ;;
        NETWORK) what="Downloads failed because the connection or DNS dropped."
            grep -qiE 'resolving timed out|dns error|name resolution|resolve host' "$CLEAN_LOG" 2>/dev/null && _plan_dns
            P_CMDS+=("curl -sS --max-time 10 -o /dev/null <url>|tried on your first mirror, geo.mirror.pkgbuild.com, archlinux.org and 1.1.1.1 every 5 s for up to 60 s, until one answers"
                     "ping -c1 -W3 1.1.1.1|only if still offline: tells a DNS problem apart from a dead link"
                     "sudo resolvectl flush-caches|only if the internet works by IP but not by name"
                     "@if names still do not resolve but DNS-over-HTTPS answers (tried: ${DOH_URLS// /, }): add 'XferCommand = /usr/bin/curl … --doh-url <resolver>' to this run's temporary pacman.conf|pacman then looks up mirror names over HTTPS; Flatpak, Snap and AUR are skipped until DNS works")
            touches="Nothing permanent (at most the DNS cache is cleared, temporary DNS servers you approved, or this run's temporary pacman.conf)." ;;
        DNS) what="Host names resolve slowly or not at all."; _plan_dns
            touches="Only the DNS cache, plus temporary DNS servers if you approve them." ;;
        BLOCKED_DL) lst=$(blocked_files | tr '\n' ' ')
            what="These package files are blocked or throttled on every mirror that was tried: ${lst:-?}. Each one is fetched straight into the package cache by other routes; the rest of the update is untouched."
            P_CMDS=("@for each file: probe every route at once with a 1-byte request (curl -r 0-0) and use the ones that answer, fastest first|routes = in-country mirrors ($(country_mirrors | wc -l) found for $(user_country)) + EXTRA_MIRRORS + your mirrorlist + geo.mirror.pkgbuild.com, each over HTTPS with HTTP/1.1, plain HTTP, DNS-over-HTTPS, and through a local proxy if one is running")
            have aria2c && P_CMDS+=("aria2c -c --split=6 --max-connection-per-server=1 -d $RESCUE_DIR <up to 8 answering mirrors>|downloads pieces from several mirrors at once; short connections survive throttling")
            P_CMDS+=("curl -fL -C - --http1.1 --speed-limit 1024 --speed-time 45 -o $RESCUE_DIR/<file>.part <url>|resumes after every cut, moving to the next route when one stops making progress; at most $RESCUE_MAX_MIN min per file"
                     "sudo install -m644 $RESCUE_DIR/<file>.part $CACHE_DIR/<file>|only when the size matches; pacman still checks the signature before installing"
                     "@if a file still cannot be downloaded: check whether holding it back is safe (same-source packages and their 32-bit twin are held together; pacman must find no update that needs the new version; core packages such as glibc, systemd, pacman, keyrings and kernels' tools are never held)|asks you first; then the update continues without them (sudo pacman -Su --ignore <list>) and they are tried first next run"
                     "@if holding back is not safe: stop before anything is installed and list the exact URLs so you can fetch the files another way")
            touches="Only adds downloaded package files to the cache. Holding back (if you approve) keeps those packages at their current version for this run." ;;
        SLOW_NET) x=$(( SLOW_LEVEL + 1 ))
            what="Downloads were too slow or kept timing out. Switches this run to slow-network level $x."
            (( SLOW_LEVEL >= 2 )) && note="Already at the highest level (2), so this fix will not change anything."
            P_CMDS=("cp /etc/pacman.conf $TMP/pacman.conf|a private copy used only by this run"
                    "@set 'ParallelDownloads = $(( x >= 2 ? 1 : 2 ))' in that copy|fewer downloads at once, so each one is less likely to stall")
            (( x >= 2 )) && P_CMDS+=("@add 'XferCommand = /usr/bin/curl -L -C - -f --retry 8 --retry-delay 5 --retry-all-errors --connect-timeout 30 --speed-limit 1 --speed-time 120 --http1.1 -o %o %u' to that copy|curl retries 8 times and resumes broken downloads")
            P_CMDS+=("@retry the failed step with: sudo pacman --config $TMP/pacman.conf --disable-download-timeout …|already-downloaded parts are resumed, not downloaded again")
            touches="Nothing: /etc/pacman.conf is not changed, and the copy is deleted when the script ends." ;;
        THIRDPARTY_DB) lst=$(thirdparty_failed_repos | tr '\n' ' ')
            what="The third-party repo(s) ${lst:-?}could not be reached, which stops the whole database sync."
            P_CMDS=("@copy /etc/pacman.conf to $TMP/pacman.conf without the section(s): $(for x in $lst; do printf '[%s] ' "$x"; done)|this run only"
                    "@retry the failed step with: sudo pacman --config $TMP/pacman.conf …")
            touches="Nothing permanent. Packages from ${lst:-those repos}stay at their current version this run." ;;
        INFORMANT) what="The informant pacman hook refuses to let pacman install anything while Arch news is unread."
            P_CMDS=("sudo informant list --unread|shows the unread news here first"
                    "@asks you whether you have read it"
                    "sudo informant read --all|only after you answer yes")
            touches="Marks the news as read in informant's cache. Nothing else." ;;
        AUR_PKGBUILD) lst=$(parse_source_fail_pkgs | tr '\n' ' ')
            what="The build script of ${lst:-?}is invalid, so makepkg stops before building."
            for x in $lst; do P_CMDS+=("rm -rf ~/.cache/paru/clone/$x ~/.cache/yay/$x|first time: throw away the cached copy so the helper downloads it fresh (only that package's build folder)"); done
            P_CMDS+=("@second time: retry the AUR update with --ignore $(tr ' ' ',' <<<"${lst% }")|every other AUR package still updates")
            touches="Only that package's build folder in ~/.cache." ;;
        AUR_SOURCE) lst=$(parse_source_fail_pkgs | tr '\n' ' ')
            what="The download server for AUR package(s) ${lst:-?}is unreachable, which stops all AUR updates."
            P_CMDS=("@retry the AUR update with: $h -Sua --noconfirm --ignore $(tr ' ' ',' <<<"${lst% }")|every other AUR package still updates")
            touches="Nothing. The skipped packages keep their current version until their server works again." ;;
        LOCALE) local base=${LANG:-en_US.UTF-8}; base=${base%%.*}
            what="Your language setting (${LANG:-unset}) has no generated locale, so programs and hooks print locale errors."
            if grep -qE "^#[[:space:]]*${base}\.UTF-8 UTF-8" /etc/locale.gen 2>/dev/null; then
                P_CMDS=("sudo sed -i 's/^#\\s*${base}.UTF-8 UTF-8/${base}.UTF-8 UTF-8/' /etc/locale.gen|un-comments one line")
            else
                P_CMDS=("echo '${base}.UTF-8 UTF-8' | sudo tee -a /etc/locale.gen|adds one line")
            fi
            P_CMDS+=("sudo locale-gen|protected step: $STOP_KEY_LABEL waits for it")
            touches="/etc/locale.gen (one line) and the generated locale archive."
            P_UNDO="comment the ${base}.UTF-8 line in /etc/locale.gen again, then: sudo locale-gen" ;;
        LOCK) local lock="$DB_PATH/db.lck"
            what="pacman's database lock ($lock) is in place, so no other pacman can run."
            note="Right now: lock $([[ -e $lock ]] && echo present || echo 'not present'); pacman $(pgrep -x pacman >/dev/null && echo "IS running ($(pgrep -a -x pacman | head -1))" || echo 'is not running')."
            P_CMDS=("@wait for the running pacman, checking 'pgrep -x pacman' every 5 s for up to 2 min|only if pacman is running; a running pacman is never touched"
                    "sudo systemctl stop packagekit|only if PackageKit is running (it can hold the lock)"
                    "sudo rm -f $lock|only when no pacman process is left, i.e. the lock is stale")
            touches="Removes the stale lock file only." ;;
        DISK) x=$(free_mb "$CACHE_DIR"); what="Not enough free space for the update${x:+ (now $x MB free on the cache disk)}."
            if have paccache; then P_CMDS=("sudo paccache -rk1|keeps only the newest cached version of each package"
                                            "sudo paccache -ruk0|removes cached files of uninstalled packages")
            else P_CMDS=("sudo pacman -Sc --noconfirm|removes cached files of old versions"); fi
            P_CMDS+=("sudo journalctl --vacuum-size=200M|shrinks the system journal to 200 MB"
                     "rm -rf ~/.cache/yay/*/{src,pkg} ~/.cache/paru/clone/*/{src,pkg} ~/.cache/yay/*/*.pkg.tar.* ~/.cache/paru/clone/*/*.pkg.tar.*|AUR build leftovers")
            while read -r x; do [[ -n $x ]] && P_CMDS+=("sudo rm -f $x $x.sig|corrupted download"); done < <(parse_corrupt_files)
            P_CMDS+=("sudo find ${CACHE_DIRS[*]:-$CACHE_DIR} -maxdepth 2 ( -name '*.part' -o -name 'download-*' ) -exec rm -rf {} +|unfinished downloads")
            touches="Deletes cached package files, old journal entries and build leftovers. Installed programs are not touched."
            P_UNDO="Not reversible, but everything removed can be downloaded again." ;;
        SYNC_DB) what="pacman's package databases are incomplete or corrupted."
            P_CMDS=("sudo find $DB_PATH/sync -maxdepth 1 ( -name '*.part' -o -name '*.lck' ) -delete|unfinished database downloads")
            if grep -qiE 'GPGME|invalid or corrupted database' "$CLEAN_LOG" 2>/dev/null; then
                P_CMDS+=("sudo rm -f $DB_PATH/sync/*.db $DB_PATH/sync/*.sig $DB_PATH/sync/*.files|the database files reported as broken")
                _plan_mirrors
            fi
            P_CMDS+=("sudo pacman -Syy --noconfirm|downloads all databases fresh")
            touches="Package databases only; installed packages are not changed." ;;
        KEYRING) what="Package signatures could not be verified (keyring outdated, damaged, or wrong clock)."
            P_CMDS=("sudo timedatectl set-ntp true|only if the clock is not synchronised")
            while read -r x; do [[ -n $x ]] && P_CMDS+=("sudo rm -f $x $x.sig|cached file with a bad signature"); done < <(parse_corrupt_files)
            [[ ! -d /etc/pacman.d/gnupg ]] || grep -qiE 'public keyring not found|keyring is not writable|trustdb' "$CLEAN_LOG" 2>/dev/null \
                && P_CMDS+=("sudo pacman-key --init|keyring missing or unwritable; protected step")
            lst=""; for x in /usr/share/pacman/keyrings/*.gpg; do [[ -e $x ]] && { x=${x##*/}; lst+="${x%.gpg} "; }; done
            P_CMDS+=("sudo pacman-key --populate ${lst:-archlinux}|reloads the official keys; protected step")
            for x in $(parse_pgp_keys); do P_CMDS+=("sudo pacman-key --recv-keys $x|key named in the error"); done
            (( ${FIX_COUNT[KEYRING]:-0} >= 1 )) && P_CMDS+=("sudo pacman-key --updatedb|second attempt: rebuilds the trust database")
            lst=$(pacman -Qq 2>/dev/null | grep -E -- '-keyring$' | tr '\n' ' ')
            P_CMDS+=("sudo pacman -Sy --needed --noconfirm ${lst:-archlinux-keyring}|newest keyring packages; the full upgrade follows in this same run; protected step")
            touches="pacman's keyring (/etc/pacman.d/gnupg) and the *-keyring packages." ;;
        CORRUPT_PKG) what="Downloaded package file(s) are damaged."
            P_CMDS=("sudo timedatectl set-ntp true|only if the clock is not synchronised")
            while read -r x; do [[ -n $x ]] && P_CMDS+=("sudo rm -f $x $x.sig"); done < <(parse_corrupt_files)
            touches="Only the damaged cached files; they are downloaded again on the retry." ;;
        CERT) what="HTTPS certificates were rejected, usually because the clock is wrong."
            P_CMDS=("sudo timedatectl set-ntp true|turns on automatic time sync; waits up to 12 s for it")
            touches="System clock synchronisation setting." ;;
        MIRRORS) what="Your mirror(s) are slow, outdated or failing ($(failed_host_count) failing host(s) in the log)."
            while read -r x; do [[ -n $x ]] && P_CMDS+=("sudo rm -f $x $x.sig|damaged download"); done < <(parse_corrupt_files)
            _plan_mirrors
            P_CMDS+=("sudo pacman -Syy --noconfirm|downloads databases from the new mirrors")
            touches="/etc/pacman.d/mirrorlist (a backup is kept)." ;;
        FILE_CONFLICT) what="Files that a package wants to install already exist on disk."
            local o ts; ts=$(date +%Y%m%d-%H%M%S)
            while IFS='|' read -r x o; do
                [[ -n $x ]] || continue
                [[ -z $o ]] && o=$(LC_ALL=C pacman -Qoq "$x" 2>/dev/null | head -1)
                if [[ -n $o ]]; then P_CMDS+=("@leave $x alone|owned by package '$o': never touched, follow the Arch news instead")
                else P_CMDS+=("sudo mv $x /var/lib/smart-update/conflict-backup/$ts$x|not owned by any package, so it is a leftover; moved, not deleted"); fi
            done < <(parse_file_conflicts)
            touches="Moves the listed unowned files into /var/lib/smart-update/conflict-backup/."
            P_UNDO="sudo cp -a /var/lib/smart-update/conflict-backup/$ts/. /" ;;
        PKG_CONFLICT) what="Two packages conflict and pacman needs your decision (usually: replace the old one)."
            P_CMDS=("@retry the same pacman command WITHOUT --noconfirm, inside 'script' so you can answer pacman's 'Remove X? [y/N]' question yourself")
            touches="Only what you approve in pacman's own question." ;;
        DEPENDENCY) what="An installed package blocks the update because it needs an old version of something."
            local foreign; foreign=$(pacman -Qmq 2>/dev/null)
            for x in $(parse_dep_blockers); do
                if grep -qx -- "$x" <<<"$foreign"; then
                    if [[ $(LC_ALL=C pacman -Qi "$x" 2>/dev/null | awk -F': ' '/^Required By/ {print $2}') == None* ]]; then
                        P_CMDS+=("sudo pacman -R --noconfirm $x|AUR package; asked first; only if it is on the AUR and a helper can rebuild it")
                    else
                        P_CMDS+=("sudo pacman -Rdd --noconfirm $x|removes only $x; the packages that need it stay installed; asked first")
                    fi
                    P_CMDS+=("@after the update: $h -S --rebuild --noconfirm $x|rebuilds it against the new version right away")
                else P_CMDS+=("@repo package $x: refresh the mirrors|the mirror is mid-sync, so the mirrors are refreshed instead"); fi
            done
            grep -q '@repo package' <<<"${P_CMDS[*]}" || (( ${#P_CMDS[@]} == 0 )) && { _plan_mirrors; P_CMDS+=("sudo pacman -Syy --noconfirm"); }
            if grep -q '@repo package' <<<"${P_CMDS[*]}" || ! grep -q 'pacman -R' <<<"${P_CMDS[*]}"; then touches="/etc/pacman.d/mirrorlist (a backup is kept) and the package databases."
            else touches="Removes the blocking AUR package(s) you approve and rebuilds them afterwards."; fi ;;
        AUR_PGP) what="An AUR package's source is signed with a key you do not have."
            for x in $(parse_pgp_keys); do
                P_CMDS+=("gpg --import <PKGBUILD folder>/keys/pgp/*.asc|if the package ships the key"
                         "curl https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$x | gpg --import|then keys.openpgp.org and pgp.mit.edu, over HTTPS (also through DNS-over-HTTPS or your proxy when those are in use)"
                         "gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $x|then gpg's own keyserver access"
                         "gpg --list-keys $x|checks that the key really arrived (the old version said 'fixed' even when every server was blocked)")
            done
            P_CMDS+=("@if no source works: skip that AUR package for this run|the other AUR packages still update")
            touches="Your user's GnuPG keyring (~/.gnupg) only." ;;
        AUR_BUILD) what="An AUR package failed to build; leftovers from an earlier build often cause this."
            for x in $(parse_failed_aur_pkgs); do P_CMDS+=("git -C ~/.cache/<helper>/$x clean -fdx && git -C ~/.cache/<helper>/$x reset --hard|wipes that package's build folder"); done
            touches="AUR build folders in ~/.cache only." ;;
        OOM) what="A build ran out of memory."
            P_CMDS=("export MAKEFLAGS=-j$(( $(nproc 2>/dev/null || echo 2) > 2 ? $(nproc 2>/dev/null || echo 2) / 2 : 1 ))|the retry compiles with half the CPU threads, using less memory")
            touches="Nothing; only the next build's settings." ;;
        DKMS) what="A kernel module (DKMS) could not be built for the new kernel."
            lst=""; for x in $(installed_kernels); do pacman -Q "$x-headers" &>/dev/null || lst+="$x-headers "; done
            if [[ -n $lst ]]; then P_CMDS=("sudo pacman -S --needed --noconfirm $lst|missing kernel headers; protected step")
            else P_CMDS=("@nothing to install|headers are present, the module itself does not support the new kernel yet"); fi
            touches="Installs kernel header packages only." ;;
        HOOK) what="A pacman hook (usually the boot image builder) failed."
            P_CMDS=("sudo mkinitcpio -P|rebuilds every boot image and shows only its errors; protected step")
            touches="Boot images in /boot." ;;
        FLATPAK) what="Flatpak's installation data is inconsistent."
            P_CMDS=("flatpak repair --user" "sudo flatpak repair"); touches="Flatpak's own data only." ;;
        REMOVED_REPO) lst=$(removed_repos_in_conf | tr '\n' ' ')
            what="Removes the retired repositories ${lst:-?}from /etc/pacman.conf. Their packages live in [extra] / [core-testing] / [extra-testing] now, so nothing is lost."
            P_CMDS=("sudo cp -a /etc/pacman.conf /etc/pacman.conf.smart-update-<date>.bak|backup first")
            for x in $lst; do P_CMDS+=("@delete the [$x] section (its header and Include/Server lines)"); done
            P_CMDS+=("sudo pacman -Syy --noconfirm|downloads the databases again")
            touches="/etc/pacman.conf (backup kept)."; P_UNDO="sudo cp -a /etc/pacman.conf.smart-update-<date>.bak /etc/pacman.conf" ;;
        IGNORED_PKG) lst=$(ignored_blockers | tr '\n' ' ')
            what="The update needs a newer ${lst:-held-back package}than IgnorePkg allows. This run upgrades it once."
            P_CMDS=("cp /etc/pacman.conf $TMP/pacman.conf|a private copy for this run"
                    "@remove ${lst:-the package} from the IgnorePkg line of that copy"
                    "@retry with: sudo pacman --config $TMP/pacman.conf -Su")
            touches="Upgrades ${lst:-that package}. /etc/pacman.conf is not changed: it stays held back in future runs." ;;
        PACMAN_BROKEN) what="pacman cannot start, so the upgrade is finished with pacman-static, a version with every library built in."
            P_CMDS=("curl -fL -o $TMP/pacman-static $PACMAN_STATIC_URL|the build the AUR package pacman-static uses"
                    "$TMP/pacman-static -V|checks that it runs"
                    "sudo $TMP/pacman-static -Syu --noconfirm|completes the upgrade; package signatures are still checked; protected step")
            touches="Installs the pending updates (which repairs pacman). The downloaded file is deleted when the script ends." ;;
        NO_SERVERS) what="Gives pacman working mirrors again."
            _plan_mirrors
            [[ $DISTRO_ID == arch ]] && P_CMDS+=("@if no mirror list can be built: add 'Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch' at the top of /etc/pacman.d/mirrorlist|Arch's own worldwide mirror")
            P_CMDS+=("sudo pacman -Syy --noconfirm")
            touches="/etc/pacman.d/mirrorlist (backup kept)." ;;
        AUR_HELPER_BROKEN) x=$(find_aur_helper)
            what="Rebuilds the AUR helper ($x) so it works with the installed pacman."
            P_CMDS=("git clone https://aur.archlinux.org/<installed variant: $x-bin / $x-git / $x>.git|in a temporary folder"
                    "makepkg -si -f --noconfirm|build and reinstall it"
                    "@if it still does not start: build '$x' from source the same way|compiled against the current libalpm")
            touches="Reinstalls the AUR helper only." ;;
        AUR_DEP_MISSING) lst=$(for x in $(parse_wanted_by); do pacman -Qq "$x" &>/dev/null && printf '%s ' "$x"; done)
            what="Skips ${lst:-the affected AUR package }this run, because one of its dependencies no longer exists."
            P_CMDS=("@retry the AUR update with --ignore ${lst// /,}|every other AUR package still updates")
            touches="Nothing. The skipped package keeps its current version." ;;
        AUR_TOOLCHAIN) what="Installs the tools makepkg needs to build AUR packages."
            P_CMDS=("sudo pacman -S --needed --noconfirm base-devel debugedit|protected step")
            touches="Installs the build tool packages only." ;;
        PARTIAL) what="Makes every program match the installed libraries again."
            P_CMDS=("sudo pacman -Syu --noconfirm|only if repo updates are pending: repo programs get their matching libraries"
                    "@scan AUR packages: ELF files that need a missing library (ldd, or checkrebuild if installed), and modules installed for an older Python or Perl"
                    "$h -S --rebuild --noconfirm <those packages>|prebuilt (-bin) packages are only listed: rebuilding them does not help")
            touches="Upgrades pending packages and rebuilds the broken AUR packages." ;;
        SERVICE_FAILED) (( ${#FAILED_UNITS[@]} )) || collect_failed_units
            what="Clears the failed state of each failed service and starts it again, then checks that it really runs."
            for x in "${FAILED_UNITS[@]}"; do
                if [[ $x == user:* ]]; then lst="systemctl --user"; else lst="sudo systemctl"; fi
                if unit_restartable "${x%%:*}" "${x#*:}"; then
                    P_CMDS+=("$lst reset-failed ${x#*:} && $lst restart ${x#*:}|then: is it active after 3 s? If not, its last log lines are shown")
                else
                    P_CMDS+=("$lst reset-failed ${x#*:}|a finished app launch or not a service: only the red 'failed' mark is cleared")
                fi
            done
            touches="Starts services that are currently stopped. Nothing that is running is touched." ;;
        TOOL_REBUILD) what="Finds AUR packages that a library, Python or Perl update broke, and rebuilds them."
            P_CMDS=("@for each AUR package: ldd on its programs and libraries (or checkrebuild if installed) — 'not found' means it must be rebuilt"
                    "@packages with files in /usr/lib/python3.X or /usr/lib/perl5/5.X of an older version"
                    "$h -S --rebuild --noconfirm <those packages>|asked first; -bin packages are only listed")
            touches="Rebuilds the AUR packages you approve." ;;
        TOOL_STALE) what="Prepares a system that was not updated for a long time, then you can run the full update."
            P_CMDS=("@remove retired repositories ([community], [testing]…) from /etc/pacman.conf|backup kept; only if present")
            _plan_mirrors
            P_CMDS+=("sudo pacman -Sy|fresh databases"
                     "sudo pacman -S --needed --noconfirm archlinux-keyring|new packager keys first (only the keyring; the full update follows right after)")
            touches="/etc/pacman.conf (only if retired repos are listed), the mirror list (backup kept), the keyring."
            note="Run the full smart update right after this: databases are fresh but packages are not upgraded yet." ;;
        SNAP_STORE) what="snapd could not reach the Snap Store (api.snapcraft.io). The route that works from this network is found and used for this run only."
            P_CMDS=("@if /etc/hosts pins api.snapcraft.io to an address that does not answer: comment that line out|backup: /etc/hosts.smart-update.bak"
                    "curl https://api.snapcraft.io/v2/snaps/info/core|direct; if it answers, the failure was a dropped connection: restart snapd (only when it is idle) and retry"
                    "curl --resolve api.snapcraft.io:443:<ip> …|every Canonical front end (DNS-over-HTTPS answers, related store hosts, known addresses); also checks that a snap file really downloads"
                    "echo '<ip> api.snapcraft.io $SNAP_ROUTE_TAG' | sudo tee -a /etc/hosts|the first address that works; removed again right after the Snap step"
                    "sudo snap set system proxy.https=<local proxy>|only if no address works but a local HTTP proxy does; your old setting is restored afterwards")
            touches="/etc/hosts (one tagged line, removed after the Snap step) or snapd's proxy setting (restored afterwards)."
            P_UNDO="sudo sed -i '/smart-update: temporary Snap Store route/d' /etc/hosts" ;;
        SNAPD_DOWN) what="Starts the snapd daemon so snap commands work."
            P_CMDS=("sudo systemctl enable --now snapd.socket" "sudo systemctl enable --now snapd.apparmor.service|on Arch, needed to run snaps" "sudo systemctl restart snapd.service" "sudo snap wait system seed.loaded|up to 2 min")
            touches="Enables snapd's services." ;;
        SNAP_CHANGE) what="Waits for the snap operation that is already running, aborting it only if it is stuck."
            P_CMDS=("snap watch <id>|up to 5 min" "sudo snap abort <id>|only if it still has not finished; snapd rolls it back")
            touches="Nothing, unless a stuck change has to be aborted." ;;
        SNAP_RUNNING) lst=$(grep -oE 'snap "[^"]+" has running apps' "$CLEAN_LOG" 2>/dev/null | cut -d'"' -f2 | sort -u | tr '\n' ' ')
            what="Updates every snap except the open ones (${lst:-?}); those update after you close them."
            P_CMDS=("sudo snap refresh <every snap with an update except ${lst:-the open ones}>")
            touches="Snaps only." ;;
        SNAP_SEED) what="Lets snapd finish its first-time setup."
            P_CMDS=("sudo systemctl restart snapd.seeded.service snapd.service" "sudo snap wait system seed.loaded|up to 3 min"); touches="Nothing." ;;
        SNAP_CLASSIC) what="Creates the /snap link classic snaps need."
            P_CMDS=("sudo ln -s /var/lib/snapd/snap /snap"); touches="Adds the /snap symlink."; P_UNDO="sudo rm /snap" ;;
        SNAP_MOUNT) what="Makes squashfs available so snaps can be mounted."
            P_CMDS=("@if the running kernel was replaced by the update: nothing can load the module — reboot|noted in the summary"
                    "sudo modprobe squashfs loop" "sudo systemctl restart snapd.service")
            touches="Loads kernel modules." ;;
        SNAP_SPACE) what="Frees the space snaps use for old revisions."
            P_CMDS=("sudo snap remove <name> --revision=<rev>|every disabled (old) revision" "sudo snap set system refresh.retain=2|keep 2 revisions instead of 3 from now on"
                    "sudo find /var/lib/snapd/cache -type f -links 1 -delete|cached downloads no snap uses")
            touches="Removes old snap revisions you cannot run any more." ;;
        SNAP_APPARMOR) what="Loads the AppArmor profiles snaps need."
            P_CMDS=("sudo systemctl enable --now apparmor.service snapd.apparmor.service" "sudo systemctl restart snapd.apparmor.service snapd.service"); touches="Enables AppArmor services." ;;
        FLATPAK_REMOTE) what="Makes the Flatpak remotes usable again."
            P_CMDS=("flatpak remote-modify --enable <remote>|user and system remotes" "flatpak remote-modify --url=https://dl.flathub.org/repo/ flathub|only if the address differs"
                    "flatpak remote-modify --gpg-import=flathub.gpg flathub|key from https://dl.flathub.org/repo/flathub.gpg" "flatpak update --appstream"
                    "sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo|only if Flathub apps are installed but the remote is gone")
            touches="Flatpak remote settings only." ;;
        FLATPAK_HELPER) what="Restarts the services system-wide Flatpak installs go through."
            P_CMDS=("sudo systemctl restart polkit.service flatpak-system-helper.service"); touches="Nothing permanent." ;;
        FLATPAK_SPACE) what="Removes Flatpak runtimes and extensions no app uses."
            P_CMDS=("flatpak uninstall --user --unused" "sudo flatpak uninstall --system --unused" "flatpak repair"); touches="Unused Flatpak runtimes." ;;
        FLATPAK_NET) what="Waits until Flathub answers, then retries."
            P_CMDS=("curl https://dl.flathub.org/repo/summary.idx|every 5 s, up to 60 s"); touches="Nothing." ;;
        DB_VERSION) what="Converts pacman's local database to the format the new pacman needs."
            P_CMDS=("sudo pacman-db-upgrade"); touches="/var/lib/pacman/local (format only)." ;;
        PACMAN_CONF) what="Disables the pacman.conf lines pacman no longer understands."
            while IFS='|' read -r x cond lst; do [[ -n $x ]] && P_CMDS+=("sudo sed -i '${cond}s/^/# /' $x|line $cond: '$lst' is not a pacman option; backup kept next to the file"); done < <(pacman_conf_bad_lines)
            (( ${#P_CMDS[@]} )) || P_CMDS=("@only 'directive not recognized' errors are fixed automatically; other errors are shown so you can fix the line")
            touches="The named lines of the config file (backup kept)." ;;
        STALE_HOOK) what="Removes pacman hooks that call programs which no longer exist."
            while IFS='|' read -r x cond lst; do
                if [[ -n $lst ]]; then P_CMDS+=("sudo pacman -S $lst|$x runs $cond, which is missing")
                else P_CMDS+=("sudo mv $x /var/lib/smart-update/removed/<date>$x|left by a removed program; runs $cond, which is missing"); fi
            done < <(stale_hooks)
            touches="Moves leftover hooks into /var/lib/smart-update/removed/." ;;
        GNUPG_PERMS) what="Gives your ~/.gnupg back to you with private permissions."
            P_CMDS=("sudo chown -R $(id -un): ${GNUPGHOME:-~/.gnupg}" "chmod 700 ${GNUPGHOME:-~/.gnupg}; chmod 600 its files"); touches="${GNUPGHOME:-~/.gnupg} permissions." ;;
        GPG_AGENT) what="Restarts gpg's agents and removes stale lock files."
            P_CMDS=("gpgconf --kill all" "sudo gpgconf --homedir /etc/pacman.d/gnupg --kill all" "rm ~/.gnupg/*.lock /etc/pacman.d/gnupg/*.lock"); touches="Nothing permanent." ;;
        BUSY_FILE) what="Waits a moment for the program holding the file, then retries."
            P_CMDS=("sudo fuser -v <file>|shows which program holds it"); touches="Nothing." ;;
        SYMLINKS) (( ${#LINKS[@]} )) || collect_links
            what="Repairs the broken links that matter; harmless ones (tools newer JDKs dropped, package quirks, optional features) are only listed."
            local lk_k lk_l lk_t lk_o lk_n
            for x in "${LINKS[@]}"; do
                IFS='|' read -r lk_k lk_l lk_t lk_o lk_n <<<"$x"
                case $lk_k in
                    JAVA_DEFAULT) P_CMDS+=("sudo archlinux-java fix|$lk_l: $lk_n") ;;
                    REINSTALL)    P_CMDS+=("sudo pacman -S $lk_o|$lk_l: $lk_n") ;;
                    UNIT|LEFTOVER)
                        if [[ $lk_l == "$HOME"/* ]]; then P_CMDS+=("mv ${lk_l/#$HOME/\~} ${STATE_DIR/#$HOME/\~}/removed-links${lk_l#"$HOME"}|$lk_n")
                        else P_CMDS+=("sudo mv $lk_l /var/lib/smart-update/removed/<date>$lk_l|$lk_n"); fi ;;
                    RESOLV)       P_CMDS+=("sudo systemctl enable --now systemd-resolved|$lk_l → $lk_t: $lk_n") ;;
                    LOCALTIME)    P_CMDS+=("sudo pacman -S tzdata|$lk_l → $lk_t: $lk_n; if the zone was renamed: sudo timedatectl set-timezone <Zone>") ;;
                esac
            done
            grep -q 'systemd' <<<"${P_CMDS[*]}" && P_CMDS+=("sudo systemctl daemon-reload")
            touches="Moves dead links into /var/lib/smart-update/removed/ (links in your home: ${STATE_DIR/#$HOME/\~}/removed-links/), reinstalls packages whose files are missing."
            P_UNDO="sudo cp -a /var/lib/smart-update/removed/<date>/. /" ;;
        UNKNOWN) what="The error is not in the knowledge base; this is a generic retry."
            P_CMDS=("sudo pacman -Syy --noconfirm|downloads all package databases fresh")
            touches="Package databases only." ;;
        TOOL_AURCLEAN) what="Frees space and fixes stale builds by clearing AUR build folders."
            P_CMDS=("rm -rf ~/.cache/paru/clone/*/{src,pkg} ~/.cache/yay/*/{src,pkg} ~/.cache/paru/clone/*/*.pkg.tar.* ~/.cache/yay/*/*.pkg.tar.*")
            touches="AUR build folders in ~/.cache only." ;;
        TOOL_PACNEW) what="Merges configuration files that a package update left as .pacnew/.pacsave."
            P_CMDS=("sudo DIFFPROG='${DIFFPROG:-vim -d}' pacdiff|for each file you choose: view, merge, replace or skip")
            touches="Only the config files you choose in pacdiff." ;;
        TOOL_ORPHANS) what="Removes packages nothing needs any more and old cached versions."
            lst=$(pacman -Qdtq 2>/dev/null | tr '\n' ' ')
            [[ -n $lst ]] && P_CMDS+=("sudo pacman -Rns --noconfirm $lst|asked first; protected step")
            P_CMDS+=("sudo paccache -rk$PACCACHE_KEEP|keeps the last $PACCACHE_KEEP versions" "sudo paccache -ruk0|cache of uninstalled packages"
                     "sudo journalctl --vacuum-time=$JOURNAL_KEEP|only if the journal is over 1 GB")
            touches="Removes unneeded packages (after you confirm) and cached files." ;;
        *) issue_meta "$c"
            what=$IWHY; note="There is no automatic fix for this. Do it by hand: $IHINT" ;;
    esac
    printf '   %s┌ What this fix does%s\n' "$BOLD$CYAN" "$NC"
    fold -s -w 76 <<<"$what" | sed "s/^/   ${CYAN}│${NC} /"
    [[ -n $note ]] && fold -s -w 76 <<<"$note" | sed "s/^/   ${CYAN}│${NC} ${YELLOW}/; s/\$/${NC}/"
    if (( ${#P_CMDS[@]} )); then
        printf '   %s│%s %sSteps, in order (lines with $ are the exact commands):%s\n' "$CYAN" "$NC" "$BOLD" "$NC"
        for entry in "${P_CMDS[@]}"; do
            i=$(( i + 1 )); cmd=${entry%%|*}; cond=""; [[ $entry == *"|"* ]] && cond=${entry#*|}
            if [[ $cmd == @* ]]; then printf '   %s│%s  %2d. %s\n' "$CYAN" "$NC" "$i" "${cmd#@}"
            else printf '   %s│%s  %2d. %s$ %s%s\n' "$CYAN" "$NC" "$i" "$GREEN" "$cmd" "$NC"; fi
            [[ -n $cond ]] && printf '   %s│%s      %s(%s)%s\n' "$CYAN" "$NC" "$GRAY" "$cond" "$NC"
        done
    fi
    [[ -n $touches ]] && fold -s -w 76 <<<"Changes to your system: $touches" | sed "s/^/   ${CYAN}│${NC} /"
    [[ -n $P_UNDO ]] && fold -s -w 76 <<<"Undo: $P_UNDO" | sed "s/^/   ${CYAN}│${NC} /"
    printf '   %s└%s\n' "$CYAN" "$NC"
}

apply_fixes() {  # returns 0 if at least one fix was applied
    local c applied=0 order=()
    [[ $FIX_MODE == off ]] && { log_info "Auto-fix disabled (--no-fix). Apply the manual fix above."; return 1; }
    for c in "${ISSUES[@]}"; do [[ $c == BLOCKED_DL ]] || order+=("$c"); done
    [[ " ${ISSUES[*]} " == *" BLOCKED_DL "* ]] && order+=(BLOCKED_DL)
    for c in "${order[@]}"; do
        issue_meta "$c"
        declare -F "fix_$c" >/dev/null || continue
        [[ $c == UNKNOWN && ! $DIAG_DOMAIN =~ ^(pacman|snap|flatpak)$ ]] && continue
        [[ $IRISK == none ]] && continue
        if (( ${FIX_COUNT[$c]:-0} >= 2 )); then
            log_warning "Fix for '$ITITLE' was already tried twice — not repeating it"; continue
        fi
        if [[ $FIX_MODE == auto ]]; then
            if [[ $IRISK == risky && $ALLOW_RISKY_AUTO != true ]]; then
                log_warning "Skipping risky fix '$ITITLE' in auto mode (use --risky to allow)"; continue
            fi
            fix_plan "$c" | strip_ansi | sed 's/^/[PLAN] /' >>"$LOG_FILE" 2>/dev/null
        else
            ask_fix "$c"; local ans=$?
            (( ans == 2 )) && { log_info "Stopped applying fixes for this step"; return 1; }
            (( ans == 1 )) && continue
        fi
        "fix_$c"; local frc=$?
        if (( frc == 3 )); then   # deferred to the next attempt (counts as a try)
            FIX_COUNT[$c]=$(( ${FIX_COUNT[$c]:-0} + 1 ))
        elif (( frc == 0 )); then
            applied=1
            FIX_COUNT[$c]=$(( ${FIX_COUNT[$c]:-0} + 1 ))
            FIXES_APPLIED+=("$ITITLE")
            log_success "Fix applied: $ITITLE"
        else
            FIX_COUNT[$c]=$(( ${FIX_COUNT[$c]:-0} + 1 ))
            log_warning "Fix for '$ITITLE' did not help"
            # nothing else can work without these (unless other files downloaded fine: then try the rescue)
            [[ ( $c == NETWORK && " ${ISSUES[*]} " != *" BLOCKED_DL "* ) || $c == SUDO ]] && return 1
        fi
    done
    (( applied ))
}

# ======================================================================
# RECOVERY RUNNER
# ======================================================================
run_logged() {  # run a command, show + capture output in $ATTEMPT_LOG
    if (( INTERACTIVE_NEXT )) && [[ -t 0 ]]; then
        INTERACTIVE_NEXT=0
        local args=() a
        for a in "$@"; do [[ $a == --noconfirm || $a == --no-confirm ]] || args+=("$a"); done
        log_warning "Answer pacman's questions below. Once it starts installing, do not press Ctrl+C or $STOP_KEY_LABEL until it has finished."
        script -qefc "$(printf '%q ' "${args[@]}")" "$ATTEMPT_LOG"
        a=$?; check_pending_stop; return "$a"
    fi
    state_write
    if [[ $PANEL_ON == true ]]; then    # full output goes to the log; the screen shows a condensed version
        run_guarded "${GUARD:-auto}" "$@" 2>&1 | tee "$ATTEMPT_LOG" | upd_filter
    else
        run_guarded "${GUARD:-auto}" "$@" 2>&1 | tee "$ATTEMPT_LOG"
    fi
    return "${PIPESTATUS[0]}"
}

run_step() {  # run_step "label" domain runner_function
    local label=$1 dom=$2 runner=$3 attempt=1 rc
    DIAG_DOMAIN=$dom
    while :; do
        ATTEMPT_LOG="$TMP/attempt_${runner}_${attempt}.log"; : >"$ATTEMPT_LOG"
        "$runner"; rc=$?
        cat "$ATTEMPT_LOG" >>"$LOG_FILE" 2>/dev/null
        if (( rc == 0 )); then
            post_scan "$dom"
            (( attempt > 1 )) && log_success "$label succeeded after $attempt attempts"
            return 0
        fi
        log_error "$label failed (attempt $attempt/$MAX_ATTEMPTS, exit code $rc)"
        notify "Problem detected" "$label failed — diagnosing" normal
        diagnose "$ATTEMPT_LOG" "$dom"
        report_diagnosis
        (( attempt >= MAX_ATTEMPTS )) && break
        apply_fixes || break
        attempt=$(( attempt + 1 ))
        log_info "Retrying: $label (attempt $attempt/$MAX_ATTEMPTS)"
    done
    UNRESOLVED+=("$label: $(issue_meta "${ISSUES[0]}"; echo "$ITITLE")")
    notify "Update blocked" "$label: see the diagnosis in the terminal/log" critical
    return 1
}

post_scan() {  # non-fatal problems in a successful run (hooks, dkms, locale, flatpak remotes)
    if grep -qE 'Setting locale failed|Failed to set default locale' "$ATTEMPT_LOG" 2>/dev/null && [[ ! -e $TMP/locale_checked ]]; then
        : >"$TMP/locale_checked"; check_locale
    fi
    if [[ $1 == flatpak ]] && (( $(grep -c "No such ref .* in remote" "$ATTEMPT_LOG" 2>/dev/null) > 3 )); then
        log_warning "Flatpak could not read its remote (flathub) — usually the same network/DNS problem; apps were NOT checked for updates"
        log_info "Retry later, or: flatpak update --appstream && flatpak repair --user"
    fi
    if grep -qE 'ldconfig: .* is not a symbolic link' "$ATTEMPT_LOG" 2>/dev/null && [[ ! -e $TMP/ldconfig_noted ]]; then
        : >"$TMP/ldconfig_noted"
        log_info "ldconfig said some libraries are 'not a symbolic link' — harmless: the package ships a real file where ldconfig expects a link (a packaging quirk). Nothing is broken; it disappears when the package is fixed upstream."
        grep -oE 'ldconfig: [^ ]+ is not a symbolic link' "$ATTEMPT_LOG" | sort -u | head -5 | while read -r _ f _; do
            printf '%s  (owner: %s)\n' "$f" "$(pacman -Qqo "$f" 2>/dev/null || echo 'no package')"; done | detail
    fi
    [[ $1 == pacman ]] || return 0
    local saved=("${ISSUES[@]}")
    CLEAN_LOG="$ATTEMPT_LOG.clean"; strip_ansi <"$ATTEMPT_LOG" | grep -vE '^Packages \([0-9]+\) ' >"$CLEAN_LOG"
    ISSUES=()
    grep -qiE 'Bad return status for module build|dkms.*(failed|error)' "$CLEAN_LOG" && add_issue DKMS
    { grep -qiE 'command failed to execute correctly' "$CLEAN_LOG" || hook_section_error; } && add_issue HOOK
    if (( ${#ISSUES[@]} )); then
        log_warning "The update finished, but post-install steps reported problems:"
        local c; for c in "${ISSUES[@]}"; do ISSUES_SEEN+=("$c"); done
        report_diagnosis
        apply_fixes || UNRESOLVED+=("Post-install: $(issue_meta "${ISSUES[0]}"; echo "$ITITLE")")
    fi
    ISSUES=("${saved[@]}")
}

# ======================================================================
# RUNNERS
# ======================================================================
runner_sync() { GUARD=safe run_logged sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Sy --noconfirm; }

runner_keyring() { GUARD=keyring run_logged sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -S --needed --noconfirm "${KEYRINGS_TO_UPDATE[@]}"; }

runner_install() {  # queued requirements (see deps_install) are installed in the same transaction
    local extra=(); mapfile -t extra < <(deps_pending)
    (( ${#extra[@]} )) && extra=(--needed "${extra[@]}")
    GUARD=install run_logged sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Su --noconfirm "${extra[@]}"
    local rc=$?; (( rc == 0 && ${#extra[@]} )) && rm -f "$STATE_DIR/deps_pending"
    return $rc
}

pending_download_bytes() {  # bytes still to download, -1 if unknown
    local out rc total=0 f s d found
    out=$(LC_ALL=C pacman "${PAC_OPTS[@]}" -Sup --print-format '%f %s' 2>/dev/null); rc=$?
    (( rc != 0 )) && { echo -1; return; }
    while read -r f s; do
        [[ $s =~ ^[0-9]+$ ]] || continue
        found=0; for d in "${CACHE_DIRS[@]}"; do [[ -e $d/$f ]] && found=1; done
        (( found )) || total=$(( total + s ))
    done <<<"$out"
    echo "$total"
}

runner_download() {
    local expected rcf sub base_c base_t base_n c got pct prev_got=0 prev_t speed=0 eta txt dt now rc
    expected=$(pending_download_bytes)
    if (( expected == 0 )); then log_success "All packages are already in the cache"; return 0; fi
    rcf="$TMP/download.rc"; rm -f "$rcf"
    base_c=$(cache_bytes); base_n=$(net_rx_total); base_t=$(now_ms); prev_t=$base_t
    if (( expected > 0 )); then
        log_info "Need to download $(human "$expected")"
        progress_open "Downloading $(human "$expected") of updates…"
    else
        log_info "Download size unknown — showing live amount"
        progress_open "Downloading updates…" pulsate
    fi
    ( sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -Suw --noconfirm </dev/null >"$ATTEMPT_LOG" 2>&1; echo $? >"$rcf" ) &
    sub=$!
    local guarded=false; keys_begin && guarded=true
    while [[ ! -s $rcf ]]; do
        c=$(( $(cache_bytes) - base_c ))
        (( c <= 0 )) && c=$(( $(net_rx_total) - base_n ))   # fallback when cache is not readable yet
        (( c < 0 )) && c=0
        got=$c
        now=$(now_ms); dt=$(( now - prev_t ))
        if (( dt >= 1000 )); then speed=$(( (got - prev_got) * 1000 / dt )); (( speed < 0 )) && speed=0; prev_got=$got; prev_t=$now; fi
        if (( expected > 0 )); then
            (( got > expected )) && got=$expected
            pct=$(( got * 100 / expected )); (( pct > 99 )) && pct=99
            eta="--:--"; (( speed > 0 )) && eta=$(fmt_secs $(( (expected - got) / speed )))
            txt="$(human "$got")/$(human "$expected") 📶 run $(human "$(net_used)") ⚡$(human "$speed")/s ETA $eta"
        else
            pct=-1
            txt="$(human "$got") 📶 run $(human "$(net_used)") ⚡$(human "$speed")/s"
        fi
        progress_update "$pct" "$txt"
        if [[ $guarded == true ]]; then poll_keys safe "$sub"; poll_keys safe "$sub"; else sleep 0.5; fi
    done
    wait "$sub" 2>/dev/null
    keys_end
    rc=$(<"$rcf")
    c=$(( $(cache_bytes) - base_c )); (( c > 0 )) && PKG_DOWNLOADED_BYTES=$(( PKG_DOWNLOADED_BYTES + c ))
    local secs=$(( ($(now_ms) - base_t) / 1000 )); (( secs < 1 )) && secs=1
    if (( rc == 0 )); then
        progress_update 100 "Downloaded $(human "$c") in $(fmt_secs "$secs") (avg $(human $(( c / secs )))/s)"
        progress_close
        log_success "Download complete: $(human "$c") in $(fmt_secs "$secs")"
    else
        progress_close
        tail -n 15 "$ATTEMPT_LOG"
    fi
    return "$rc"
}

runner_aur() {
    local flags=()
    read -ra flags <<<"$AUR_EXTRA_FLAGS"
    case $HELPER in
        pamac) run_logged pamac upgrade --aur --no-confirm ;;
        *)     (( ${#AUR_IGNORE[@]} )) && flags+=(--ignore "$(IFS=,; echo "${AUR_IGNORE[*]}")")
               aur_pacman_flags flags
               run_logged env LC_ALL=C "$HELPER" -Sua --noconfirm "${flags[@]}" ;;
    esac
}

runner_aur_reinstall() {  # --rebuild: build again even if a package file of that version is cached (it would be linked to the old library)
    local flags=(); aur_pacman_flags flags
    [[ $HELPER == paru || $HELPER == yay ]] && flags+=(--rebuild)
    run_logged env LC_ALL=C "$HELPER" -S --noconfirm "${flags[@]}" "${REINSTALL_AFTER[@]}"
}

aur_pacman_flags() {  # aur_pacman_flags ARRAYNAME — paru/yay install repo dependencies with plain pacman, which
    # ignored the slow-network/DoH/proxy settings (the real log stalled on .sig files there). Give them a
    # pacman that uses this run's temporary pacman.conf.
    local -n _f=$1
    [[ ${PAC_OPTS[0]:-} == --config && ( $HELPER == paru || $HELPER == yay ) ]] || return 0
    printf '#!/bin/sh\nexec /usr/bin/pacman --config %q "$@"\n' "${PAC_OPTS[1]}" >"$TMP/pacman-wrap"
    chmod 755 "$TMP/pacman-wrap"
    _f+=(--pacman "$TMP/pacman-wrap")
}

runner_flatpak() {
    GUARD=safe run_logged flatpak update -y --noninteractive
}

runner_snap() {
    if (( ${#SNAP_HOLD[@]} )); then   # open apps: refresh everything else
        local names=()
        mapfile -t names < <(snap refresh --list 2>/dev/null | awk 'NR>1 {print $1}' | grep -vxF -f <(printf '%s\n' "${SNAP_HOLD[@]}"))
        (( ${#names[@]} )) || { echo "Only open snaps have updates (${SNAP_HOLD[*]}); they update once closed" >"$ATTEMPT_LOG"; return 0; }
        GUARD=safe run_logged sudo snap refresh "${names[@]}"; return
    fi
    GUARD=safe run_logged sudo snap refresh
}

# ======================================================================
# PRE-FLIGHT CHECKS
# ======================================================================
# ======================================================================
# REQUIREMENTS — what this script needs, explained, installed on request
# ======================================================================
# "tier|package|commands that prove it is there (- = check the package)|why it is needed|only when"
DEPS_SPEC=(
    "required|sudo|sudo|Runs pacman and the repairs as root, while the script itself stays your normal user."
    "required|curl|curl|Checks the internet connection, reads Arch news and the AUR, tests mirrors and fetches blocked downloads."
    "required|gawk|awk|Reads pacman's output and the logs to work out what went wrong."
    "required|sed|sed|Tidies command output and edits a config line when a fix needs it."
    "required|grep|grep|Recognises error messages in pacman's output."
    "required|findutils|find xargs|Finds leftover files, old caches and broken links."
    "required|util-linux|script flock|Lets pacman ask its questions while the output is recorded, and stops two copies from running at once."
    "required|procps-ng|pgrep|Notices another package manager (Discover, pamac) before touching pacman's lock."
    "recommended|pacman-contrib|checkupdates paccache pacdiff|Counts updates without changing anything, cleans old cached packages and merges .pacnew config files."
    "recommended|reflector|reflector|Picks fast, up-to-date mirrors when downloads are slow or failing.|nomirrors"
    "recommended|git|git|Downloads AUR package recipes, and an AUR helper if you have none.|aur"
    "recommended|base-devel|-|The compilers and tools makepkg needs to build AUR packages.|aur"
    "recommended|rebuild-detector|checkrebuild|Finds AUR programs that a library update broke, so they are rebuilt instead of crashing.|aur"
    "recommended|libnotify|notify-send|Desktop notifications when an update finishes or needs you.|notify"
    "optional|aria2|aria2c|Downloads blocked packages from several mirrors at once — much faster on filtered networks."
    "optional|psmisc|fuser|Shows which program holds a file that blocks an update."
    "optional|lm_sensors|sensors|Adds CPU temperatures to the health report."
    "optional|iproute2|ss|Finds a local proxy (v2ray, clash, Tor…) to route blocked downloads through."
)
DEPS_MISS=()

deps_missing() {  # -> DEPS_MISS: "tier|package|why" for everything not installed (features you use only)
    DEPS_MISS=()
    local e tier pkg cmds why cond c miss
    for e in "${DEPS_SPEC[@]}"; do
        IFS='|' read -r tier pkg cmds why cond <<<"$e"
        case $cond in
            aur)       [[ $DO_AUR == true ]] || continue ;;
            notify)    [[ $NOTIFY_ENABLED == true && -n ${DISPLAY:-${WAYLAND_DISPLAY:-}} ]] || continue ;;
            nomirrors) have pacman-mirrors && continue ;;   # Manjaro ranks mirrors with its own tool
        esac
        miss=0
        if [[ $cmds == - ]]; then pacman -Qq "$pkg" &>/dev/null || miss=1
        else for c in $cmds; do have "$c" || { miss=1; break; }; done; fi
        (( miss )) && DEPS_MISS+=("$tier|$pkg|$why")
    done
}

deps_install() {  # deps_install PKG... -> 0 installed, 2 queued for the next full update, 1 failed
    local s=(sudo) rc
    [[ $EUID -eq 0 ]] && s=()
    if (( EUID != 0 )) && ! have sudo; then
        log_error "sudo is missing, so nothing can be installed as your user. As root: pacman -S sudo, then allow your user with visudo."
        return 1
    fi
    log_info "Installing: $*"
    "${s[@]}" env LC_ALL=C pacman -S --needed --noconfirm "$@" 2>&1 | tee "${TMP:-/tmp}/deps.log" | grep -E '^(error|warning|installing|upgrading|:: )' | grep -v 'Proceed with' | sed 's/^/     /'
    rc=${PIPESTATUS[0]}
    (( rc == 0 )) && { log_success "Installed: $*"; return 0; }
    if grep -qE 'failed retrieving file|target not found|404' "${TMP:-/tmp}/deps.log"; then
        mkdir -p "$STATE_DIR"; printf '%s\n' "$@" >>"$STATE_DIR/deps_pending"
        log_warning "Your package lists are out of date, so these can't be installed on their own yet. They will be installed together with the next full update (installing them alone now could mix old and new packages)."
        return 2
    fi
    log_error "Could not install: $*  — run: sudo pacman -S --needed $*"
    return 1
}

deps_pending() { [[ -s $STATE_DIR/deps_pending ]] && sort -u "$STATE_DIR/deps_pending"; }

deps_check() {  # deps_check [setup] — on the first run, with --setup, or whenever something needed is missing
    local mode=${1:-auto} first=0 e tier pkg why declined body="" b
    local -a req=() rec=() opt=() btn=()
    [[ -f $STATE_DIR/setup_done && $mode != setup ]] || first=1
    deps_missing
    declined=" $(cat "$STATE_DIR/deps_declined" 2>/dev/null | tr '\n' ' ') "
    for e in "${DEPS_MISS[@]}"; do
        IFS='|' read -r tier pkg why <<<"$e"
        [[ $tier != required ]] && { (( first )) || continue; [[ $mode != setup && $declined == *" $pkg "* ]] && continue; }
        [[ " $(deps_pending | tr '\n' ' ') " == *" $pkg "* ]] && continue    # already queued for the next update
        case $tier in required) req+=("$pkg") ;; recommended) rec+=("$pkg") ;; optional) opt+=("$pkg") ;; esac
        body+="$tier|$pkg|$why"$'\n'
    done
    mkdir -p "$STATE_DIR"
    if (( ${#req[@]} + ${#rec[@]} + ${#opt[@]} == 0 )); then
        : >"$STATE_DIR/setup_done"
        [[ $mode == setup ]] && log_success "Everything Arch Smart Update uses is installed$( [[ -n $(deps_pending) ]] && echo " (queued for the next update: $(deps_pending | tr '\n' ' '))")"
        return 0
    fi
    local text="Arch Smart Update uses a few standard Arch packages. Not installed yet:"$'\n'
    for tier in required recommended optional; do
        local head; case $tier in required) head="Needed to run" ;; recommended) head="Recommended" ;; optional) head="Optional extras" ;; esac
        grep -q "^$tier|" <<<"$body" || continue
        text+=$'\n'"$head"$'\n'
        while IFS='|' read -r tier pkg why; do text+="  • $pkg — $why"$'\n'; done < <(grep "^$tier|" <<<"$body")
    done
    local all=("${req[@]}" "${rec[@]}" "${opt[@]}")
    text+=$'\n'"Command: sudo pacman -S --needed ${all[*]}"

    if [[ ! -t 0 && $GUI != true ]]; then   # cron, pipes: never ask
        printf '%s\n' "$text" | sed 's/^/  /' >&2
        if (( ${#req[@]} )); then
            [[ $FIX_MODE == auto ]] && deps_install "${req[@]}" && return 0
            log_error "Missing required packages: ${req[*]} — install them and run again."; exit 1
        fi
        : >"$STATE_DIR/setup_done"; return 0
    fi

    btn=("Install all")
    (( ${#req[@]} && ${#rec[@]} + ${#opt[@]} )) && btn+=("Only what's needed")
    (( ! ${#req[@]} && ${#rec[@]} && ${#opt[@]} )) && btn+=("Skip the extras")
    if (( ${#req[@]} )); then btn+=("Quit"); else btn+=("Not now"); fi
    ui_dialog "📦 Before the first run" "$text" 0 $(( ${#btn[@]} - 1 )) "${btn[@]}"
    b=${btn[TUI_CHOICE]:-}
    case $b in
        "Install all")        deps_install "${all[@]}" ;;
        "Only what's needed") deps_install "${req[@]}"; printf '%s\n' "${rec[@]}" "${opt[@]}" >>"$STATE_DIR/deps_declined" ;;
        "Skip the extras")    deps_install "${rec[@]}"; printf '%s\n' "${opt[@]}" >>"$STATE_DIR/deps_declined" ;;
        "Not now")            printf '%s\n' "${rec[@]}" "${opt[@]}" >>"$STATE_DIR/deps_declined"
                              log_info "Skipped. Run '$PROG --setup' (or Repair tools → Check requirements) to see this again." ;;
        *)                    log_info "Needed to run: ${req[*]}  — install with: sudo pacman -S --needed ${req[*]}"; exit 1 ;;
    esac
    : >"$STATE_DIR/setup_done"
    deps_missing
    for e in "${DEPS_MISS[@]}"; do
        IFS='|' read -r tier pkg why <<<"$e"
        [[ $tier == required && " $(deps_pending | tr '\n' ' ') " != *" $pkg "* ]] && { log_error "Still missing: $pkg — the script can't run without it."; exit 1; }
    done
    return 0
}

check_dependencies() {
    have pacman || { log_error "pacman not found — this script is for Arch-based systems"; exit 1; }
    return 0
}

last_full_upgrade_epoch() {
    local l; l=$(grep -a 'starting full system upgrade' /var/log/pacman.log 2>/dev/null | tail -1)
    l=${l#[}; l=${l%%]*}
    [[ -n $l ]] || { echo 0; return; }
    date -d "$l" +%s 2>/dev/null || echo 0
}

check_news() {
    log_step "Checking Arch Linux news since your last upgrade…"
    local feed last title d ts line important=0
    feed=$(curl -fsS --max-time 10 https://archlinux.org/feeds/news/ 2>/dev/null) || { log_info "Could not fetch the news feed"; return 0; }
    last=$(last_full_upgrade_epoch)
    (( last == 0 )) && { log_info "No previous full upgrade found in pacman.log"; return 0; }
    while IFS= read -r line; do
        case $line in
            '<title>'*)   title=${line#<title>}; title=${title%</title>} ;;
            '<pubDate>'*) d=${line#<pubDate>}; d=${d%</pubDate>}
                          ts=$(date -d "$d" +%s 2>/dev/null || echo 0)
                          if (( ts > last )); then
                              title=$(xml_unescape "$title")
                              NEWS_TITLES+=("$title")
                              [[ $title =~ [Mm]anual\ intervention|requires|replaced|must ]] && important=1
                          fi ;;
        esac
    done < <(grep -oE '<title>[^<]*</title>|<pubDate>[^<]*</pubDate>' <<<"$feed")
    if (( ${#NEWS_TITLES[@]} == 0 )); then log_success "No new Arch news"; return 0; fi
    log_warning "News published since your last full upgrade:"
    local n; for n in "${NEWS_TITLES[@]}"; do echo "     📰 $n"; done
    echo "     Read: https://archlinux.org/news/"
    if (( important )); then
        notify "Manual intervention may be required" "${NEWS_TITLES[0]}" critical
        if [[ $FIX_MODE != auto && $DRY_RUN == false ]]; then
            ui_ask "Arch news may require manual steps for this update. Continue now?" y || { log_info "Aborted so you can read the news."; exit 0; }
        fi
    fi
}

check_partial_state() {
    local sync_ts last ign
    sync_ts=$(stat -c %Z "$DB_PATH/sync/core.db" 2>/dev/null || echo 0)
    last=$(last_full_upgrade_epoch)
    if (( last > 0 && sync_ts > last + 3600 )) && [[ -n $(pacman -Qu 2>/dev/null | head -1) ]]; then
        log_warning "Databases were refreshed after your last full upgrade without upgrading (a 'pacman -Sy' only)."
        log_info "That is a partial-upgrade state. This run completes it — don't install single packages until it finishes."
    fi
    ign=$(pacman-conf IgnorePkg 2>/dev/null | tr '\n' ' ')
    [[ -n ${ign// } ]] && log_warning "Held back by IgnorePkg: $ign— a common cause of partial-upgrade breakage"
    local crit; crit=$(pacman -Qmq 2>/dev/null | grep -xE 'glibc|gcc-libs|systemd|linux|pacman|openssl')
    [[ -n $crit ]] && log_warning "Core packages installed from outside the repos: $(tr '\n' ' ' <<<"$crit")"
    if ! LC_ALL=C pacman -Dk &>"$TMP/dk.log"; then
        log_warning "Local package database consistency issues (pacman -Dk):"
        head -5 "$TMP/dk.log" | sed 's/^/     /'
    fi
    return 0
}

preflight() {
    log_step "Pre-flight checks"
    [[ $EUID -eq 0 ]] && { log_error "Run as your normal user (sudo is used when needed). AUR builds cannot run as root."; exit 1; }
    check_dependencies

    if [[ $DRY_RUN == false ]]; then
        ensure_sudo || exit 1
    fi

    if ! pacman -V &>/dev/null; then
        log_error "pacman itself cannot start:"
        LC_ALL=C pacman -V 2>&1 | head -3 | sed 's/^/     /'
        ISSUES=(PACMAN_BROKEN); CLEAN_LOG=/dev/null; report_diagnosis
        [[ $DRY_RUN == false ]] && apply_fixes || { log_error "Nothing can be updated until pacman works"; exit 1; }
    fi
    local rr; rr=$(removed_repos_in_conf | tr '\n' ' ')
    if [[ -n ${rr// } ]]; then
        log_warning "/etc/pacman.conf still lists repositories Arch has removed: $rr— every database sync would fail"
        ISSUES=(REMOVED_REPO); CLEAN_LOG=/dev/null
        [[ $DRY_RUN == false ]] && apply_fixes
    fi
    if (( $(grep -cE '^[[:space:]]*Server' /etc/pacman.d/mirrorlist 2>/dev/null || echo 0) == 0 )) && [[ $DISTRO_ID == arch ]]; then
        log_warning "The mirror list has no active Server line — pacman could not download anything"
        ISSUES=(NO_SERVERS); CLEAN_LOG=/dev/null
        [[ $DRY_RUN == false ]] && apply_fixes
    fi
    check_stale_system

    if net_ok; then
        log_success "Internet connection OK"
        if ! dns_ok; then
            if dns_dead; then
                log_warning "The internet works, but the system DNS does not answer at all"
                resolver_state
                enable_doh || log_warning "Downloads will fail until DNS works again"
            else
                log_warning "DNS is slow right now (lookup took over 3 s) — downloads may time out; fixes are ready if they do"
            fi
        fi
    else
        ISSUES=(NETWORK); CLEAN_LOG=/dev/null
        if [[ $DRY_RUN == true ]] || ! fix_NETWORK; then log_error "No internet connection after several tries (DNS and direct checks failed) — cannot update."; exit 1; fi
    fi
    check_locale
    check_informant

    if [[ -e $DB_PATH/db.lck ]]; then
        log_warning "Pacman database is locked"
        CLEAN_LOG=/dev/null; ISSUES=(LOCK); issue_details LOCK
        [[ $DRY_RUN == false ]] && { ui_ask "Resolve the lock (wait for / stop the other manager, or remove a stale lock)?" y && fix_LOCK; }
        [[ -e $DB_PATH/db.lck ]] && { log_error "Database is still locked — aborting"; exit 1; }
    fi

    [[ $DRY_RUN == false ]] && ensure_clock

    local p fm
    for p in / "$CACHE_DIR"; do
        fm=$(free_mb "$p")
        if [[ -n $fm ]] && (( fm < MIN_FREE_MB )); then
            log_warning "Only $fm MB free on $(df -P "$p" | awk 'NR==2{print $6}') (minimum $MIN_FREE_MB MB)"
            [[ $DRY_RUN == false ]] && ui_ask "Free disk space now (clean package cache, journal, AUR build files)?" y && fix_DISK
            break
        fi
    done
    if mountpoint -q /boot 2>/dev/null && (( $(free_mb /boot) < 60 )); then
        log_warning "/boot has only $(free_mb /boot) MB free — kernel updates may fail"
    fi

    check_partial_state
    check_news
}

# ======================================================================
# SNAPSHOTS & MIRRORS
# ======================================================================
create_snapshot() {
    case $SNAPSHOT_TOOL in
        zfs)
            have zfs || return 0
            local ds snap
            for ds in $ZFS_DATASETS; do
                snap="arch-update-$(date +%Y%m%d-%H%M%S)"
                log_step "ZFS snapshot $ds@$snap"
                [[ $DRY_RUN == true ]] && { log_info "[DRY-RUN] would snapshot"; continue; }
                if sudo zfs snapshot "$ds@$snap"; then
                    log_success "Snapshot created"
                    sudo zfs list -t snapshot -o name -H -s creation "$ds" 2>/dev/null | grep '@arch-update-' \
                        | head -n "-$ZFS_KEEP_SNAPSHOTS" | while read -r old; do sudo zfs destroy "$old" && log_info "Removed $old"; done
                else log_warning "ZFS snapshot failed"; fi
            done ;;
        snapper)
            have snapper || return 0
            log_step "Snapper snapshot"
            [[ $DRY_RUN == true ]] || sudo snapper -c root create -d "smart-update pre" -c number && log_success "Snapshot created" ;;
        timeshift)
            have timeshift || return 0
            log_step "Timeshift snapshot"
            [[ $DRY_RUN == true ]] || sudo timeshift --create --comments "smart-update pre" --tags O | tail -2 ;;
    esac
}

should_update_mirrors() {
    [[ $FORCE_MIRRORS == true ]] && return 0
    have reflector || have pacman-mirrors || return 1
    [[ -f /etc/pacman.d/mirrorlist ]] || return 0
    local age=$(( ( $(date +%s) - $(stat -c %Y /etc/pacman.d/mirrorlist) ) / 86400 ))
    if (( age >= MIRROR_UPDATE_DAYS )); then log_info "Mirrorlist is $age days old"; return 0; fi
    log_success "Mirrorlist is $age days old — fresh enough"
    return 1
}

find_aur_helper() {  # prints the helper name ONLY (no logging on stdout)
    local h
    have "$AUR_HELPER" && { echo "$AUR_HELPER"; return; }
    for h in paru yay pikaur trizen pamac; do have "$h" && { echo "$h"; return; }; done
    echo none
}

# ======================================================================
# UPDATE PHASES
# ======================================================================
update_official() {
    log_step "Official repositories"
    if [[ $DRY_RUN == true ]]; then
        if have checkupdates; then
            export CHECKUPDATES_DB="$TMP/checkup-db"
            local list; list=$(checkupdates 2>/dev/null)
            if [[ -z $list ]]; then log_success "System is up to date"; return 0; fi
            echo "$list" | head -40 | sed 's/^/     /'
            local sz; sz=$(LC_ALL=C pacman -Sup --dbpath "$CHECKUPDATES_DB" --print-format '%s' 2>/dev/null | awk '{t+=$1} END{print t+0}')
            log_info "[DRY-RUN] $(wc -l <<<"$list") updates, about $(human "$sz") to download (before cache)"
        else
            log_info "[DRY-RUN] install pacman-contrib to preview updates without syncing"
        fi
        return 0
    fi

    if should_update_mirrors; then refresh_mirrors; fi

    run_step "Sync package databases" pacman runner_sync || return 1

    local pending; pending=$(pacman "${PAC_OPTS[@]}" -Qu 2>/dev/null)
    if [[ -z $pending ]]; then
        log_success "Official packages are up to date"
        if [[ -n $(deps_pending) ]]; then   # lists are fresh and nothing else changes: safe to install them now
            local q; mapfile -t q < <(deps_pending)
            deps_install "${q[@]}" && rm -f "$STATE_DIR/deps_pending"
        fi
        return 0
    fi
    local n; n=$(wc -l <<<"$pending")
    log_info "$n package(s) to upgrade:"
    head -30 <<<"$pending" | sed 's/^/     /'
    (( n > 30 )) && echo "     … and $(( n - 30 )) more"
    grep -qE '^(linux|linux-lts|linux-zen|systemd|glibc|nvidia[a-z-]*|mesa) ' <<<"$pending" && log_info "Core components included — a reboot will likely be needed."

    KEYRINGS_TO_UPDATE=()
    local k; for k in $(awk '{print $1}' <<<"$pending" | grep -E -- '-keyring$'); do KEYRINGS_TO_UPDATE+=("$k"); done
    if (( ${#KEYRINGS_TO_UPDATE[@]} )); then
        log_step "Updating keyrings first (${KEYRINGS_TO_UPDATE[*]})"
        run_step "Keyring update" pacman runner_keyring || log_warning "Keyring update failed; continuing (signature errors will be handled)"
    fi

    local exp; exp=$(pending_download_bytes)
    if (( exp > 0 )) && (( $(free_mb "$CACHE_DIR") * 1048576 < exp * 3 + MIN_FREE_MB * 1048576 )); then
        log_warning "Download ($(human "$exp")) may not fit: $(free_mb "$CACHE_DIR") MB free"
        ISSUES=(DISK); CLEAN_LOG=/dev/null; apply_fixes
    fi

    log_step "Downloading packages"
    run_step "Download" pacman runner_download || return 1

    if [[ $DOWNLOAD_ONLY == true ]]; then
        log_success "Updates downloaded to the cache. Run the full update later to install them (nothing is downloaded twice)."
        return 0
    fi
    log_step "Installing updates"
    run_step "Install" pacman runner_install || return 1
    log_success "Official packages upgraded"
    notify "System updated" "$n packages upgraded" low
}

update_aur() {
    [[ $DNS_DEAD == true ]] && { log_step "AUR packages"; dns_still_dead "AUR updates" && return 0; }
    HELPER=$(find_aur_helper)
    if [[ $HELPER == none ]]; then
        if [[ $DRY_RUN == true ]]; then
            log_info "[DRY-RUN] No AUR helper found — a real run would offer to install paru/yay"; return 0
        fi
        if [[ $AUR_BOOTSTRAP == never || $FIX_MODE == auto ]] || [[ $GUI != true && ! -t 0 ]]; then
            log_info "No AUR helper found (install one from the menu, or: $PROG --install-helper paru)"; return 0
        fi
        install_aur_helper || return 0
        HELPER=$(find_aur_helper)
        [[ $HELPER == none ]] && return 0
        log_success "Using the new helper '$HELPER' — continuing with AUR updates"
    fi
    log_step "AUR packages via $HELPER"
    if ! helper_works "$HELPER"; then   # typical after a pacman major update: the helper links the old libalpm
        log_error "$HELPER cannot start:"; "$HELPER" --version 2>&1 | head -2 | sed 's/^/     /'
        ISSUES=(AUR_HELPER_BROKEN); CLEAN_LOG=/dev/null; report_diagnosis
        [[ $DRY_RUN == true ]] && return 0
        apply_fixes || { UNRESOLVED+=("AUR helper $HELPER is broken: rebuild it"); return 0; }
    fi
    if [[ $DRY_RUN == true ]]; then
        [[ $HELPER != pamac ]] && "$HELPER" -Qua 2>/dev/null | sed 's/^/     /'
        log_info "[DRY-RUN] would run: $HELPER -Sua --noconfirm"
        return 0
    fi
    gui_pulse_start "Updating AUR packages with $HELPER"
    run_step "AUR update" aur runner_aur || log_warning "Some AUR packages were not updated (system packages are fine)"
    gui_pulse_stop
    rebuild_pending
}

dns_still_dead() {  # true (and says so) while the system DNS is down
    [[ $DNS_DEAD == true ]] || return 1
    dns_ok && { DNS_DEAD=false; return 1; }
    log_warning "Skipped: $1 needs the system DNS, which is still down (pacman used DNS-over-HTTPS instead). Run again once DNS works."
    SKIPPED_DNS+=("$1"); return 0
}

update_flatpak() {
    have flatpak || return 0
    log_step "Flatpak"
    dns_still_dead "Flatpak" && return 0
    if [[ $DRY_RUN == true ]]; then flatpak remote-ls --updates 2>/dev/null | head -10; return 0; fi
    gui_pulse_start "Updating Flatpak apps"
    run_step "Flatpak update" flatpak runner_flatpak
    local rc=$?
    gui_pulse_stop
    (( rc == 0 )) && flatpak uninstall --unused -y --noninteractive 2>/dev/null | tail -1
}

update_snap() {
    have snap || return 0
    log_step "Snap"
    dns_still_dead "Snap" && return 0
    [[ $DRY_RUN == true ]] && { snap refresh --list 2>/dev/null; return 0; }
    snap_kept_recheck
    SNAP_HOLD=()
    run_step "Snap refresh" snap runner_snap
    local rc=$?
    snap_route_restore
    (( ${#SNAP_HOLD[@]} )) && log_info "Not updated because they are open: ${SNAP_HOLD[*]} — close them; snapd updates them by itself (or: sudo snap refresh ${SNAP_HOLD[*]})"
    return $rc
}

check_firmware() {
    have fwupdmgr || return 0
    log_step "Firmware (fwupd)"
    [[ $DRY_RUN == true ]] && return 0
    fwupdmgr refresh --force &>/dev/null
    local out; out=$(fwupdmgr get-updates 2>&1)
    if grep -qiE 'no updat|no upgrades' <<<"$out"; then log_success "Firmware is up to date"
    elif grep -qiE 'upgrade|update' <<<"$out"; then log_warning "Firmware updates available — run: fwupdmgr update"; head -15 <<<"$out" | sed 's/^/     /'
    else log_success "No firmware updates"; fi
}

# ======================================================================
# MAINTENANCE & HEALTH
# ======================================================================
install_notices() {  # messages printed by package install scripts that ask the user to do something
    local logs=("$TMP"/attempt_runner_install_*.log) efi
    logs+=(/dev/null)
    if grep -qh 'To use the new features provided in this GRUB update' /dev/null "${logs[@]}" 2>/dev/null; then
        log_step "GRUB was updated"
        log_info "GRUB's boot code on disk is still the old version. The system boots fine as it is; reinstalling only adds new GRUB features."
        efi=$(findmnt -rno TARGET -t vfat 2>/dev/null | grep -E '^/(boot|efi|boot/efi)$' | head -1)
        if [[ -d /sys/firmware/efi && -n $efi ]]; then
            detail "UEFI system, EFI partition at $efi. When you want the new features, run:"
            detail "  sudo grub-install --target=x86_64-efi --efi-directory=$efi --bootloader-id=GRUB"
        else
            detail "BIOS system. When you want the new features, run (replace sdX with the boot DISK, not a partition):"
            detail "  sudo grub-install --target=i386-pc /dev/sdX"
        fi
        detail "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
        detail "Not done automatically: a wrong grub-install target can make the system unbootable."
    fi
    local gone; gone=$(grep -h 'packages not in the AUR:' /dev/null "$TMP"/attempt_runner_aur*.log 2>/dev/null | tail -1 | sed 's/.*packages not in the AUR: *//')
    if [[ -n $gone ]]; then
        log_info "Installed but no longer in any repository or the AUR (they never get updates or security fixes): $gone"
        detail "They usually were renamed or merged into another package (search: pacman -Ss <name>), or dropped. Remove one you no longer need: sudo pacman -Rns <name>"
    fi
    # "directory permissions differ on X" + "filesystem: 755  package: 700": looser than the package wants is
    # a real problem (e.g. /etc/ssl/private readable by everyone); stricter is a deliberate local choice
    local path fsm pkm
    while IFS='|' read -r path fsm pkm; do
        [[ -n $path && $fsm =~ ^[0-7]+$ && $pkm =~ ^[0-7]+$ ]] || continue
        if (( (8#$fsm & ~8#$pkm) != 0 )); then
            log_warning "$path is $fsm on disk but its package wants $pkm — it is open to more users than intended"
            if [[ $DRY_RUN == false ]] && { [[ $FIX_MODE == auto ]] || ui_ask "Set $path back to $pkm (the package's permissions)?" y; }; then
                sudo chmod "$pkm" "$path" && log_success "$path is $pkm now"
            fi
        else
            log_info "$path is $fsm on disk, stricter than the package's $pkm — a deliberate local choice; harmless"
        fi
    done < <(awk '/directory permissions differ on / {p=$NF; sub(/\/$/, "", p); next}
                  p != "" && /filesystem: [0-7]+ +package: [0-7]+/ {print p "|" $2 "|" $4; p=""}' /dev/null "${logs[@]}" 2>/dev/null | sort -u)
    return 0
}

post_maintenance() {
    install_notices
    log_step "Config files needing attention (.pacnew/.pacsave)"
    local cnt; cnt=$(find /etc -name '*.pac*' 2>/dev/null | grep -cE '\.pac(new|save)$')
    if (( cnt > 0 )); then
        log_warning "$cnt .pacnew/.pacsave file(s) (new default configs that were NOT applied; old settings stay active until merged):"
        find /etc \( -name '*.pacnew' -o -name '*.pacsave' \) -printf '%p  (%TY-%Tm-%Td)\n' 2>/dev/null | head -20 | detail
        have pacdiff && log_info "Merge them with: sudo DIFFPROG=meld pacdiff  (or sudo pacdiff)"
    else log_success "None"; fi

    log_step "Failed systemd services"
    local failed ufailed s
    failed=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    ufailed=$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    if [[ -z $failed && -z $ufailed ]]; then log_success "No failed services"
    else
        local why
        for s in $failed; do
            log_warning "System service failed: $s"
            why=$(explain_service "$s"); [[ -n $why ]] && echo "Why: $why" | detail
            journalctl -u "$s" -n 5 --no-pager -o short 2>/dev/null | detail
            echo "💡 sudo systemctl restart $s   (or clear the failed state: sudo systemctl reset-failed $s)" | detail
        done
        for s in $ufailed; do
            log_warning "User service failed: $s"
            why=$(explain_service "$s"); [[ -n $why ]] && echo "Why: $why" | detail
            journalctl --user -u "$s" -n 5 --no-pager -o short 2>/dev/null | detail
            echo "💡 systemctl --user reset-failed $s" | detail
        done
        # general fix: clear the failed state and restart every failed service, then check it really runs
        collect_failed_units
        if (( ${#FAILED_UNITS[@]} )) && [[ $DRY_RUN == false ]]; then
            local saved_issues=("${ISSUES[@]}")
            ISSUES=(SERVICE_FAILED); ISSUES_SEEN+=(SERVICE_FAILED); CLEAN_LOG=/dev/null
            apply_fixes
            ISSUES=("${saved_issues[@]}")
        fi
    fi

    check_symlinks
}

prune_stale_parts() {  # drop unfinished downloads that are no longer needed (that version or newer is installed)
    local f b name ver inst n=0 bytes=0 sz
    while IFS= read -r f; do
        b=${f##*/}; b=${b%.part}; b=${b%.pkg.tar.*}       # name-pkgver-pkgrel-arch
        b=${b%-*}; ver=${b##*-}; b=${b%-*}; ver="${b##*-}-$ver"; name=${b%-*}
        inst=$(pacman -Q "$name" 2>/dev/null | awk '{print $2}')
        if [[ -n $inst ]] && (( $(vercmp "$inst" "$ver") >= 0 )) \
           || { [[ -z $inst ]] && [[ -n $(find "$f" -mtime +14 2>/dev/null) ]]; }; then
            sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
            if rm -f -- "$f" 2>/dev/null || sudo rm -f -- "$f"; then n=$((n + 1)); bytes=$((bytes + sz)); fi
        fi
    done < <(find "${CACHE_DIRS[@]:-$CACHE_DIR}" "$RESCUE_DIR" -maxdepth 1 -name '*.pkg.tar.*.part' 2>/dev/null)
    (( n )) && log_success "Removed $n unfinished download(s) no longer needed ($(human "$bytes"))"
    return 0
}

cleanup() {
    log_step "Cleaning orphans, package cache and journal"
    [[ $DRY_RUN == true ]] && { log_info "[DRY-RUN] would remove orphans, paccache -rk$PACCACHE_KEEP, vacuum journal"; return 0; }
    local before after orphans
    before=$(df -P / | awk 'NR==2{print $4}')
    orphans=$(pacman -Qdtq 2>/dev/null)
    if [[ -n $orphans ]]; then
        log_info "Orphans: $(tr '\n' ' ' <<<"$orphans")"
        if [[ $FIX_MODE == auto ]] || ui_ask "Remove these orphaned packages?" y; then
            # shellcheck disable=SC2086
            run_guarded remove sudo pacman -Rns --noconfirm $orphans 2>&1 | tail -3
        fi
    else log_success "No orphaned packages"; fi
    prune_stale_parts
    if have paccache; then
        sudo paccache -rk"$PACCACHE_KEEP" 2>&1 | tail -1
        sudo paccache -ruk0 2>&1 | tail -1
    fi
    local js; js=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -1)
    if [[ $js == *G ]]; then sudo journalctl --vacuum-time="$JOURNAL_KEEP" 2>&1 | tail -1; fi
    after=$(df -P / | awk 'NR==2{print $4}')
    (( after > before )) && log_success "Freed $(human $(( (after - before) * 1024 )))"
}

health_report() {
    log_step "System health"
    df -h / /home /boot 2>/dev/null | awk 'NR==1 || /^\//' | while read -r line; do
        local u; u=$(awk '{print $5}' <<<"$line" | tr -d '%')
        if [[ $u =~ ^[0-9]+$ ]] && (( u > 90 )); then echo "     ${RED}$line${NC}"; else echo "     $line"; fi
    done
    free -h | sed 's/^/     /'
    local load cpus; load=$(cut -d' ' -f1 /proc/loadavg); cpus=$(nproc)
    awk -v l="$load" -v c="$cpus" 'BEGIN{exit !(l > c)}' && log_warning "High load: $load on $cpus CPUs"
    have sensors && sensors 2>/dev/null | grep -E '^(Package|Tctl|Core 0)' | head -3 | sed 's/^/     /'
    return 0
}

reboot_check() {
    log_step "Reboot check"
    local need_reboot=false crit=""
    if [[ ! -d /usr/lib/modules/$(uname -r) ]]; then
        log_warning "The running kernel $(uname -r) was replaced — REBOOT REQUIRED (new modules can't load until you do)"
        need_reboot=true
    fi
    if (( PLOG_START > 0 )); then
        crit=$(tail -n +"$(( PLOG_START + 1 ))" /var/log/pacman.log 2>/dev/null | grep -oE 'upgraded (linux[a-z-]*|systemd|glibc|nvidia[a-z-]*|mesa|dbus[a-z-]*|amd-ucode|intel-ucode) ' | awk '{print $2}' | sort -u | tr '\n' ' ')
    fi
    [[ -n $crit ]] && log_warning "Core packages upgraded this run: $crit— reboot recommended"
    if (( ${#REBOOT_SERVICES[@]} )); then
        log_warning "Waiting for the reboot: ${REBOOT_SERVICES[*]} (they need the new kernel)"
        need_reboot=true
    fi
    [[ $need_reboot == false && -z $crit ]] && log_success "No reboot needed"
    if [[ $need_reboot == true && $DRY_RUN == false ]]; then
        notify "Reboot required" "A new kernel was installed${REBOOT_SERVICES[*]:+ — waiting: ${REBOOT_SERVICES[*]}}" critical
        if ui_ask "Reboot now?" n; then sudo systemctl reboot; fi
    fi
}

summary() {
    local dur=$(( $(date +%s) - RUN_START )) upg=0 txt
    (( PLOG_START > 0 )) && upg=$(tail -n +"$(( PLOG_START + 1 ))" /var/log/pacman.log 2>/dev/null | grep -cE '\[ALPM\] (upgraded|installed)')
    txt="Duration:            $(fmt_secs "$dur")
Packages changed:    $upg
Packages downloaded: $(human "$PKG_DOWNLOADED_BYTES")
Network used (run):  $(human "$(net_used)")
Problems detected:   $(printf '%s\n' "${ISSUES_SEEN[@]}" | sed '/^$/d' | sort -u | wc -l)
Fixes applied:       ${#FIXES_APPLIED[@]}
Unresolved:          ${#UNRESOLVED[@]}"
    printf '\n%s══════════════════ SUMMARY ══════════════════%s\n' "$GREEN" "$NC"
    printf '%s\n' "$txt"
    local f; for f in "${FIXES_APPLIED[@]}"; do echo "   🔧 fixed: $f"; done
    for f in "${UNRESOLVED[@]}"; do echo "   ❌ unresolved: $f"; done
    (( ${#HOLD_PKGS[@]} )) && echo "   ⏸  held back this run (blocked download, safe): ${HOLD_PKGS[*]}"
    (( ${#BLOCKED_FINAL[@]} )) && echo "   🚫 could not be downloaded: ${BLOCKED_FINAL[*]}"
    [[ -n $PAC_DOH ]] && echo "   🌐 system DNS was down — pacman used DNS-over-HTTPS ($PAC_DOH)"
    (( ${#SKIPPED_DNS[@]} )) && echo "   ⏭  skipped (DNS down): ${SKIPPED_DNS[*]}"
    echo "Log: $LOG_FILE"
    [[ -n $REPORT_FILE ]] && echo "Detailed report: $REPORT_FILE"
    [[ $DRY_RUN == true ]] && echo "${YELLOW}Dry-run: nothing was changed.${NC}"
    printf '%s═════════════════════════════════════════════%s\n' "$GREEN" "$NC"
    _log "$txt"
    if (( ${#UNRESOLVED[@]} )); then
        notify "Finished with problems" "${#UNRESOLVED[@]} step(s) need attention — see the log" normal
        ui_message "$APP_TITLE — needs attention" "$txt

Unresolved:
$(printf '%s\n' "${UNRESOLVED[@]}")

Log: $LOG_FILE"
    else
        notify "Update complete" "Downloaded $(human "$(net_used)") — all good" normal
        ui_message "$APP_TITLE — done" "$txt

Log: $LOG_FILE"
    fi
}

# ======================================================================
# SUDO, QUESTIONS AND CHOICES
# ======================================================================
ensure_sudo() {
    [[ $DRY_RUN == true ]] && return 0
    if ! sudo -v; then log_error "sudo access is required"; return 1; fi
    if [[ ! -e $TMP/sudo_keepalive ]]; then
        : >"$TMP/sudo_keepalive"
        ( trap '' INT QUIT HUP; while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null; sleep 50; done ) &
        SUDO_PID=$!
    fi
}

ask_fix() {  # uses ITITLE/IWHY/IHINT/IRISK + $c (issue code). 0 = apply, 1 = skip, 2 = stop fixing this step
    local code=${1:-$c}
    (( FIX_YES_ALL )) && return 0
    if [[ $GUI == true ]]; then gui_ask_fix "$code"; return; fi
    [[ -t 0 ]] || { ui_ask "Apply fix for: $ITITLE?" y; return; }
    if tui_ok; then
        local show=0 body dl
        while :; do
            body="$ITITLE"$'\n\n'"Why it failed: $IWHY"
            [[ $IRISK == risky ]] && body+=$'\n\n'"⚠  This fix changes packages or files."
            if (( show )); then
                body+=$'\n\n'"What it will do:"$'\n'"$(fix_plan "$code" | strip_ansi)"$'\n\n'"To do it by hand instead: $IHINT"
                dl="Hide details"
            else dl="Details"; fi
            tui_dialog "🔧 Fix available" "$body" 0 1 Apply Skip "Yes to all" "$dl" "Quit fixing"
            case $TUI_CHOICE in
                0) return 0 ;; 1) return 1 ;; 2) FIX_YES_ALL=1; return 0 ;;
                3) show=$(( !show )) ;; 4) return 2 ;;
            esac
        done
    fi
    local ans risk=""
    [[ $IRISK == risky ]] && risk=" ${RED}(changes packages/files)${NC}"
    while :; do
        read -r -p "${YELLOW}?${NC} Apply fix for ${BOLD}${ITITLE}${NC}${risk}
  [Y]es  [n]o  [a]ll fixes this run  [d]etails (what it changes + exact commands)  [q]uit fixing: " ans
        case ${ans,,} in
            ''|y|yes) return 0 ;;
            n|no)     return 1 ;;
            a|all)    FIX_YES_ALL=1; return 0 ;;
            d|details)
                printf '   %sWhy it failed:%s %s\n' "$BOLD" "$NC" "$IWHY"
                fix_plan "$code"
                printf '   %sTo do it by hand instead:%s %s\n' "$BOLD" "$NC" "$IHINT" ;;
            q|quit)   return 2 ;;
            *)        echo "   Please answer y, n, a, d or q" ;;
        esac
    done
}

gui_ask_fix() {  # dialog with Apply / Skip / Details
    local code=$1 q rc f="$TMP/fix-details.txt"
    q="Apply fix for: $ITITLE?"; [[ $IRISK == risky ]] && q+=$'\n(changes packages or files)'
    { printf 'Why it failed: %s\n\n' "$IWHY"; fix_plan "$code" | strip_ansi | sed 's/^   //'; printf '\nTo do it by hand instead: %s\n' "$IHINT"; } >"$f"
    while :; do
        case $GUI_TOOL in
            zenity)  local out; out=$(zenity --question --title="$APP_TITLE" --width=520 --no-markup --text="$q" \
                         --ok-label=Apply --cancel-label=Skip --extra-button=Details 2>/dev/null); rc=$?
                     [[ $out == Details ]] && rc=2 ;;
            yad)     yad --title="$APP_TITLE" --width=520 --image=dialog-question --text="$(gui_escape "$q")" \
                         --button=Details:2 --button=Skip:1 --button=Apply:0 2>/dev/null; rc=$? ;;
            kdialog) kdialog --title "$APP_TITLE" --yes-label Apply --no-label Skip --cancel-label Details --yesnocancel "$q" 2>/dev/null; rc=$? ;;
            *)       ui_ask "$q" y; return ;;
        esac
        case $rc in
            0) return 0 ;;
            2) case $GUI_TOOL in
                   zenity)  zenity --text-info --title="Fix details: $ITITLE" --width=760 --height=520 --filename="$f" 2>/dev/null ;;
                   yad)     yad --text-info --title="Fix details: $ITITLE" --width=760 --height=520 --filename="$f" --button=OK:0 2>/dev/null ;;
                   kdialog) kdialog --title "Fix details: $ITITLE" --textbox "$f" 760 520 2>/dev/null ;;
               esac ;;
            *) return 1 ;;
        esac
    done
}

tui_text() {  # whiptail/dialog (newt) cannot draw emoji: drop them and map typographic symbols to ASCII
    printf '%s' "$1" | LC_ALL=C sed -E \
        -e 's/\xF0[\x80-\xBF]{3}//g' \
        -e 's/\xEF\xB8\x8F//g; s/\xE2\x80\x8D//g' \
        -e 's/\xE2[\x98-\x9E][\x80-\xBF]//g; s/\xE2[\xAC\xAD][\x80-\xBF]//g; s/\xE2\x8F[\x80-\xBF]//g' \
        -e 's/\xE2\x80[\x93\x94]/-/g; s/\xE2\x80\xA6/.../g; s/\xE2\x80\xA2/*/g' \
        -e 's/\xE2\x86\x90/<-/g; s/\xE2\x86\x92/->/g; s/\xE2\x9C[\x93\x94]/OK/g' \
        -e 's/^ +//; s/  +/  /g'
}

ui_choose() {  # ui_choose "title" "prompt" key label [key label]...  -> prints chosen key; 1 = cancelled
    local title=$1 prompt=$2 i ans tool=""
    shift 2
    local keys=() labels=() rows=() modern=false
    tui_ok && modern=true
    while (( $# >= 2 )); do
        if [[ $1 == @* && $modern != true ]]; then shift 2; continue; fi   # section headings: modern UI only
        keys+=("$1"); labels+=("$2"); rows+=("$1" "$2"); shift 2
    done
    if [[ $GUI == true && $GUI_TOOL == zenity ]]; then
        zenity --list --title="$title" --text="$prompt" --column=Key --column=Option --hide-column=1 \
            --print-column=1 --width=600 --height=520 "${rows[@]}" 2>/dev/null
        return
    fi
    [[ -t 0 ]] || return 1
    if [[ $modern == true ]]; then tui_menu "$title" "$prompt"; return; fi
    if [[ $MENU_STYLE != plain ]]; then
        if have dialog; then tool=dialog; elif have whiptail; then tool=whiptail; fi   # dialog keeps Ctrl+\ working
    fi
    if [[ -n $tool ]]; then
        local notags=--notags tui_rows=() h w
        [[ $tool == dialog ]] && notags=--no-tags
        for i in "${!keys[@]}"; do tui_rows+=("${keys[$i]}" "$(tui_text "${labels[$i]}")"); done
        local txt list maxh
        txt=$(tui_text "$prompt")
        list=${#keys[@]}; maxh=$(( $(tput lines 2>/dev/null || echo 24) - 2 )); (( maxh < 16 )) && maxh=16
        h=$(( list + $(printf '%s\n' "$txt" | wc -l) + 6 ))
        (( h > maxh )) && { list=$(( list - (h - maxh) )); h=$maxh; }
        (( list < 4 )) && list=4
        w=$(( $(tput cols 2>/dev/null || echo 80) - 4 )); (( w > 96 )) && w=96; (( w < 60 )) && w=60
        "$tool" --title "$(tui_text "$title")" $notags --menu "$txt" "$h" "$w" "$list" \
            "${tui_rows[@]}" 3>&1 1>&2 2>&3
        return
    fi
    {
        printf '\n%s━━ %s ━━%s\n' "$BOLD$PURPLE" "$title" "$NC"
        printf '%s\n\n' "$prompt"
        for i in "${!keys[@]}"; do printf '  %s%2d)%s %s\n' "$CYAN" $(( i + 1 )) "$NC" "${labels[$i]}"; done
        echo
    } >&2
    while :; do
        read -r -p "Choose 1-${#keys[@]} (q = back): " ans
        [[ ${ans,,} == q ]] && return 1
        if [[ $ans =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#keys[@]} )); then echo "${keys[$(( ans - 1 ))]}"; return 0; fi
        echo "  Not a valid choice" >&2
    done
}

# ======================================================================
# MODERN TERMINAL UI — mouse + keyboard, pure bash (no extra packages)
#   MENU_STYLE: auto | modern = this UI · classic = whiptail/dialog · plain = numbered list
#   Mouse: hover highlights, click opens, wheel scrolls. Keys: arrows/j/k, Enter,
#   Esc/q back, 1-9 quick pick, Tab/←→ between buttons, underlined letter = button.
# ======================================================================
TUI_ACTIVE=0
TUI_STTY=""
TUI_ROWS=24
TUI_COLS=80
TUI_RESIZED=1
TUI_CHOICE=0
TUI_HIT=-1
TUI_BY=0
TUI_BUF=""
TUI_S=""
TUI_INPUT=""
K="" MX=0 MY=0
declare -a TUI_LINES=() TUI_BX0=() TUI_BX1=()
declare -A TUI_DESC=(
    [main:full]="Runs everything in the right order: official packages, AUR, Flatpak/Snap, firmware check, cleanup and a health report. Errors are diagnosed and repaired on the way — the fix mode decides whether you are asked first."
    [main:official]="Only pacman packages from the official repositories. Locks, keyring, mirrors and free disk space are checked first."
    [main:aur]="Rebuilds outdated AUR packages with your AUR helper. If official updates are pending you are offered to install those first, so the system is never half-upgraded."
    [main:apps]="Updates Flatpak and Snap applications. System packages are not touched."
    [main:preview]="Dry run: shows what would be updated and what would be repaired. Nothing on the system changes."
    [main:download]="Downloads official updates into the pacman cache now; install later, even offline. Resumes where it stopped — made for slow, unstable or filtered connections."
    [main:news]="Arch news items that need manual action, plus pre-flight checks: locks, disk space, keyring, clock, network and mirrors."
    [main:diagnose]="Paste an error or pick a log file and get the most likely cause in plain language, then apply the fixes it knows."
    [main:tools]="Run a single repair: mirrors, keyring, stale lock, disk space, AUR build files, initramfs, clock, .pacnew merge or orphans. Each shows its exact commands before it runs."
    [main:helper]="Installs paru or yay (prebuilt) so AUR packages can be updated and repaired as well."
    [main:health]="Failed services, .pacnew files, disk usage, and whether a reboot is needed after a kernel or core-library update."
    [main:settings]="Fix mode, what a full update includes, mirror refresh, notifications and the menu style. Changes apply at once; Save keeps them."
    [main:logs]="Open the log of a recent run. Runs that had errors are marked."
    [main:report]="Everything that can interfere with updates — locks, timers, hooks, services, running programs, network path and mirrors — with plain-language conclusions."
    [main:install]="Search the official repositories and the AUR at once. Pick pacman or any installed AUR helper, and see before anything happens: what will be installed, what is only needed to build it, what is already on your system (keep it), and which optional extras exist."
    [main:uninstall]="Search what is installed and see where each package came from and how it was installed. Then remove only the package, remove it with the dependencies nothing else needs, or clean it fully — its enabled services and the data it created in your home folder go too (moved to the Trash). You see the exact list first."
    [main:quit]="Leave Smart Update."
)

tui_ok() {  # use the modern UI here?
    [[ $GUI != true && ( $MENU_STYLE == auto || $MENU_STYLE == modern ) ]] || return 1
    [[ -t 0 && -n ${TERM:-} && $TERM != dumb && $TERM != linux ]] || return 1
    { : >/dev/tty; } 2>/dev/null
}

tui_theme() {
    local e=$'\033['
    T_R="${e}0m" T_B="${e}1m" T_U="${e}4m" T_NU="${e}24m"
    T_DIM="${e}38;5;245m" T_FG="${e}38;5;252m" T_ACC="${e}38;5;141m" T_OK="${e}38;5;114m" T_WARN="${e}38;5;221m"
    T_HDR="${e}48;5;55m${e}38;5;231m" T_SEL="${e}48;5;60m${e}38;5;231m" T_LINE="${e}38;5;240m"
    T_BTN="${e}48;5;238m${e}38;5;252m" T_BTNF="${e}48;5;141m${e}38;5;232m${e}1m" T_FIELD="${e}48;5;236m${e}38;5;231m"
}

tui_enter() {  # alternate screen, hidden cursor, raw keys, mouse reporting (SGR, with hover)
    (( TUI_ACTIVE++ )) && return 0
    TUI_STTY=$(stty -g </dev/tty 2>/dev/null)
    stty -echo -icanon -isig min 1 time 0 </dev/tty 2>/dev/null
    trap 'TUI_RESIZED=1' WINCH
    TUI_RESIZED=1
    [[ -n $TMP && -d $TMP ]] && : >"$TMP/tui_on"      # the live panel pauses while a dialog is open
    # resetting the scroll region also moves the cursor to row 1; keep it where the output is,
    # or everything printed after the dialog closes overwrites the screen from the top
    printf '\0337\033[r\0338' >/dev/tty
    printf '\033[?1049h\033[?25l\033[?7l\033[?1000h\033[?1002h\033[?1003h\033[?1006h' >/dev/tty
}

tui_leave() {
    (( TUI_ACTIVE > 0 )) || return 0
    (( --TUI_ACTIVE > 0 )) && return 0
    printf '\033[?1003l\033[?1002l\033[?1000l\033[?1006l\033[0m\033[?7h\033[?25h\033[?1049l' >/dev/tty
    [[ -n $TUI_STTY ]] && stty "$TUI_STTY" </dev/tty 2>/dev/null
    trap - WINCH
    if [[ -n $TMP ]]; then
        rm -f "$TMP/tui_on" "$TMP/panel_rows"
        [[ -e $TMP/panel_on ]] && { panel_region; panel_draw; }
    fi
    return 0
}

tui_size() {  # -> TUI_ROWS TUI_COLS; 0 if the size changed
    local s r c
    s=$(stty size </dev/tty 2>/dev/null) || s="24 80"
    r=${s% *} c=${s#* }
    (( r < 12 )) && r=12; (( c < 44 )) && c=44
    TUI_RESIZED=0
    [[ $r == "$TUI_ROWS" && $c == "$TUI_COLS" ]] && return 1
    TUI_ROWS=$r TUI_COLS=$c
}

tui_key() {  # tui_key TIMEOUT -> K (up down left right home end pgup pgdn tab btab enter space esc bksp cancel
             #   click move release wheelup wheeldown tick ch:<char>), MX/MY = mouse cell
    local c s=""
    K="" MX=0 MY=0
    IFS= read -rsn1 -t "$1" c </dev/tty || { K=tick; return; }
    case $c in
        $'\033')
            if ! IFS= read -rsn1 -t 0.05 c </dev/tty; then K=esc; return; fi
            if [[ $c != '[' && $c != O ]]; then K=esc; return; fi
            while IFS= read -rsn1 -t 0.05 c </dev/tty; do s+=$c; [[ $c == [@-~] ]] && break; done
            case $s in
                A) K=up ;; B) K=down ;; C) K=right ;; D) K=left ;;
                H|1~|7~) K=home ;; F|4~|8~) K=end ;; 5~) K=pgup ;; 6~) K=pgdn ;; Z) K=btab ;; 3~) K=del ;;
                '<'*[Mm])
                    local b x y t=${s: -1}
                    IFS=';' read -r b x y <<<"${s:1:${#s}-2}"
                    MX=${x:-0} MY=${y:-0}
                    if (( b & 64 )); then (( b & 1 )) && K=wheeldown || K=wheelup
                    elif (( b & 32 )); then K=move
                    elif [[ $t == M ]] && (( (b & 3) == 0 )); then K=click
                    elif [[ $t == m ]]; then K=release
                    else K=other; fi ;;
                *) K=other ;;
            esac ;;
        ''|$'\n'|$'\r') K=enter ;;
        ' ')            K=space ;;
        $'\t')          K=tab ;;
        $'\x7f'|$'\b')  K=bksp ;;
        $'\x03'|$'\x1c'|$'\x04') K=cancel ;;
        $'\x15')        K=kill ;;
        *)              K="ch:$c" ;;
    esac
}

tui_wrap() {  # tui_wrap WIDTH TEXT -> TUI_LINES (keeps paragraphs and leading indentation)
    local w=$1 para ind line word cut
    local -a words
    TUI_LINES=()
    (( w < 10 )) && w=10
    while IFS= read -r para || [[ -n $para ]]; do
        para=${para//$'\t'/    }
        ind=${para%%[! ]*}; (( ${#ind} > w / 2 )) && ind=${ind:0:w/2}
        read -ra words <<<"$para"
        (( ${#words[@]} )) || { TUI_LINES+=(""); continue; }
        line=$ind; cut=$(( w - ${#ind} ))
        for word in "${words[@]}"; do
            while (( ${#word} > cut )); do
                [[ $line != "$ind" ]] && { TUI_LINES+=("$line"); line=$ind; }
                TUI_LINES+=("$ind${word:0:cut}"); word=${word:cut}
            done
            [[ -z $word ]] && continue
            if [[ $line == "$ind" ]]; then line+=$word
            elif (( ${#line} + 1 + ${#word} <= w )); then line+=" $word"
            else TUI_LINES+=("$line"); line=$ind$word; fi
        done
        [[ $line != "$ind" ]] && TUI_LINES+=("$line")
    done <<<"$2"
}

tui_fit() { local s=$1 w=$2; (( w < 1 )) && { TUI_S=""; return; }; (( ${#s} > w )) && s="${s:0:w-1}…"; TUI_S=$s; }
tui_at() { TUI_BUF+=$'\033['"$1;$2H"; }
tui_spaces() { printf -v TUI_S '%*s' "$1" ''; }

tui_header() {  # tui_header CRUMB — app bar on row 1 with the live data counter
    local left=" ◆ $APP_TITLE" right
    [[ -n $1 ]] && left+="  ›  $1"
    right="↓ $(human "$(net_used)") this session "
    tui_spaces "$TUI_COLS"
    tui_at 1 1; TUI_BUF+="$T_HDR$TUI_S"
    tui_fit "$left" $(( TUI_COLS - 2 )); tui_at 1 1; TUI_BUF+="$T_HDR$T_B$TUI_S$T_R"
    (( ${#left} + ${#right} + 2 < TUI_COLS )) && { tui_at 1 $(( TUI_COLS - ${#right} + 1 )); TUI_BUF+="$T_HDR$right$T_R"; }
}

tui_box() {  # tui_box ROW COL HEIGHT WIDTH COLOR [TITLE]
    local y=$1 x=$2 h=$3 w=$4 col=$5 title=${6:-} line r
    printf -v line '%*s' $(( w - 2 )) ''; line=${line// /─}
    tui_spaces $(( w - 2 ))
    tui_at "$y" "$x"; TUI_BUF+="$col╭$line╮$T_R"
    for (( r = 1; r < h - 1; r++ )); do tui_at $(( y + r )) "$x"; TUI_BUF+="$col│$T_R$TUI_S$col│$T_R"; done
    tui_at $(( y + h - 1 )) "$x"; TUI_BUF+="$col╰$line╯$T_R"
    if [[ -n $title ]]; then tui_fit "$title" $(( w - 8 )); tui_at "$y" $(( x + 2 )); TUI_BUF+="$T_B$T_ACC $TUI_S $T_R"; fi
}

tui_buttons() {  # tui_buttons ROW RIGHT_EDGE FOCUS LABEL... — right-aligned, sets TUI_BX0/TUI_BX1/TUI_BY for clicks
    local row=$1 right=$2 focus=$3 i=0 x total=0 l style
    shift 3
    TUI_BX0=() TUI_BX1=() TUI_BY=$row
    for l in "$@"; do (( total += ${#l} + 5 )); done
    x=$(( right - total + 2 ))
    for l in "$@"; do
        style=$T_BTN; (( i == focus )) && style=$T_BTNF
        TUI_BX0+=("$x"); TUI_BX1+=($(( x + ${#l} + 3 )))
        tui_at "$row" "$x"; TUI_BUF+="$style  $T_U${l:0:1}$T_NU${l:1}  $T_R"
        (( x += ${#l} + 5, i++ ))
    done
}

tui_hit() {  # was the mouse event on a button? -> TUI_HIT
    local i; TUI_HIT=-1
    (( MY == TUI_BY )) || return 1
    for i in "${!TUI_BX0[@]}"; do (( MX >= TUI_BX0[i] && MX <= TUI_BX1[i] )) && { TUI_HIT=$i; return 0; }; done
    return 1
}

tui_flush() { printf '%s' "$TUI_BUF" >/dev/tty; TUI_BUF=""; }

# hotkeys for menu items: 1-9, 0, then letters; h j k l q stay navigation keys
TUI_HOTKEYS=(1 2 3 4 5 6 7 8 9 0 a b c d e f g i m n o p r s t u v w x y z)
declare -A TUI_HOTKEY_POS=(); for _i in "${!TUI_HOTKEYS[@]}"; do TUI_HOTKEY_POS[${TUI_HOTKEYS[_i]}]=$_i; done; unset _i

tui_menu() {  # tui_menu TITLE PROMPT — uses keys[]/labels[] of ui_choose; prints the chosen key, 1 = back
    local title=$1 prompt=$2 crumb=$1 ctx
    [[ $title == "$APP_TITLE"* ]] && crumb=""
    ctx=${crumb:-main}
    local n=${#keys[@]} i r y sel top=0 dirty=1 ticks=0 l tok hasicon=0
    local -a pick=() icon=() name=() sub=()
    local -A rowat=() posof=()
    for i in "${!keys[@]}"; do
        l=${labels[i]} tok=${labels[i]%% *} icon[i]=""
        if [[ ${keys[i]} != @* && $tok != "$l" && -n $tok && $tok != *[[:alnum:]]* && ${#tok} -le 3 ]]; then
            icon[i]=$tok; hasicon=1; l=${l#"$tok"}; l=${l#"${l%%[! ]*}"}
        fi
        if [[ $l == *" ("*")" ]]; then   # split at the FIRST " (": descriptions may contain parentheses themselves
            name[i]=${l%% (*}; name[i]=${name[i]%"${name[i]##*[! ]}"}; sub[i]=${l#* (}; sub[i]=${sub[i]%)}
        else name[i]=$l sub[i]=""; fi
        [[ ${keys[i]} == @* ]] || { posof[$i]=${#pick[@]}; pick+=("$i"); }
    done
    (( ${#pick[@]} )) || return 1
    sel=${pick[0]}
    (( BASH_SUBSHELL > 0 )) && trap 'tui_leave' EXIT
    tui_theme; tui_enter

    local listx=3 listw ly0 ly1 vis wide px pw ph tx bg dim nm desc p
    while :; do
        if (( dirty )); then
            (( TUI_RESIZED )) && tui_size
            TUI_BUF=$'\033[0m\033[2J'; rowat=()
            tui_header "$crumb"
            y=3
            if [[ -n $prompt ]]; then
                tui_wrap $(( TUI_COLS - 6 )) "$prompt"
                for (( r = 0; r < ${#TUI_LINES[@]} && r < 5; r++ )); do
                    tui_fit "${TUI_LINES[r]}" $(( TUI_COLS - 6 )); tui_at "$y" 4; TUI_BUF+="$T_DIM$TUI_S$T_R"; (( y++ ))
                done
                (( y++ ))
            fi
            ly0=$y ly1=$(( TUI_ROWS - 3 )); (( ly1 < ly0 )) && ly1=$ly0
            vis=$(( ly1 - ly0 + 1 ))
            wide=0; (( TUI_COLS >= 100 )) && wide=1
            if (( wide )); then listw=$(( TUI_COLS * 55 / 100 )); (( listw > 70 )) && listw=70; else listw=$(( TUI_COLS - 5 )); fi
            # keep the selection (and its section heading) in view
            (( sel < top )) && top=$sel
            (( sel > 0 )) && [[ ${keys[sel-1]} == @* ]] && (( top == sel )) && top=$(( sel - 1 ))
            (( sel >= top + vis )) && top=$(( sel - vis + 1 ))
            (( top > n - vis )) && top=$(( n - vis )); (( top < 0 )) && top=0
            tx=$(( listx + 5 )); (( hasicon )) && tx=$(( listx + 8 ))
            for (( r = 0; r < vis && top + r < n; r++ )); do
                i=$(( top + r )) y=$(( ly0 + r ))
                if [[ ${keys[i]} == @* ]]; then
                    nm=${labels[i]^^}; tui_spaces $(( listw - ${#nm} - 3 )); p=${TUI_S// /─}
                    tui_at "$y" $(( listx + 2 )); TUI_BUF+="$T_ACC$T_B$nm$T_R $T_LINE$p$T_R"
                    continue
                fi
                rowat[$y]=$i
                bg=""; dim=$T_DIM; (( i == sel )) && { bg=$T_SEL; dim=$'\033[38;5;250m'; }
                tui_spaces "$listw"; tui_at "$y" "$listx"; TUI_BUF+="$bg$TUI_S"
                (( i == sel )) && { tui_at "$y" "$listx"; TUI_BUF+="$bg"$'\033[38;5;141m▌'; }
                p=${posof[$i]}
                (( p < ${#TUI_HOTKEYS[@]} )) && { tui_at "$y" $(( listx + 2 )); TUI_BUF+="$bg$dim${TUI_HOTKEYS[p]}"; }
                [[ -n ${icon[i]} ]] && { tui_at "$y" $(( listx + 5 )); TUI_BUF+="$bg${icon[i]}"; }
                nm=${name[i]}
                local avail=$(( listx + listw - tx - 1 )) sw=""
                if [[ $nm =~ ^(.+):\ (on|off)$ ]]; then
                    nm=${BASH_REMATCH[1]}
                    if [[ ${BASH_REMATCH[2]} == on ]]; then sw=$'\033[38;5;114m'"● ON "; else sw="$dim○ OFF"; fi
                    (( avail -= 7 ))
                fi
                tui_fit "$nm" "$avail"; nm=$TUI_S
                tui_at "$y" "$tx"
                if (( i == sel )); then TUI_BUF+="$bg$T_B$nm$T_R$bg"; else TUI_BUF+="$T_FG$nm$T_R"; fi
                if [[ -n ${sub[i]} && -z $sw ]] && (( avail - ${#nm} > 8 )); then
                    tui_fit "${sub[i]}" $(( avail - ${#nm} - 3 )); TUI_BUF+="$bg$dim   $TUI_S"
                fi
                [[ -n $sw ]] && { tui_at "$y" $(( listx + listw - 7 )); TUI_BUF+="$bg$sw"; }
                TUI_BUF+=$T_R
            done
            if (( n > vis )); then  # scrollbar
                local th=$(( vis * vis / n )) ty; (( th < 1 )) && th=1
                ty=$(( ly0 + (vis - th) * top / (n - vis) ))
                for (( r = ly0; r <= ly1; r++ )); do
                    tui_at "$r" $(( listx + listw + 1 ))
                    if (( r >= ty && r < ty + th )); then TUI_BUF+="$T_ACC┃$T_R"; else TUI_BUF+="$T_LINE│$T_R"; fi
                done
            fi
            desc=${TUI_DESC[$ctx:${keys[sel]}]:-${sub[sel]}}
            if (( wide )); then  # details panel
                px=$(( listx + listw + 4 )) pw=$(( TUI_COLS - listx - listw - 5 )) ph=$vis
                (( ph > 16 )) && ph=16
                tui_box "$ly0" "$px" "$ph" "$pw" "$T_LINE"
                tui_at $(( ly0 + 1 )) $(( px + 3 ))
                [[ -n ${icon[sel]} ]] && TUI_BUF+="${icon[sel]}  "
                tui_fit "${name[sel]}" $(( pw - 10 )); TUI_BUF+="$T_B$TUI_S$T_R"
                tui_wrap $(( pw - 6 )) "$desc"
                for (( r = 0; r < ${#TUI_LINES[@]} && r < ph - 6; r++ )); do
                    tui_at $(( ly0 + 3 + r )) $(( px + 3 )); TUI_BUF+="$T_FG${TUI_LINES[r]}$T_R"
                done
                tui_at $(( ly0 + ph - 2 )) $(( px + 3 )); TUI_BUF+="${T_DIM}Enter or click to open$T_R"
            elif [[ -n $desc ]]; then
                tui_fit "$desc" $(( TUI_COLS - 6 )); tui_at $(( TUI_ROWS - 1 )) 4; TUI_BUF+="$T_DIM$TUI_S$T_R"
            fi
            local back=Back; [[ -z $crumb ]] && back=Quit
            local hk="1-${#pick[@]}"; (( ${#pick[@]} > 9 )) && hk="1-9 0 a-z"
            tui_fit "↑↓ move · Enter open · $hk pick · Esc ${back,,}" $(( TUI_COLS - 24 ))
            tui_at "$TUI_ROWS" 3; TUI_BUF+="$T_DIM$TUI_S$T_R"
            tui_buttons "$TUI_ROWS" $(( TUI_COLS - 1 )) -1 Open "$back"
            tui_flush; dirty=0
        fi
        tui_key 1
        local step=0
        case $K in
            tick)    tui_size && dirty=1; (( ++ticks % 3 == 0 )) && dirty=1 ;;
            up|ch:k|btab|wheelup)     step=-1 ;;
            down|ch:j|tab|wheeldown)  step=1 ;;
            pgup)    step=-5 ;;
            pgdn)    step=5 ;;
            home)    sel=${pick[0]}; dirty=1 ;;
            end)     sel=${pick[-1]}; dirty=1 ;;
            enter|space|right|ch:l) break ;;
            esc|left|cancel|bksp|ch:q|ch:Q|ch:h) tui_leave; return 1 ;;
            move)    [[ -n ${rowat[$MY]:-} && ${rowat[$MY]} != "$sel" ]] && { sel=${rowat[$MY]}; dirty=1; } ;;
            click)   if [[ -n ${rowat[$MY]:-} ]]; then sel=${rowat[$MY]}; break
                     elif tui_hit; then (( TUI_HIT == 0 )) && break; tui_leave; return 1
                     elif (( wide && MX >= px && MY >= ly0 && MY < ly0 + ph )); then break; fi ;;
            ch:?)    p=${K#ch:}; p=${p,,}; p=${TUI_HOTKEY_POS[$p]:-}   # letters work in either case
                     [[ -n $p ]] && (( p < ${#pick[@]} )) && { sel=${pick[p]}; break; } ;;
        esac
        if (( step )); then
            p=$(( ${posof[$sel]} + step )); (( p < 0 )) && p=0; (( p >= ${#pick[@]} )) && p=$(( ${#pick[@]} - 1 ))
            sel=${pick[p]}; dirty=1
        fi
    done
    tui_leave
    printf '%s\n' "${keys[sel]}"
}

tui_dialog() {  # tui_dialog TITLE BODY FOCUS CANCEL_INDEX BUTTON... -> TUI_CHOICE = index of the chosen button
    local title=$1 body=$2 focus=$3 cancel=$4 top=0 dirty=1 bw bh bx by bodyh nl max r nb
    shift 4
    local -a btn=("$@")
    nb=${#btn[@]}
    tui_theme; tui_enter
    while :; do
        if (( dirty )); then
            (( TUI_RESIZED )) && tui_size
            bw=$(( TUI_COLS - 4 )); (( bw > 86 )) && bw=86
            tui_wrap $(( bw - 6 )) "$body"; nl=${#TUI_LINES[@]}
            max=$(( TUI_ROWS - 10 )); (( max < 3 )) && max=3
            bodyh=$nl; (( bodyh > max )) && bodyh=$max; (( bodyh < 1 )) && bodyh=1
            (( top > nl - bodyh )) && top=$(( nl - bodyh )); (( top < 0 )) && top=0
            bh=$(( bodyh + 6 ))
            bx=$(( (TUI_COLS - bw) / 2 + 1 )) by=$(( (TUI_ROWS - bh) / 2 + 1 )); (( by < 3 )) && by=3
            TUI_BUF=$'\033[0m\033[2J'
            tui_header ""
            tui_box "$by" "$bx" "$bh" "$bw" "$T_ACC" "$title"
            for (( r = 0; r < bodyh && top + r < nl; r++ )); do
                tui_fit "${TUI_LINES[top+r]}" $(( bw - 6 )); tui_at $(( by + 2 + r )) $(( bx + 3 )); TUI_BUF+="$T_FG$TUI_S$T_R"
            done
            if (( nl > bodyh )); then
                (( top > 0 )) && { tui_at $(( by + 2 )) $(( bx + bw - 2 )); TUI_BUF+="$T_ACC▲$T_R"; }
                (( top + bodyh < nl )) && { tui_at $(( by + 1 + bodyh )) $(( bx + bw - 2 )); TUI_BUF+="$T_ACC▼$T_R"; }
                tui_at $(( by + bh - 2 )) $(( bx + 3 )); TUI_BUF+="$T_DIM$(( top + 1 ))–$(( top + bodyh )) of $nl · scroll$T_R"
            fi
            tui_buttons $(( by + bh - 2 )) $(( bx + bw - 3 )) "$focus" "${btn[@]}"
            tui_fit "←→ choose · Enter confirm · Esc cancel · ↑↓ / wheel scroll · underlined letter = button" $(( TUI_COLS - 4 ))
            tui_at "$TUI_ROWS" 3; TUI_BUF+="$T_DIM$TUI_S$T_R"
            tui_flush; dirty=0
        fi
        tui_key 1
        case $K in
            tick)  tui_size && dirty=1 ;;
            left|btab)  focus=$(( (focus - 1 + nb) % nb )); dirty=1 ;;
            right|tab)  focus=$(( (focus + 1) % nb )); dirty=1 ;;
            up|wheelup)     (( top > 0 )) && { (( top-- )); dirty=1; } ;;
            down|wheeldown) (( top + bodyh < nl )) && { (( top++ )); dirty=1; } ;;
            pgup)  (( top -= bodyh, top < 0 )) && top=0; dirty=1 ;;
            pgdn)  (( top += bodyh )); dirty=1 ;;
            enter|space) TUI_CHOICE=$focus; break ;;
            esc|cancel)  TUI_CHOICE=$cancel; break ;;
            move)  tui_hit && (( TUI_HIT != focus )) && { focus=$TUI_HIT; dirty=1; } ;;
            click) tui_hit && { TUI_CHOICE=$TUI_HIT; break; } ;;
            ch:?)  local c=${K#ch:} i
                   for i in "${!btn[@]}"; do [[ ${btn[i]:0:1} == "${c^^}" || ${btn[i]:0:1} == "${c,,}" ]] && { TUI_CHOICE=$i; break 2; }; done ;;
        esac
    done
    tui_leave
}

tui_input() {  # tui_input TITLE PROMPT DEFAULT -> TUI_INPUT; 1 = cancelled
    local title=$1 prompt=$2 val=$3 dirty=1 bw bh bx by r fy nl
    tui_theme; tui_enter
    while :; do
        if (( dirty )); then
            (( TUI_RESIZED )) && tui_size
            bw=$(( TUI_COLS - 4 )); (( bw > 76 )) && bw=76
            tui_wrap $(( bw - 6 )) "$prompt"; nl=${#TUI_LINES[@]}; (( nl > 6 )) && nl=6
            bh=$(( nl + 8 ))
            bx=$(( (TUI_COLS - bw) / 2 + 1 )) by=$(( (TUI_ROWS - bh) / 2 + 1 )); (( by < 3 )) && by=3
            TUI_BUF=$'\033[0m\033[2J'
            tui_header ""
            tui_box "$by" "$bx" "$bh" "$bw" "$T_ACC" "$title"
            for (( r = 0; r < nl; r++ )); do tui_at $(( by + 2 + r )) $(( bx + 3 )); TUI_BUF+="$T_FG${TUI_LINES[r]}$T_R"; done
            fy=$(( by + 3 + nl ))
            tui_spaces $(( bw - 6 )); tui_at "$fy" $(( bx + 3 )); TUI_BUF+="$T_FIELD$TUI_S"
            local shown=$val; (( ${#shown} > bw - 9 )) && shown="…${shown: -$(( bw - 10 ))}"
            tui_at "$fy" $(( bx + 4 )); TUI_BUF+="$T_FIELD$shown"$'\033[38;5;141m▏'"$T_R"
            tui_buttons $(( by + bh - 2 )) $(( bx + bw - 3 )) 0 OK Cancel
            tui_at "$TUI_ROWS" 3; TUI_BUF+="${T_DIM}Type · Backspace delete · Ctrl+U clear · Enter OK · Esc cancel$T_R"
            tui_flush; dirty=0
        fi
        tui_key 1
        case $K in
            tick)   tui_size && dirty=1 ;;
            enter)  tui_leave; TUI_INPUT=$val; return 0 ;;
            esc|cancel) tui_leave; return 1 ;;
            bksp)   val=${val%?}; dirty=1 ;;
            kill)   val=""; dirty=1 ;;
            space)  val+=" "; dirty=1 ;;
            ch:*)   val+=${K#ch:}; dirty=1 ;;
            click)  if tui_hit; then tui_leave; (( TUI_HIT == 0 )) && { TUI_INPUT=$val; return 0; }; return 1; fi ;;
        esac
    done
}

tui_back_button() {  # after an action: one clickable button below the output, in the normal screen
    local saved
    tui_theme
    saved=$(stty -g </dev/tty 2>/dev/null)
    stty -echo -icanon -isig </dev/tty 2>/dev/null
    printf '\n\n  %s  ↩  Back to menu  %s   %sEnter · Esc · or click anywhere%s' "$T_BTNF" "$T_R" "$T_DIM" "$T_R" >/dev/tty
    printf '\033[?1000h\033[?1006h' >/dev/tty
    while :; do
        tui_key 60
        case $K in enter|esc|space|click|cancel|ch:q|ch:Q) break ;; esac
    done
    printf '\033[?1000l\033[?1006l\n' >/dev/tty
    [[ -n $saved ]] && stty "$saved" </dev/tty 2>/dev/null
}

pause() {
    [[ -t 0 && $GUI != true ]] || return 0
    if tui_ok; then tui_back_button; return 0; fi
    read -r -p "${GRAY}Press Enter to return to the menu…${NC}" _
    return 0
}

set_config_value() {  # persist one setting in the config file
    local key=$1 val=$2
    [[ -f $CONFIG_FILE ]] || create_config >/dev/null
    if grep -q "^$key=" "$CONFIG_FILE"; then sed -i "s|^$key=.*|$key=\"$val\"|" "$CONFIG_FILE"
    else printf '%s="%s"\n' "$key" "$val" >>"$CONFIG_FILE"; fi
}

# ======================================================================
# AUR HELPER BOOTSTRAP
# ======================================================================
runner_bootstrap_deps() { GUARD=install run_logged sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -S --needed --noconfirm base-devel git; }

runner_repo_pkg() { GUARD=install run_logged sudo env LC_ALL=C pacman "${PAC_OPTS[@]}" -S --needed --noconfirm "$BOOT_PKG"; }

runner_makepkg() {
    local dir="$TMP/build-$BOOT_PKG"
    rm -rf -- "$dir"
    local mode=--needed; [[ -n $MAKEPKG_FORCE ]] && mode=-f   # -f: rebuild and reinstall the same version
    run_logged bash -c 'git clone --depth 1 "https://aur.archlinux.org/$1.git" "$2" && cd "$2" && [ -f PKGBUILD ] || { echo "error: target not found: $1"; exit 1; }; LC_ALL=C makepkg -si --noconfirm "$3"' _ "$BOOT_PKG" "$dir" "$mode"
}

install_aur_helper() {  # [paru|yay|both] — asks when no argument
    local choice=${1:-} wanted=() p ok=0
    if [[ -z $choice ]]; then
        choice=$(ui_choose "AUR helper" "No AUR helper (paru or yay) is installed. With one, this script can also update and repair AUR packages. Install one now?" \
            paru  "paru  — fast, shows PKGBUILD diffs (recommended)" \
            yay   "yay   — the most popular helper" \
            both  "Both paru and yay" \
            skip  "Not now" \
            never "No, and don't ask again") || choice=skip
    fi
    case $choice in
        skip|"") log_info "Skipping AUR helper installation"; return 1 ;;
        never)   set_config_value AUR_BOOTSTRAP never; log_info "Won't ask again (set AUR_BOOTSTRAP=ask in $CONFIG_FILE to undo)"; return 1 ;;
        both)    wanted=(paru yay) ;;
        paru|yay) wanted=("$choice") ;;
        *) log_error "Unknown helper '$choice' (use paru, yay or both)"; return 1 ;;
    esac
    ensure_sudo || return 1
    if [[ ! -e $TMP/sys_updated ]] && [[ -n $(pacman -Qu 2>/dev/null | head -1) ]]; then
        if ui_ask "Your official packages are not fully up to date. Update them first so the helper is built against a current system (recommended)?" y; then
            update_official || { log_error "Official update failed — not installing the helper on a half-updated system"; return 1; }
            : >"$TMP/sys_updated"
        fi
    fi
    log_step "Installing build tools (base-devel, git)"
    run_step "Install base-devel and git" pacman runner_bootstrap_deps || return 1
    for p in "${wanted[@]}"; do
        if have "$p"; then log_success "$p is already installed"; ok=1; continue; fi
        if LC_ALL=C pacman -Si "$p" &>/dev/null; then
            log_step "Installing $p from your distribution's repository"
            BOOT_PKG=$p
            run_step "Install $p" pacman runner_repo_pkg && ok=1
            continue
        fi
        BOOT_PKG=$p; [[ $AUR_BOOTSTRAP_BIN == true ]] && BOOT_PKG="$p-bin"
        log_step "Building $BOOT_PKG from the AUR"
        if run_step "Build $BOOT_PKG" aur runner_makepkg; then ok=1
        elif [[ $BOOT_PKG == *-bin ]]; then
            log_warning "Prebuilt $BOOT_PKG failed — trying to compile $p from source"
            BOOT_PKG=$p
            run_step "Build $p" aur runner_makepkg && ok=1
        fi
    done
    if (( ok )); then
        local h; for h in "${wanted[@]}"; do have "$h" && log_success "$h $("$h" --version 2>/dev/null | head -1 | awk '{print $2}') is ready"; done
        [[ $AUR_HELPER != paru && $AUR_HELPER != yay ]] || have "$AUR_HELPER" || AUR_HELPER=${wanted[0]}
        notify "AUR helper installed" "${wanted[*]} ready" low
        return 0
    fi
    log_error "Could not install an AUR helper — see the diagnosis above"
    return 1
}

# ======================================================================
# INTERACTIVE MENU
# ======================================================================
# shellcheck disable=SC2012  # log names are generated by this script
newest_logs() { local l=("$LOG_DIR"/update_*.log); (( ${#l[@]} )) && ls -1t "${l[@]}" 2>/dev/null | head -n "${1:-5}"; }   # nullglob: no match → no ls of the cwd

menu_status() {
    local last h
    last=$(last_full_upgrade_epoch)
    h=$(find_aur_helper)
    printf 'Last full upgrade: %s  ·  AUR helper: %s  ·  Fixes: %s\nDownloaded this session: %s  ·  Emergency stop: Ctrl+\\' \
        "$( (( last > 0 )) && date -d @"$last" '+%a %-d %b, %H:%M' || echo never)" "$h" "$FIX_MODE" "$(human "$(net_used)")"
}

aur_only_guard() {
    have checkupdates || return 0
    local n; n=$(CHECKUPDATES_DB="$TMP/checkup-db" checkupdates 2>/dev/null | wc -l)
    (( n == 0 )) && return 0
    if ui_ask "$n official update(s) are pending. AUR packages built on an outdated system can break. Update official packages first?" y; then
        DO_OFFICIAL=true
    fi
}

run_action() {  # runs in a subshell so an abort returns to the menu
    local mode=$1
    (
        trap - INT
        case $mode in
            full) ;;
            official) DO_AUR=false DO_FLATPAK=false DO_SNAP=false DO_FIRMWARE=false DO_HEALTH=false ;;
            aur)      DO_OFFICIAL=false DO_FLATPAK=false DO_SNAP=false DO_FIRMWARE=false DO_CLEANUP=false DO_HEALTH=false; aur_only_guard ;;
            apps)     DO_OFFICIAL=false DO_AUR=false DO_FIRMWARE=false DO_CLEANUP=false DO_HEALTH=false ;;
            preview)  DRY_RUN=true ;;
            download) DOWNLOAD_ONLY=true DO_AUR=false DO_FLATPAK=false DO_SNAP=false DO_FIRMWARE=false DO_CLEANUP=false DO_HEALTH=false ;;
        esac
        run_update
    )
}

action_diagnose() {
    local src f="$TMP/diag-input.log" path
    src=$(ui_choose "Diagnose an error" "What should I analyse?" \
        paste "Paste error text from the terminal" \
        file  "A log file" \
        last  "The log of a previous run") || return 0
    case $src in
        paste) echo "Paste the error output, then press Ctrl+D on an empty line:"; cat >"$f" ;;
        file)  read -e -r -p "Path to the log file (Enter = newest log): " path
               path=${path#"${path%%[![:space:]]*}"}; path=${path%"${path##*[![:space:]]}"}   # trim
               path=${path#[\'\"]}; path=${path%[\'\"]}; path=${path/#\~/$HOME}               # dragged-in files come quoted
               if [[ -z $path ]]; then
                   path=$(newest_logs 1); [[ -n $path ]] || { log_info "No previous logs in $LOG_DIR"; return 0; }
                   log_info "No path given — using the newest log: $path"
               fi
               cp -- "$path" "$f" 2>/dev/null || { log_error "Cannot read '$path' (does the file exist, and can you read it?)"; return 0; } ;;
        last)  path=$(newest_logs 1); [[ -n $path ]] || { log_info "No previous logs in $LOG_DIR"; return 0; }; log_info "Using $path"; cp -- "$path" "$f" ;;
    esac
    [[ -s $f ]] || { log_info "Nothing to analyse"; return 0; }
    local dom; dom=$(guess_domain "$f")
    DIAG_DOMAIN=$dom
    diagnose "$f" "$dom"; report_diagnosis
    local c fixable=0
    for c in "${ISSUES[@]}"; do issue_meta "$c"; declare -F "fix_$c" >/dev/null && [[ $IRISK != none && $c != UNKNOWN ]] && fixable=1; done
    if (( fixable )) && ui_ask "Try the automatic fixes now?" y; then
        ( trap - INT; ensure_sudo && apply_fixes ) && ui_ask "Fixes applied. Run the full smart update now?" y && run_action full
    fi
}

action_tools() {
    local t
    while :; do
        t=$(ui_choose "Repair tools" "Run a single repair (each one explains what it does):" \
            mirrors  "🌐 Re-rank mirrors (slow / failing downloads, 404 errors)" \
            keyring  "🔑 Repair the pacman keyring (signature / 'unknown trust' errors)" \
            lock     "🔓 Remove a stale pacman lock (db.lck)" \
            disk     "🧹 Free disk space (cache, journal, AUR build files)" \
            aurclean "🧩 Clean all AUR helper build directories" \
            initramfs "🥾 Rebuild initramfs images (mkinitcpio -P)" \
            clock    "🕒 Turn on time synchronisation (NTP)" \
            pacnew   "📝 Merge .pacnew config files (pacdiff)" \
            orphans  "🗑️  Remove orphans and old cached packages" \
            rebuild  "♻️  Rebuild AUR packages broken by library / Python / Perl updates" \
            stale    "🕰️  Prepare a long-outdated system (retired repos, mirrors, keyring)" \
            helperfix "🧰 Repair a broken AUR helper (paru / yay won't start)" \
            services "🔁 Restart failed services (and check they really run)" \
            deps     "📦 Check requirements (what the script needs, and why)" \
            back     "← Back") || return 0
        [[ $t == back ]] && return 0
        [[ $t == deps ]] && { deps_check setup; pause; continue; }
        (
            trap - INT
            CLEAN_LOG=/dev/null
            local code
            case $t in
                mirrors) code=MIRRORS ;; keyring) code=KEYRING; FIX_COUNT[KEYRING]=1 ;; lock) code=LOCK ;; disk) code=DISK ;;
                aurclean) code=TOOL_AURCLEAN ;; initramfs) code=HOOK ;; clock) code=CERT ;; pacnew) code=TOOL_PACNEW ;; orphans) code=TOOL_ORPHANS ;;
                rebuild) code=TOOL_REBUILD ;; stale) code=TOOL_STALE ;; helperfix) code=AUR_HELPER_BROKEN ;;
                services) collect_failed_units; code=SERVICE_FAILED
                          (( ${#FAILED_UNITS[@]} )) || { log_success "No failed services"; exit 0; } ;;
            esac
            if [[ $GUI == true ]] || tui_ok; then   # dialogs: the plan goes inside the question
                fix_plan "$code" | strip_ansi | sed 's/^   //' >"$TMP/tool-plan.txt"
                ui_ask "$(cat "$TMP/tool-plan.txt")

Run this repair?" y || exit 0
            else
                fix_plan "$code"
                ui_ask "Run this repair?" y || exit 0
            fi
            ensure_sudo || exit 1
            case $t in
                mirrors)  fix_MIRRORS && log_success "Mirrors refreshed" ;;
                keyring)  fix_KEYRING && log_warning "Databases were refreshed: run the full update next to avoid a partial upgrade" ;;
                lock)     if [[ -e $DB_PATH/db.lck ]]; then fix_LOCK; else log_success "No lock present"; fi ;;
                disk)     fix_DISK ;;
                rebuild)  FIX_MODE=ask; check_rebuilds ;;
                services) fix_SERVICE_FAILED ;;
                helperfix) HELPER=$(find_aur_helper)
                          if [[ $HELPER == none ]]; then log_info "No AUR helper installed (use 'Install an AUR helper')"
                          elif helper_works "$HELPER"; then log_success "$HELPER starts fine — nothing to repair"
                          else fix_AUR_HELPER_BROKEN; fi ;;
                stale)    [[ -n $(removed_repos_in_conf) ]] && fix_REMOVED_REPO
                          refresh_mirrors
                          if run_step "Sync package databases" pacman runner_sync; then
                              KEYRINGS_TO_UPDATE=(); local k
                              for k in $(pacman -Qu 2>/dev/null | awk '{print $1}' | grep -E -- '-keyring$'); do KEYRINGS_TO_UPDATE+=("$k"); done
                              if (( ${#KEYRINGS_TO_UPDATE[@]} )); then run_step "Keyring update" pacman runner_keyring
                              else log_success "Keyrings are current"; fi
                              log_warning "Now run the full smart update: databases are fresh but packages are not upgraded yet"
                          fi ;;
                aurclean) local d; for d in "$HOME"/.cache/paru/clone/*/ "$HOME"/.cache/yay/*/; do rm -rf -- "${d}src" "${d}pkg" "$d"*.pkg.tar.* 2>/dev/null; done
                          log_success "AUR build files cleaned ($(du -sh "$HOME/.cache" 2>/dev/null | cut -f1) left in ~/.cache)" ;;
                initramfs) fix_HOOK || log_info "mkinitcpio not installed (dracut/booster users: run their own regenerate command)" ;;
                clock)    ensure_clock || log_success "Clock is already synchronised" ;;
                pacnew)   if have pacdiff; then sudo DIFFPROG="${DIFFPROG:-vim -d}" pacdiff; else log_info "Install pacman-contrib for pacdiff"; fi ;;
                orphans)  FIX_MODE=ask; cleanup ;;
            esac
        )
        pause
    done
}

save_config() {
    [[ -f $CONFIG_FILE ]] && cp -- "$CONFIG_FILE" "$CONFIG_FILE.bak"
    local k
    for k in AUR_HELPER FIX_MODE ALLOW_RISKY_AUTO NOTIFY_ENABLED MIRROR_UPDATE_DAYS MIRROR_COUNTRY AUR_BOOTSTRAP \
             DO_AUR DO_FLATPAK DO_SNAP DO_FIRMWARE DO_CLEANUP DO_HEALTH MENU_STYLE UPDATE_VIEW INSTALL_HELPER STALE_DAYS; do
        set_config_value "$k" "${!k}"
    done
    log_success "Settings saved to $CONFIG_FILE (previous version: $CONFIG_FILE.bak)"
}

action_settings() {
    local s v
    onoff() { [[ $1 == true ]] && echo "on" || echo "off"; }
    while :; do
        s=$(ui_choose "Settings" "Select a setting to change (changes apply now; choose Save to keep them):" \
            fixmode "Fix mode: $FIX_MODE   (ask → auto → off)" \
            risky   "Risky fixes allowed in auto mode: $(onoff "$ALLOW_RISKY_AUTO")" \
            helper  "Preferred AUR helper: $AUR_HELPER" \
            aur     "Full update includes AUR: $(onoff "$DO_AUR")" \
            flatpak "Full update includes Flatpak: $(onoff "$DO_FLATPAK")" \
            snap    "Full update includes Snap: $(onoff "$DO_SNAP")" \
            firmware "Full update checks firmware: $(onoff "$DO_FIRMWARE")" \
            cleanup "Full update cleans cache/orphans: $(onoff "$DO_CLEANUP")" \
            mirrors "Mirror refresh: every $MIRROR_UPDATE_DAYS days, country: ${MIRROR_COUNTRY:-worldwide}" \
            notify  "Desktop notifications: $(onoff "$NOTIFY_ENABLED")" \
            style   "Menu style: $MENU_STYLE (modern = mouse · classic = whiptail · plain = numbers)" \
            view    "Live status panel while updating: $( [[ $UPDATE_VIEW == classic ]] && echo off || echo on)" \
            installer "Install software with: ${INSTALL_HELPER:-ask each time} (pacman, paru, yay…)" \
            save    "💾 Save settings" \
            back    "← Back") || return 0
        flip() { [[ ${!1} == true ]] && printf -v "$1" false || printf -v "$1" true; }
        case $s in
            fixmode) case $FIX_MODE in ask) FIX_MODE=auto ;; auto) FIX_MODE=off ;; *) FIX_MODE=ask ;; esac ;;
            risky)   flip ALLOW_RISKY_AUTO ;;
            helper)  v=$(ui_choose "AUR helper" "Preferred helper:" paru paru yay yay pikaur pikaur trizen trizen) && AUR_HELPER=$v ;;
            aur)     flip DO_AUR ;;  flatpak) flip DO_FLATPAK ;;  snap) flip DO_SNAP ;;
            firmware) flip DO_FIRMWARE ;;  cleanup) flip DO_CLEANUP ;;  notify) flip NOTIFY_ENABLED ;;
            mirrors) if tui_ok; then
                         tui_input "Mirror refresh" "Refresh mirrors every how many days?" "$MIRROR_UPDATE_DAYS" \
                             && [[ $TUI_INPUT =~ ^[0-9]+$ ]] && MIRROR_UPDATE_DAYS=$TUI_INPUT
                         tui_input "Mirror countries" "Countries for reflector, comma separated (e.g. Germany,Netherlands). Leave empty for worldwide." "$MIRROR_COUNTRY" \
                             && MIRROR_COUNTRY=$TUI_INPUT
                     else
                         read -r -p "Refresh mirrors every how many days? [$MIRROR_UPDATE_DAYS] " v; [[ $v =~ ^[0-9]+$ ]] && MIRROR_UPDATE_DAYS=$v
                         read -r -p "Countries for reflector (comma separated, empty = worldwide) [$MIRROR_COUNTRY]: " v; [[ -n $v ]] && MIRROR_COUNTRY=$v
                     fi ;;
            style)   case $MENU_STYLE in auto|modern) MENU_STYLE=classic ;; classic) MENU_STYLE=plain ;; *) MENU_STYLE=modern ;; esac ;;
            view)    [[ $UPDATE_VIEW == classic ]] && UPDATE_VIEW=panel || UPDATE_VIEW=classic ;;
            installer) local io=(ask "Ask each time") t
                     for t in pacman paru yay pikaur trizen pamac; do have "$t" && io+=("$t" "$t"); done
                     v=$(ui_choose "Install software with" "Preferred tool (you can still pick another one each time):" "${io[@]}") \
                         && { [[ $v == ask ]] && INSTALL_HELPER="" || INSTALL_HELPER=$v; } ;;
            save)    save_config; pause ;;
            back|"") return 0 ;;
        esac
    done
}

action_logs() {
    local logs=() l k=() choice
    mapfile -t logs < <(newest_logs 8)
    (( ${#logs[@]} )) || { log_info "No logs yet in $LOG_DIR"; return 0; }
    for l in "${logs[@]}"; do
        local tag=""; grep -q '^\[ERROR\]' "$l" && tag=" ⚠ had errors"
        k+=("$l" "$(basename "$l")$tag")
    done
    choice=$(ui_choose "Logs" "Open a log:" "${k[@]}") || return 0
    if have less; then less -R "$choice"; else tail -n 120 "$choice"; fi
}

interactive_menu() {
    local choice
    trap 'printf "\n"' INT     # Ctrl+C stops the current action and returns here
    while :; do
        choice=$(ui_choose "$APP_TITLE v$VERSION" "$(menu_status)" \
            @update  "Update" \
            full     "🚀 Full smart update (official + AUR + apps + cleanup)" \
            official "📦 Update official packages only" \
            aur      "🧩 Update AUR packages only" \
            apps     "📱 Update Flatpak / Snap apps" \
            download "⬇️  Download updates now, install later (good for slow/unstable internet)" \
            preview  "👀 Preview available updates (no changes)" \
            @repair  "Diagnose & repair" \
            diagnose "🔎 Diagnose an error (paste text or open a log) and fix it" \
            tools    "🔧 Repair tools" \
            news     "📰 Arch news and pre-flight checks" \
            helper   "🧰 Install an AUR helper (paru / yay)" \
            @software "Software" \
            install  "📥 Install software (search repos + AUR, see exactly what gets installed)" \
            uninstall "📤 Uninstall software (see how it was installed, what goes, full clean)" \
            @system  "System" \
            health   "🩺 Health report (services, .pacnew, disks, reboot)" \
            report   "🧾 Detailed system report (what could interfere with updates, and why)" \
            logs     "📜 View logs" \
            settings "⚙️  Settings" \
            quit     "🚪 Quit") || break
        case $choice in tools|settings|logs|quit|"") ;; *) screen_fresh ;; esac
        case $choice in
            full|official|aur|apps|preview|download) run_action "$choice" ;;
            news)     ( trap - INT; preflight ) ;;
            diagnose) action_diagnose ;;
            install)  ( trap - INT; action_install ) ;;
            uninstall) ( trap - INT; action_uninstall ) ;;
            tools)    action_tools; continue ;;
            helper)   ( trap - INT
                        h=$(find_aur_helper)
                        if [[ $h != none ]] && ! ui_ask "'$h' is already installed. Install another helper anyway?" n; then exit 0; fi
                        install_aur_helper ) ;;
            health)   ( trap - INT; post_maintenance; health_report; reboot_check ) ;;
            settings) action_settings; continue ;;
            logs)     action_logs; continue ;;
            report)   ( trap - INT; write_report deep; [[ -n $REPORT_FILE ]] && { if [[ -t 0 ]]; then less -R "$REPORT_FILE"; else ui_message "Report" "$(cat "$REPORT_FILE")"; fi; } ) ;;
            quit|"")  break ;;
        esac
        pause
    done
    trap 'echo; log_warning "Interrupted by user"; exit 130' INT
    printf '%sBye — data downloaded this session: %s%s\n' "$GRAY" "$(human "$(net_used)")" "$NC"
}

# ======================================================================
# ONE SESSION AT A TIME — a second terminal gets a live view of the first
# ======================================================================
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/smart-update-$UID.lock"
STATE_FILE="${XDG_RUNTIME_DIR:-/tmp}/smart-update-$UID.state"
SESSION_OWNED=false
SESSION_MODE=menu            # menu | update | task
SESSION_TTY=""
SESSION_START=0
declare -A S=()              # the state file, as read by state_read

session_alive() { [[ -n $1 ]] && kill -0 "$1" 2>/dev/null && grep -qa 'smart-update' "/proc/$1/cmdline" 2>/dev/null; }

state_read() {
    local k v; S=()
    [[ -r $STATE_FILE ]] || return 1
    while IFS='=' read -r k v; do [[ -n $k ]] && S[$k]=$v; done <"$STATE_FILE"
}

state_write() {  # publish what this session is doing (read by the live panel and by a second terminal)
    [[ $SESSION_OWNED == true ]] || return 0
    local f="$STATE_FILE.$$.$BASHPID" i ph=""
    for i in "${!PHASE_KEYS[@]}"; do ph+="${PHASE_STATE[i]}:${PHASE_LABELS[i]};"; done
    {
        printf 'pid=%s\ntty=%s\nstarted=%s\nmode=%s\n' "$$" "$SESSION_TTY" "$SESSION_START" "$SESSION_MODE"
        printf 'log=%s\nattempt=%s\ntmp=%s\nrun_start=%s\n' "$LOG_FILE" "$ATTEMPT_LOG" "$TMP" "$RUN_START"
        printf 'phases=%s\ncur=%s\nbase_net=%s\ntask=%s\n' "$ph" "$PHASE_CUR" "$BASE_NET" "${TASK_LABEL:-}"
    } >"$f" 2>/dev/null && mv -f "$f" "$STATE_FILE" 2>/dev/null
}

session_claim() {  # 0 = this process now owns the session
    local fd rc=0
    exec {fd}>>"$LOCK_FILE" 2>/dev/null || { SESSION_OWNED=true; return 0; }
    if have flock && ! flock -w 5 "$fd"; then exec {fd}>&-; return 1; fi
    state_read
    if [[ -n ${S[pid]:-} && ${S[pid]} != "$$" ]] && session_alive "${S[pid]}"; then rc=1
    else
        SESSION_OWNED=true SESSION_MODE=menu SESSION_START=$(date +%s)
        SESSION_TTY=$(tty 2>/dev/null); [[ $SESSION_TTY == "not a tty" ]] && SESSION_TTY="no terminal"
        SESSION_TTY=${SESSION_TTY#/dev/}
        state_write
    fi
    have flock && flock -u "$fd"
    exec {fd}>&-
    return $rc
}

session_release() { [[ $SESSION_OWNED == true ]] && state_read && [[ ${S[pid]:-} == "$$" ]] && rm -f "$STATE_FILE"; return 0; }

session_set() { SESSION_MODE=$1; TASK_LABEL=${2:-}; state_write; }   # session_set menu|update|task [label]

viewer_draw() {  # full-screen live view of the session that runs in another terminal
    local y r st lbl ph i cur icon col el out=() step sub rows
    (( TUI_RESIZED )) && tui_size
    TUI_BUF=$'\033[0m\033[2J'
    BASE_NET=${S[base_net]:-0}
    tui_header "Live view"
    tui_at 3 3; TUI_BUF+="$T_B${T_ACC}Smart Update is already running in another terminal$T_R"
    tui_at 4 3; TUI_BUF+="$T_DIM${S[tty]:-?} · PID ${S[pid]:-?} · opened $(date -d "@${S[started]:-0}" '+%H:%M' 2>/dev/null)$T_R"
    tui_at 5 3; TUI_BUF+="${T_DIM}Only one session can change the system at a time. This screen shows what it is doing.$T_R"
    y=7
    if [[ ${S[mode]} == menu ]]; then
        tui_wrap $(( TUI_COLS - 8 )) "That session is open in its menu and is not changing anything right now. Use that terminal, or close it — this screen continues automatically as soon as it closes."
        for r in "${TUI_LINES[@]}"; do tui_at "$y" 4; TUI_BUF+="$T_FG$r$T_R"; (( y++ )); done
    else
        step=$(cat "${S[tmp]}/step" 2>/dev/null); sub=$(cat "${S[tmp]}/substep" 2>/dev/null)
        if [[ ${S[mode]} == task ]]; then
            tui_at "$y" 4; TUI_BUF+="$T_ACC▶$T_R $T_B${S[task]}$T_R"; (( y++ ))
        else
            IFS=';' read -ra ph <<<"${S[phases]}"
            for i in "${!ph[@]}"; do
                [[ -n ${ph[i]} ]] || continue
                st=${ph[i]%%:*} lbl=${ph[i]#*:}
                case $st in ok) icon=✓ col=$T_OK ;; warn) icon=! col=$T_WARN ;; fail) icon=✗ col=$'\033[38;5;203m' ;;
                            run) icon=▶ col=$T_ACC ;; skip) icon=- col=$T_DIM ;; *) icon=· col=$T_DIM ;; esac
                tui_at "$y" 4
                if [[ $st == run ]]; then TUI_BUF+="$col$icon $T_B$lbl$T_R"; tui_fit "$step" $(( TUI_COLS - ${#lbl} - 14 )); TUI_BUF+="$T_DIM  — $TUI_S$T_R"
                else TUI_BUF+="$col$icon $lbl$T_R"; fi
                (( y++ ))
            done
        fi
        if [[ -n ${S[run_start]} && ${S[run_start]} != 0 ]]; then
            el=$(( $(date +%s) - S[run_start] ))
            tui_at $(( y + 1 )) 4; TUI_BUF+="${T_DIM}Elapsed $(fmt_secs "$el")${sub:+  ·  $sub}$T_R"
        fi
        (( y += 3 ))
        rows=$(( TUI_ROWS - y - 2 ))
        if (( rows >= 4 )); then
            tui_box "$y" 3 $(( rows + 2 )) $(( TUI_COLS - 4 )) "$T_LINE" "Latest output"
            local src=${S[attempt]}; [[ -s $src ]] || src=${S[log]}
            mapfile -t out < <(clean_tail "$src" "$rows")
            for (( r = 0; r < ${#out[@]}; r++ )); do
                tui_fit "${out[r]}" $(( TUI_COLS - 10 )); tui_at $(( y + 1 + r )) 5; TUI_BUF+="$T_FG$TUI_S$T_R"
            done
        fi
    fi
    tui_at "$TUI_ROWS" 3; TUI_BUF+="${T_DIM}q / Esc  leave this view — the session in ${S[tty]:-the other terminal} keeps running$T_R"
    tui_flush
}

session_viewer() {  # 0 = the other session ended and this one took over; 1 = the user left
    local last_mode="" last_log="" ticks=0
    tui_theme; tui_enter
    while :; do
        state_read
        if [[ -z ${S[pid]:-} ]] || ! session_alive "${S[pid]}"; then
            tui_leave
            local title="The other session has closed" body="You can continue here now."
            if [[ $last_mode == update && -r $last_log ]]; then
                title="The update in the other terminal has finished"
                body=$(sed -n '/^Duration:/,/^Unresolved:/p' "$last_log" | tail -8)
                [[ -n $body ]] || body="See its log: $last_log"
                body+=$'\n\n'"Log: $last_log"
            fi
            tui_dialog "$title" "$body" 0 1 "Open Smart Update here" Quit
            (( TUI_CHOICE == 0 )) && session_claim && return 0
            return 1
        fi
        last_mode=${S[mode]} last_log=${S[log]}
        viewer_draw
        tui_key 1
        case $K in esc|cancel|ch:q|ch:Q) tui_leave; return 1 ;; esac
        (( ++ticks ))
    done
}

# ======================================================================
# LIVE UPDATE VIEW — a fixed status panel at the bottom, command output scrolls above it
# (a scroll region anchored at row 1 scrolls fast and keeps the terminal's scrollback)
# ======================================================================
declare -a PHASE_KEYS=() PHASE_LABELS=() PHASE_STATE=()
PHASE_CUR=-1
PHASE_UNRES=0
PANEL_ON=false
PANEL_H=5
UPD_NOISE='^[[:space:]]*(g\+\+|gcc|cc|c\+\+|clang\+*|ld|ar|ranlib|strip|libtool:|/usr/bin/[a-z+-]+)[[:space:]]|^(C|CXX|CPP|LD|RUST)FLAGS[[:space:]]*=|^make(\[[0-9]+\])?: (Entering|Leaving|Nothing)|^\[ *[0-9]+%\] |^ +(CC|CXX|LD|AR|CCLD|CXXLD|GEN|INSTALL) |^ +Compiling [a-z0-9_-]+ v|% Total|Dload +Upload|^ *[0-9]+ +[0-9.]+[kMG]? +[0-9]+ |Error while writing index for .*No debugging symbols'

clean_tail() {  # clean_tail FILE N — the last N meaningful lines of a command log (no compiler/curl noise)
    [[ -r $1 ]] || return 0
    tail -n 600 "$1" 2>/dev/null | strip_ansi | grep -avE "$UPD_NOISE" | sed '/^[[:space:]]*$/d' | tail -n "$2"
}

phases_init() {  # the phases this run goes through (shown in the panel and in a second terminal)
    PHASE_KEYS=(pre) PHASE_LABELS=("Pre-flight")
    [[ $DO_OFFICIAL == true ]] && { PHASE_KEYS+=(sys); PHASE_LABELS+=("System packages"); }
    [[ $DO_AUR == true && $DOWNLOAD_ONLY != true ]] && { PHASE_KEYS+=(aur); PHASE_LABELS+=("AUR"); }
    [[ $DO_OFFICIAL == true && $DOWNLOAD_ONLY != true ]] && { PHASE_KEYS+=(fixup); PHASE_LABELS+=("Repairs"); }
    if [[ $DO_FLATPAK == true && $DO_SNAP == true ]]; then PHASE_KEYS+=(apps); PHASE_LABELS+=("Apps")   # the panel cuts labels at a space or "/"
    elif [[ $DO_FLATPAK == true || $DO_SNAP == true ]]; then PHASE_KEYS+=(apps); PHASE_LABELS+=("$([[ $DO_FLATPAK == true ]] && echo Flatpak || echo Snap)"); fi
    PHASE_KEYS+=(maint done) PHASE_LABELS+=("Maintenance" "Report")
    PHASE_STATE=(); local i; for i in "${!PHASE_KEYS[@]}"; do PHASE_STATE+=(wait); done
    PHASE_CUR=-1
}

phase_end() {  # close the running phase: ok, or ! when it left something unresolved
    (( PHASE_CUR >= 0 )) || return 0
    [[ ${PHASE_STATE[PHASE_CUR]} == run ]] || return 0
    if (( ${#UNRESOLVED[@]} > PHASE_UNRES )); then PHASE_STATE[PHASE_CUR]=warn; else PHASE_STATE[PHASE_CUR]=ok; fi
}

phase_begin() {  # phase_begin KEY
    local i
    phase_end
    for i in "${!PHASE_KEYS[@]}"; do
        if [[ ${PHASE_KEYS[i]} == "$1" ]]; then PHASE_CUR=$i; PHASE_STATE[i]=run; PHASE_UNRES=${#UNRESOLVED[@]}
        elif (( i < PHASE_CUR )) && [[ ${PHASE_STATE[i]} == wait ]]; then PHASE_STATE[i]=skip; fi
    done
    [[ -n $TMP ]] && : >"$TMP/substep"
    state_write; panel_draw
}

phase_fail() { (( PHASE_CUR >= 0 )) && PHASE_STATE[PHASE_CUR]=fail; state_write; panel_draw; }

panel_wanted() { tui_ok && [[ -t 1 && $UPDATE_VIEW != classic && -n $TMP ]]; }

panel_rows() { local s; s=$(stty size </dev/tty 2>/dev/null) || s="24 80"; P_ROWS=${s% *} P_COLS=${s#* }; }

panel_region() {  # keep the panel rows out of the scrolling area; panel_region resize -> cursor back inside it
    [[ -e $TMP/panel_on ]] || return 0
    panel_rows
    local bot=$(( P_ROWS - PANEL_H ))
    if [[ $1 == resize ]]; then
        # keep the cursor where it is, but no lower than the area's last row: H index moves down
        # (scrolling only if the cursor would leave the screen), then H rows back up.
        # Then clear the old panel's remains below the area.
        local idx; printf -v idx '%*s' "$PANEL_H" ''; idx=${idx// /$'\033D'}
        printf '\0337\033[r\0338%s\033[%dA\0337\033[%d;1H\033[J\033[1;%dr\0338' \
            "$idx" "$PANEL_H" $(( bot + 1 )) "$bot" >/dev/tty
    else
        printf '\0337\033[1;%dr\0338' "$bot" >/dev/tty
    fi
    printf '%s' "$P_ROWS" >"$TMP/panel_rows"
}

screen_fresh() {  # start on a clear screen: what is visible scrolls up into the scrollback (nothing is lost)
    [[ -t 1 ]] || return 0
    local s r nl; s=$(stty size </dev/tty 2>/dev/null) || s="24 80"; r=${s% *}
    printf -v nl '%*s' "$r" ''; printf '%s\033[H\033[J' "${nl// /$'\n'}" >/dev/tty
}

panel_on() {
    panel_wanted || return 0
    PANEL_ON=true; : >"$TMP/panel_on"
    tui_theme
    screen_fresh
    panel_region
    printf '\033[H' >/dev/tty
    panel_draw
}

panel_off() {
    [[ $PANEL_ON == true ]] || return 0
    phase_end; state_write; panel_draw
    rm -f "$TMP/panel_on"; PANEL_ON=false
    panel_rows   # keep the final panel on screen as the run's last lines; later output goes below it
    printf '\033[r\033[%d;1H\n' "$P_ROWS" >/dev/tty
}

panel_draw() {  # draw the panel (main process at every step; the ticker every 2 s) — reads only files
    [[ -n $TMP && -e $TMP/panel_on && ! -e $TMP/tui_on ]] || return 0
    [[ -n $T_R ]] || tui_theme
    local -A st=(); local k v
    while IFS='=' read -r k v; do st[$k]=$v; done <"$STATE_FILE" 2>/dev/null
    panel_rows
    [[ $(cat "$TMP/panel_rows" 2>/dev/null) == "$P_ROWS" ]] || panel_region resize   # terminal was resized
    local w=$P_COLS b="" ph i s lbl plain="" chips="" icon col n=0 done_n=0 step sub left right bar pct fill
    IFS=';' read -ra ph <<<"${st[phases]}"
    for i in "${!ph[@]}"; do [[ -n ${ph[i]} ]] && (( n++ )); [[ ${ph[i]} == ok:* || ${ph[i]} == warn:* || ${ph[i]} == skip:* || ${ph[i]} == fail:* ]] && (( done_n++ )); done
    for i in "${!ph[@]}"; do
        [[ -n ${ph[i]} ]] || continue
        s=${ph[i]%%:*} lbl=${ph[i]#*:}
        (( w < 100 )) && lbl=${lbl%% *}; lbl=${lbl%%/*}
        case $s in ok) icon=✓ col=$T_OK ;; warn) icon=! col=$T_WARN ;; fail) icon=✗ col=$'\033[38;5;203m' ;;
                    run) icon=▶ col="$T_ACC$T_B" ;; skip) icon=- col=$T_DIM ;; *) icon=· col=$T_DIM ;; esac
        plain+="$icon $lbl   "; chips+="$col$icon $lbl$T_R   "
    done
    (( ${#plain} > w - 2 )) && chips="${T_DIM}phase $(( done_n + 1 ))/$n$T_R"
    step=$(cat "$TMP/step" 2>/dev/null); sub=$(cat "$TMP/substep" 2>/dev/null)
    left=" ◆ $APP_TITLE · ${st[task]:-update}"
    right="⏱ $(fmt_secs $(( $(date +%s) - ${st[run_start]:-$(date +%s)} )))  ↓ $(human "$(net_used)") "
    local y=$(( P_ROWS - PANEL_H + 1 ))
    printf -v k '%*s' $(( w )) ''; b+=$'\0337\033['"$y"$';1H\033[2K'"$T_LINE${k// /─}$T_R"
    tui_spaces "$w"
    b+=$'\033['"$(( y + 1 ))"$';1H\033[2K'"$T_HDR$TUI_S"$'\033['"$(( y + 1 ))"$';1H'"$T_B$left$T_R"
    (( ${#left} + ${#right} + 2 < w )) && b+=$'\033['"$(( y + 1 ));$(( w - ${#right} + 1 ))H$T_HDR$right$T_R"
    b+=$'\033['"$(( y + 2 ))"$';1H\033[2K  '"$chips"
    pct=0; (( n > 0 )) && pct=$(( done_n * 100 / n ))
    local bw=$(( w >= 100 ? 30 : 16 )); fill=$(( pct * bw / 100 ))
    printf -v bar '%*s' "$fill" ''; bar=${bar// /█}; local rest; printf -v rest '%*s' $(( bw - fill )) ''; rest=${rest// /░}
    tui_fit "$step${sub:+  ·  $sub}" $(( w - bw - 12 ))
    b+=$'\033['"$(( y + 3 ))"$';1H\033[2K  '"$T_ACC$bar$T_DIM$rest$T_R $(printf '%3d' "$pct")%  $T_FG$TUI_S$T_R"
    tui_fit "Ctrl+C cancel step · Ctrl+\\ stop all · full output: ${st[log]/#$HOME/\~}" $(( w - 4 ))
    b+=$'\033['"$(( y + 4 ))"$';1H\033[2K  '"$T_DIM$TUI_S$T_R"$'\0338'
    printf '%s' "$b" >/dev/tty 2>/dev/null
}

upd_filter() {  # what the terminal shows of a command: progress lines collapse, compiler/curl noise is hidden
    local sf="$TMP/substep"
    UPD_NOISE_ENV=$UPD_NOISE awk -v sf="$sf" -v red=$'\033[38;5;203m' -v yel=$'\033[38;5;221m' -v grn=$'\033[38;5;114m' \
        -v dim=$'\033[38;5;245m' -v acc=$'\033[38;5;141m' -v rst=$'\033[0m' '
        BEGIN { noise = ENVIRON["UPD_NOISE_ENV"] }   # via the environment: -v would eat the regex backslashes
        function nl()      { if (cl) { printf "\n"; cl = 0 } }
        function status(t) { if (length(t) > 110) t = substr(t, 1, 109) "…"; printf "\r\033[K  %s%s%s", dim, t, rst; cl = 1; fflush() }
        function setsub(t) { printf "%s", t > sf; close(sf) }
        {
            n = split($0, seg, "\r"); line = seg[n]
            gsub(/\033\[[0-9;?]*[A-Za-z]/, "", line)
            if (line ~ /^[[:space:]]*$/) next
            if (line ~ noise)                              { comp++; if (comp % 5 == 1) status("⚙ compiling… " comp " steps"); next }
            if (line ~ /^ +-> Running build hook: /)       { sub(/^ +-> Running build hook: /, "", line); status("building boot image: " line); next }
            if (line ~ /^\( *[0-9]+\/[0-9]+\) /)           { status(line); setsub(line); next }
            if (line ~ /^==> Making package: /)            { nl(); comp = 0; p = line; sub(/^==> Making package: /, "", p); sub(/ \(.*$/, "", p)
                                                             printf "%s▶ Building %s%s\n", acc, p, rst; setsub("Building " p); fflush(); next }
            if (line ~ /^==> Finished making: /)           { nl(); p = line; sub(/^==> Finished making: /, "", p); sub(/ \(.*$/, "", p)
                                                             printf "%s✓ Built %s%s\n", grn, p, rst; fflush(); next }
            if (line ~ /\.\.\. (Passed|Skipped|Found)$/)  { status(line); next }
            # inside prepare()/build()/check()/package(): only a counter, errors and warnings
            if (line ~ /^==> Starting (prepare|build|check|package)\(\)/) { inb = 1; bl = 0; stage = line; sub(/^==> Starting /, "", stage); sub(/\.\.\.$/, "", stage)
                                                             status("⚙ " p ": " stage); next }
            if (line ~ /^==> /) inb = 0
            if (inb) {
                if (line ~ /(^|[^a-z])(error|fatal)[: ]|\*\*\*|FAILED|Error [0-9]/) { nl(); printf "%s%s%s\n", red, line, rst; fflush(); next }
                if (line ~ /(^|[^a-z])warning: /)          { wn++; next }
                if (++bl % 10 == 1) status("⚙ " p ": " stage " — " bl " lines of build output (full text in the log)")
                next
            }
            if (line ~ /^==> ERROR|^error|^fatal|^ERROR/)  { nl(); printf "%s%s%s\n", red, line, rst; fflush(); next }
            if (line ~ /^==> WARNING|^warning/)            { nl(); printf "%s%s%s\n", yel, line, rst; fflush(); next }
            if (line ~ /^(==>|  ->) /)                     { status(line); next }
            nl(); print line; fflush()
        }
        END { nl() }'
}

# ======================================================================
# FAILED SERVICES — restart any failed service and check that it really runs
# ======================================================================
declare -a FAILED_UNITS=()   # "system:unit" / "user:unit"

collect_failed_units() {
    local u
    FAILED_UNITS=()
    for u in $(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do FAILED_UNITS+=("system:$u"); done
    for u in $(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}'); do FAILED_UNITS+=("user:$u"); done
}

unit_restartable() {  # unit_restartable scope unit — a real service with a unit file (not a finished app launch)
    local sc=(systemctl); [[ $1 == user ]] && sc+=(--user)
    [[ $2 == *.service ]] || return 1
    [[ $2 == app-*@*.service || $2 == run-*.service ]] && return 1     # transient: started by the desktop / systemd-run
    [[ -n $("${sc[@]}" show -p FragmentPath --value "$2" 2>/dev/null) ]]
}

# A service that needs the RUNNING kernel's modules/headers (DKMS, BPF/bcc, kernel-module loaders…)
# can't start after a kernel upgrade until you reboot: /usr/lib/modules/$(uname -r) is gone.
declare -a REBOOT_SERVICES=()
REBOOT_SIGNS='/lib/modules/[^ ]*|kheaders|[Mm]odule .* not found in directory|modprobe: FATAL|Failed to compile BPF|[Ii]nvalid module format|[Uu]nknown symbol|[Cc]ould not insert .*module|[Kk]ernel headers .*not found'

kernel_replaced() { [[ ! -d /usr/lib/modules/$(uname -r) ]]; }

unit_journal() {  # unit_journal scope unit lines — this boot's log of a unit
    local j=(journalctl -b --no-pager -o cat -n "${3:-200}"); [[ $1 == user ]] && j+=(--user)
    "${j[@]}" -u "$2" 2>/dev/null
}

service_waits_reboot() {  # service_waits_reboot scope unit — 0 if it fails only because the kernel was replaced
    kernel_replaced || return 1
    local log hit; log=$(unit_journal "$1" "$2" 300)
    hit=$(grep -E "$REBOOT_SIGNS" <<<"$log") || return 1
    # quote the clearest line: a missing /lib/modules path beats a generic "compile failed"
    REBOOT_HINT=$(grep -E -m1 '/lib/modules|not found in directory' <<<"$hit" || head -1 <<<"$hit")
    REBOOT_HINT=${REBOOT_HINT#"${REBOOT_HINT%%[![:space:]]*}"}; return 0
}

note_reboot_service() {  # note_reboot_service unit
    local u=$1 k; k=$(uname -r)
    log_warning "$u needs the kernel files of the running kernel $k, which the update replaced — restarting can't help, a REBOOT fixes it"
    detail "Log: ${REBOOT_HINT:0:160}"
    detail "Why: the new kernel's files are installed, the running one's were removed; after a reboot $u starts normally."
    [[ " ${REBOOT_SERVICES[*]} " == *" $u "* ]] || REBOOT_SERVICES+=("$u")
    UNRESOLVED+=("Service $u starts after a reboot (running kernel $k was replaced)")
}

fix_SERVICE_FAILED() {
    local e scope u sc fixed=0 st res typ REBOOT_HINT=""
    (( ${#FAILED_UNITS[@]} )) || collect_failed_units
    for e in "${FAILED_UNITS[@]}"; do
        scope=${e%%:*} u=${e#*:}
        if [[ $scope == user ]]; then sc=(systemctl --user); else sc=(sudo systemctl); fi
        if unit_restartable "$scope" "$u" && service_waits_reboot "$scope" "$u"; then
            note_reboot_service "$u"; continue      # leave it failed: a restart would just crash-loop again
        fi
        "${sc[@]}" reset-failed "$u" 2>/dev/null    # also clears "start request repeated too quickly"
        if ! unit_restartable "$scope" "$u"; then
            log_fix "$u: cleared (a finished app launch or a non-service unit — nothing to restart)"; fixed=1; continue
        fi
        log_fix "Restarting $u"
        timeout 60 "${sc[@]}" restart "$u" 2>&1 | tail -2
        sleep 3
        if [[ $scope == user ]]; then sc=(systemctl --user); else sc=(systemctl); fi
        st=$("${sc[@]}" is-active "$u" 2>/dev/null)
        typ=$("${sc[@]}" show -p Type --value "$u" 2>/dev/null); res=$("${sc[@]}" show -p Result --value "$u" 2>/dev/null)
        if [[ $st == active || ( $typ == oneshot && $res == success && $st != failed ) ]]; then
            log_success "$u is running again"; fixed=1
        else
            if service_waits_reboot "$scope" "$u"; then note_reboot_service "$u"; continue; fi
            log_warning "$u still fails after a restart ($st, result: ${res:-?}) — the problem is in the service itself:"
            if [[ $scope == user ]]; then journalctl --user -u "$u" -n 4 --no-pager -o cat 2>/dev/null | detail
            else journalctl -u "$u" -n 4 --no-pager -o cat 2>/dev/null | detail; fi
            local why; why=$(explain_service "$u"); [[ -n $why ]] && detail "Why: $why"
            UNRESOLVED+=("Service $u still fails after a restart")
        fi
    done
    (( fixed ))
}

# ======================================================================
# SOFTWARE — search, install (pacman or any AUR helper) and uninstall with a full preview
# ======================================================================
PROTECTED_PKGS='base|filesystem|glibc|gcc-libs|bash|coreutils|pacman|systemd|systemd-libs|sudo|util-linux|shadow|linux|linux-lts|linux-zen|linux-hardened|linux-firmware|archlinux-keyring|grub|mkinitcpio|dbus|openssl|zlib'

ui_input() {  # ui_input TITLE PROMPT DEFAULT -> TUI_INPUT; 1 = cancelled
    if tui_ok; then tui_input "$@"; return; fi
    local v; [[ -t 0 ]] || return 1
    read -e -r -p "$2 ${3:+[$3] }" v || return 1
    TUI_INPUT=${v:-$3}
}

ui_dialog() {  # ui_dialog TITLE BODY FOCUS CANCEL BUTTON... -> TUI_CHOICE
    if tui_ok; then tui_dialog "$@"; return; fi
    local title=$1 body=$2 cancel=$4 i=0 l args=() c
    shift 4
    printf '\n%s━━ %s ━━%s\n%s\n' "$BOLD$PURPLE" "$title" "$NC" "$body" >&2
    for l in "$@"; do args+=("$i" "$l"); (( i++ )); done
    c=$(MENU_STYLE=plain ui_choose "$title" "Choose:" "${args[@]}") || { TUI_CHOICE=$cancel; return 0; }
    TUI_CHOICE=$c
}

aur_json() {  # aur_json URL MODE — MODE search: "name|version|votes|popularity|outofdate|description"; info: KEY=value lines
    local out
    out=$(curl -fsS --max-time 20 "$1" 2>/dev/null) || return 1
    have python3 || return 1
    python3 -I -c '
import json, sys
mode = sys.argv[1]
d = json.loads(sys.stdin.read())
for r in d.get("results", []):
    if mode == "search":
        desc = (r.get("Description") or "").replace("|", "/").replace("\n", " ")
        print("%s|%s|%s|%.2f|%s|%s" % (r["Name"], r.get("Version", ""), r.get("NumVotes", 0),
              r.get("Popularity", 0) or 0, "1" if r.get("OutOfDate") else "", desc))
    else:
        for k in ("Name", "Version", "Description", "Maintainer", "NumVotes", "Popularity", "OutOfDate", "LastModified", "URL"):
            print("%s=%s" % (k, r.get(k) if r.get(k) is not None else ""))
        for k in ("Depends", "MakeDepends", "CheckDepends", "OptDepends"):
            print("%s=%s" % (k, "\t".join(r.get(k, []))))
' "$2" <<<"$out"
}

pkg_name_of() { local d=${1%%:*}; d=${d%%[<>=]*}; printf '%s' "$d"; }   # "foo>=1.2: desc" -> foo

pm_search() {  # pm_search QUERY -> R_KEYS / R_LABELS ("repo:name" / "aur:name")
    local q=$1 line repo name ver rest desc inst tag
    R_KEYS=() R_LABELS=()
    local -a exact=() exactl=() repo_k=() repo_l=() aur_k=() aur_l=()
    local -A seen=()
    while IFS= read -r line; do
        if [[ $line =~ ^([a-z0-9_-]+)/([^ ]+)\ ([^ ]+)(.*)$ ]]; then
            repo=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]} ver=${BASH_REMATCH[3]} rest=${BASH_REMATCH[4]}
            IFS= read -r desc; desc=${desc#"${desc%%[! ]*}"}
            inst=""; [[ $rest == *"[installed"* ]] && inst="✔ installed · "
            seen[$name]=1
            tag="📦 $name $ver  ($inst$repo — $desc)"
            if [[ $name == "$q" ]]; then exact+=("repo:$name"); exactl+=("$tag")
            else repo_k+=("repo:$name"); repo_l+=("$tag"); fi
        fi
    done < <(LC_ALL=C pacman -Ss -- "$q" 2>/dev/null | head -n 160)
    local h; h=$(find_aur_helper)
    local results
    results=$(aur_json "https://aur.archlinux.org/rpc/v5/search/$(urlencode "$q")?by=name-desc" search 2>/dev/null | sort -t'|' -k4,4gr | head -n 50)
    if [[ -z $results && ( $h == paru || $h == yay ) ]]; then   # no python / RPC: ask the helper
        results=$("$h" -Ssa -- "$q" 2>/dev/null | strip_ansi | awk '/^aur\// {split($1,a,"/"); n=a[2]; v=$2; getline d; gsub(/^ +/,"",d); gsub(/\|/,"/",d); print n "|" v "|0|0||" d}' | head -n 50)
    fi
    local votes pop ood
    while IFS='|' read -r name ver votes pop ood desc; do
        [[ -n $name && -z ${seen[$name]:-} ]] || continue
        inst=""; pacman -Qq "$name" &>/dev/null && inst="✔ installed · "
        tag="🧩 $name $ver  (${inst}AUR · ★$votes${ood:+ · out of date} — $desc)"
        if [[ $name == "$q" ]]; then exact+=("aur:$name"); exactl+=("$tag")
        else aur_k+=("aur:$name"); aur_l+=("$tag"); fi
    done <<<"$results"
    local i
    (( ${#exact[@]} )) && { R_KEYS+=(@exact); R_LABELS+=("Exact match"); for i in "${!exact[@]}"; do R_KEYS+=("${exact[i]}"); R_LABELS+=("${exactl[i]}"); done; }
    (( ${#repo_k[@]} )) && { R_KEYS+=(@repo); R_LABELS+=("Official repositories"); for i in "${!repo_k[@]}"; do R_KEYS+=("${repo_k[i]}"); R_LABELS+=("${repo_l[i]}"); done; }
    (( ${#aur_k[@]} )) && { R_KEYS+=(@aur); R_LABELS+=("AUR (community builds — review before installing)"); for i in "${!aur_k[@]}"; do R_KEYS+=("${aur_k[i]}"); R_LABELS+=("${aur_l[i]}"); done; }
    return 0
}

pm_choose_installer() {  # pm_choose_installer repo|aur -> PM_TOOL (pacman, paru, yay, pikaur, trizen, pamac)
    local kind=$1 h opts=() pref=${INSTALL_HELPER:-}
    [[ $kind == repo ]] && opts+=(pacman "📦 pacman — the official package manager (recommended for repo packages)")
    for h in paru yay pikaur trizen pamac; do
        have "$h" || continue
        case $h in
            paru)   opts+=(paru "🧩 paru — shows the PKGBUILD for review, fast") ;;
            yay)    opts+=(yay "🧩 yay — the most widely used helper") ;;
            *)      opts+=("$h" "🧩 $h") ;;
        esac
    done
    if (( ${#opts[@]} == 0 )); then log_warning "AUR packages need an AUR helper — install one from the main menu (Install an AUR helper)"; return 1; fi
    if (( ${#opts[@]} == 2 )); then PM_TOOL=${opts[0]}; return 0; fi
    # the preferred tool first
    if [[ -n $pref ]]; then
        local i re=() rest=()
        for (( i = 0; i < ${#opts[@]}; i += 2 )); do
            if [[ ${opts[i]} == "$pref" ]]; then re=("${opts[i]}" "${opts[i+1]} · your last choice"); else rest+=("${opts[i]}" "${opts[i+1]}"); fi
        done
        opts=("${re[@]}" "${rest[@]}")
    fi
    PM_TOOL=$(ui_choose "Install with" "Which tool should install it?" "${opts[@]}") || return 1
    if [[ $PM_TOOL != "$INSTALL_HELPER" ]]; then INSTALL_HELPER=$PM_TOOL; set_config_value INSTALL_HELPER "$PM_TOOL" >/dev/null 2>&1; fi
}

pm_classify_deps() {  # pm_classify_deps DEP... -> DEP_HAVE / DEP_REPO / DEP_AUR (missing deps resolved one level)
    DEP_HAVE=() DEP_REPO=() DEP_AUR=()
    (( $# )) || return 0
    local -A miss=(); local d
    while IFS= read -r d; do [[ -n $d ]] && miss[$d]=1; done < <(pacman -T -- "$@" 2>/dev/null)
    for d in "$@"; do
        if [[ -z ${miss[$d]:-} ]]; then DEP_HAVE+=("$d")
        elif pacman -Sp --print-format %n -- "$d" &>/dev/null </dev/null; then DEP_REPO+=("$d")
        else DEP_AUR+=("$d"); fi
    done
}

pm_dep_users() {  # "used by N other packages" for an installed dependency
    local n r; n=$(pkg_name_of "$1")
    r=$(LC_ALL=C pacman -Qi -- "$n" 2>/dev/null | awk -F': ' '/^Required By/ {print $2}')
    [[ -z $r || $r == None* ]] && return 0
    printf ' · used by %d other package(s)' "$(wc -w <<<"$r")"
}

pm_install_plan() {  # pm_install_plan repo|aur NAME EXTRAS... -> PLAN_TEXT, PLAN_OPT (optional deps not installed)
    local kind=$1 name=$2 d l total=0 n v r s
    shift 2
    local extras=("$@")
    PLAN_TEXT="" PLAN_OPT=() PLAN_MAKE=()
    local -a deps=() optl=()
    if [[ $kind == repo ]]; then
        local info; info=$(LC_ALL=C pacman -Si -- "$name" 2>/dev/null)
        PLAN_TEXT+="$(awk -F': ' '/^Description/ {print $2; exit}' <<<"$info")"$'\n'
        PLAN_TEXT+="Version $(awk -F': ' '/^Version/ {print $2; exit}' <<<"$info") · from [$(awk -F': ' '/^Repository/ {print $2; exit}' <<<"$info")] · signed by the Arch packagers"$'\n\n'
        PLAN_TEXT+="WILL BE INSTALLED"$'\n'
        while IFS='|' read -r n v r s; do
            [[ -n $n ]] || continue
            (( total += s ))
            if [[ $n == "$name" ]]; then PLAN_TEXT+="  + $n $v   (the package you chose, $(human "$s") download)"$'\n'
            else PLAN_TEXT+="  + $n $v   (needed by it, from [$r])"$'\n'; fi
        done < <(LC_ALL=C pacman -Sp --print-format '%n|%v|%r|%s' -- "$name" "${extras[@]}" </dev/null 2>/dev/null)
        PLAN_TEXT+="  Download: $(human "$total")"$'\n'
        read -ra deps <<<"$(awk -F': ' '/^Depends On/ {print $2; exit}' <<<"$info" | sed 's/None//')"
        mapfile -t optl < <(awk '/^Optional Deps/ {f=1; sub(/^[^:]+: */, ""); print; next} f && /^ / {sub(/^ +/, ""); print; next} f {exit}' <<<"$info" | grep -v '^None$')
    else
        local -A ai=(); local k
        while IFS='=' read -r k v; do [[ -n $k ]] && ai[$k]=$v; done < <(aur_json "https://aur.archlinux.org/rpc/v5/info?arg%5B%5D=$(urlencode "$name")" info)
        if [[ -z ${ai[Name]:-} ]]; then PLAN_TEXT="Could not load the AUR details of $name (no answer from aur.archlinux.org, or python3 is missing)."; return 1; fi
        PLAN_TEXT+="${ai[Description]}"$'\n'
        PLAN_TEXT+="Version ${ai[Version]} · AUR · maintainer: ${ai[Maintainer]:-none (orphaned)} · ★${ai[NumVotes]} · updated $(date -d "@${ai[LastModified]:-0}" +%F 2>/dev/null)"$'\n'
        [[ -n ${ai[OutOfDate]} ]] && PLAN_TEXT+="⚠ Flagged out of date since $(date -d "@${ai[OutOfDate]}" +%F 2>/dev/null)"$'\n'
        [[ -z ${ai[Maintainer]} ]] && PLAN_TEXT+="⚠ Orphaned: nobody maintains this package"$'\n'
        PLAN_TEXT+="AUR packages are built on your computer from a script anyone can upload: read the PKGBUILD when the helper shows it."$'\n\n'
        IFS=$'\t' read -ra deps <<<"${ai[Depends]}"
        IFS=$'\t' read -ra optl <<<"${ai[OptDepends]}"
        local -a mk=(); IFS=$'\t' read -ra mk <<<"${ai[MakeDepends]}${ai[CheckDepends]:+$'\t'${ai[CheckDepends]}}"
        PLAN_TEXT+="WILL BE INSTALLED"$'\n'"  + $name ${ai[Version]}   (built from the AUR)"$'\n'
        pm_classify_deps "${deps[@]}"
        local have_deps=("${DEP_HAVE[@]}")
        for d in "${DEP_REPO[@]}"; do PLAN_TEXT+="  + $d   (needed by it, from the official repos)"$'\n'; done
        for d in "${DEP_AUR[@]}"; do PLAN_TEXT+="  + $d   (needed by it, also built from the AUR — plus its own dependencies)"$'\n'; done
        for d in "${extras[@]}"; do PLAN_TEXT+="  + $d   (optional extra you chose)"$'\n'; done
        if (( ${#mk[@]} )); then
            pm_classify_deps "${mk[@]}"
            PLAN_MAKE=("${DEP_REPO[@]}" "${DEP_AUR[@]}")
            if (( ${#PLAN_MAKE[@]} )); then
                PLAN_TEXT+=$'\n'"ONLY NEEDED TO BUILD IT (can be removed right after)"$'\n'
                for d in "${PLAN_MAKE[@]}"; do PLAN_TEXT+="  ~ $d"$'\n'; done
            fi
        fi
        DEP_HAVE=("${have_deps[@]}")
    fi
    # dependencies that are already on the system
    if [[ $kind == repo ]]; then pm_classify_deps "${deps[@]}"; fi
    if (( ${#DEP_HAVE[@]} )); then
        PLAN_TEXT+=$'\n'"ALREADY ON YOUR SYSTEM (it uses them — keep them installed)"$'\n'
        for d in "${DEP_HAVE[@]}"; do PLAN_TEXT+="  ✓ $d$(pm_dep_users "$d")"$'\n'; done
    fi
    # optional extras
    if (( ${#optl[@]} )); then
        PLAN_TEXT+=$'\n'"OPTIONAL — NOT NEEDED, only for extra features (not installed unless you pick them)"$'\n'
        for l in "${optl[@]}"; do
            [[ -n $l ]] || continue
            d=$(pkg_name_of "$l")
            if pacman -Qq -- "$d" &>/dev/null; then PLAN_TEXT+="  ✓ $l   (already installed)"$'\n'
            else PLAN_TEXT+="  ○ $l"$'\n'; PLAN_OPT+=("$d|${l#*: }"); fi
        done
    fi
    return 0
}

pm_pick_extras() {  # toggle optional dependencies -> PICKED (array)
    local e d desc sel choice keys=() i
    local -A on=()
    for d in "${PICKED[@]}"; do on[$d]=1; done
    while :; do
        keys=()
        for e in "${PLAN_OPT[@]}"; do
            d=${e%%|*} desc=${e#*|}
            [[ ${on[$d]:-} ]] && sel=on || sel=off
            keys+=("$d" "$d — ${desc:0:60}: $sel")
        done
        keys+=(done "✅ Done")
        choice=$(ui_choose "Optional extras" "Pick the extras to install with it (click to switch on/off):" "${keys[@]}") || break
        [[ $choice == done ]] && break
        if [[ ${on[$choice]:-} ]]; then unset "on[$choice]"; else on[$choice]=1; fi
    done
    PICKED=("${!on[@]}")
}

pm_run_logged() {  # interactive command (the user answers its questions), output kept for a diagnosis
    local f=$1; shift
    log_info "Running: $*"
    if have script; then script -qefc "$(printf '%q ' "$@")" "$f"; return; fi
    "$@" 2>&1 | tee "$f"; return "${PIPESTATUS[0]}"
}

action_install() {
    local q key kind name choice rc tries=0
    ui_input "Install software" "Search the official repositories and the AUR (name or words from the description):" "" || return 0
    q=${TUI_INPUT//[[:space:]]/ }; q=${q# }; q=${q% }
    [[ -n $q ]] || return 0
    log_info "Searching for '$q'…"
    pm_search "$q"
    if (( ${#R_KEYS[@]} == 0 )); then ui_dialog "Nothing found" "No package matches '$q' in the official repositories or the AUR." 0 0 OK; return 0; fi
    key=$(ui_choose "Results for '$q'" "📦 official repository · 🧩 AUR · ✔ already installed" "${R_KEYS[@]}") || return 0
    kind=${key%%:*} name=${key#*:}
    pm_choose_installer "$kind" || return 0
    PICKED=()
    while :; do
        pm_install_plan "$kind" "$name" "${PICKED[@]}" || { ui_dialog "Package details" "$PLAN_TEXT" 0 0 OK; return 0; }
        local btns=(Install) body="$PLAN_TEXT"$'\n'"Installs with: $PM_TOOL"
        (( ${#PLAN_OPT[@]} )) && btns+=("Extras…")
        btns+=(Cancel)
        ui_dialog "Install $name" "$body" 0 $(( ${#btns[@]} - 1 )) "${btns[@]}"
        choice=${btns[TUI_CHOICE]}
        case $choice in
            Install) break ;;
            "Extras…") pm_pick_extras ;;
            *) return 0 ;;
        esac
    done
    local removemake=false
    if (( ${#PLAN_MAKE[@]} )) && [[ $PM_TOOL == paru || $PM_TOOL == yay ]]; then
        ui_ask "Remove the build-only packages (${PLAN_MAKE[*]}) after it is built? They are not needed to run it." y && removemake=true
    fi
    ensure_sudo || return 1
    session_set task "Installing $name"
    local cmd=() f="$TMP/install-$name.log"
    case $PM_TOOL in
        pacman) cmd=(sudo pacman -S --needed -- "$name" "${PICKED[@]}") ;;
        pamac)  if [[ $kind == aur ]]; then cmd=(pamac build "$name" "${PICKED[@]}"); else cmd=(pamac install "$name" "${PICKED[@]}"); fi ;;
        *)      cmd=("$PM_TOOL" -S --needed); [[ $removemake == true ]] && cmd+=(--removemake); cmd+=(-- "$name" "${PICKED[@]}") ;;
    esac
    while :; do
        log_step "Installing $name with $PM_TOOL"
        pm_run_logged "$f" "${cmd[@]}"; rc=$?
        if pacman -Qq -- "$name" &>/dev/null; then
            log_success "$name is installed ($(pacman -Q -- "$name" | awk '{print $2}'))"
            break
        fi
        (( rc == 0 )) && { log_info "Nothing was installed (cancelled at the question?)"; break; }
        log_error "Installing $name failed (exit code $rc)"
        (( tries++ )) && break
        DIAG_DOMAIN=pacman; [[ $kind == aur ]] && DIAG_DOMAIN=aur
        diagnose "$f" "$DIAG_DOMAIN"; report_diagnosis
        ui_ask "Apply the fixes above and try again?" y || break
        apply_fixes || break
    done
    session_set menu
}

pm_how_installed() {  # how a package came onto the system, from /var/log/pacman.log
    local n=$1 cmd when
    IFS=$'\t' read -r when cmd < <(awk -v n="$n" '
        /\[PACMAN\] Running / { c = $0 }
        index($0, "[ALPM] installed " n " (") { w = substr($1, 2, 10); last = w "\t" c }
        END { print last }' /var/log/pacman.log 2>/dev/null)
    cmd=${cmd#*Running \'}; cmd=${cmd%\'}
    local how
    case $cmd in
        *"/.cache/yay/"*)   how="built from the AUR with yay" ;;
        *"/.cache/paru/"*)  how="built from the AUR with paru" ;;
        *"/.cache/pikaur"*) how="built from the AUR with pikaur" ;;
        *"/tmp/build-"*|*smart-update*) how="built from the AUR by Smart Update" ;;
        "pacman -U"*)       how="installed from a package file (pacman -U)" ;;
        *"pacman -S"*|*"pacman --sync"*) how="installed from the repositories with pacman" ;;
        "")                 how="unknown (older than /var/log/pacman.log)" ;;
        *)                  how="with: ${cmd:0:80}" ;;
    esac
    printf '%s%s' "$how" "${when:+ on $when}"
}

pm_user_data() {  # leftovers a package's programs created in your home folder (exact names only)
    local n=$1 b d c
    local -A seen=()
    for b in "$n" "${n%-bin}" "${n%-git}" "${n%-stable-bin}" "${n%-desktop}"; do
        [[ -n $b && -z ${seen[$b]:-} ]] || continue; seen[$b]=1
        for d in "$HOME/.config" "$HOME/.local/share" "$HOME/.cache" "$HOME/.local/state" "$HOME/.var/app"; do
            for c in "$d"/*; do [[ ${c##*/} == "$b" || ${c,,} == "${d,,}/${b,,}" ]] && [[ -e $c ]] && printf '%s\n' "$c"; done
        done
        [[ -e $HOME/.$b ]] && printf '%s\n' "$HOME/.$b"
    done | sort -u
}

pm_system_leftovers() {  # unowned files the package left in system folders
    local n=$1 d
    for d in /etc /var/lib /var/cache /var/log /opt; do
        [[ -e $d/$n ]] || continue
        pacman -Qqo "$d/$n" &>/dev/null && [[ $(pacman -Qqo "$d/$n" 2>/dev/null) != "$n" ]] && continue   # owned by another package
        printf '%s\n' "$d/$n"
    done
}

pm_trash() {  # move to the desktop Trash (restorable); system paths go to a backup folder
    local p
    for p in "$@"; do
        if [[ $p == "$HOME"/* ]]; then
            if have gio && gio trash -- "$p" 2>/dev/null; then log_fix "Moved to Trash: ${p/#$HOME/\~}"
            else mkdir -p "$STATE_DIR/removed-data" && mv -- "$p" "$STATE_DIR/removed-data/" && log_fix "Moved ${p/#$HOME/\~} → ${STATE_DIR/#$HOME/\~}/removed-data/"; fi
        else
            local bk="/var/lib/smart-update/removed/$(date +%Y%m%d-%H%M%S)"
            sudo mkdir -p "$bk$(dirname "$p")" && sudo mv -- "$p" "$bk$p" && log_fix "Moved $p → $bk$p"
        fi
    done
}

action_uninstall() {
    local q key name info line n v desc tags
    local -a keys=() foreign
    ui_input "Uninstall software" "Search your installed packages (leave empty to list what you installed yourself, newest first):" "" || return 0
    q=${TUI_INPUT# }; q=${q% }
    mapfile -t foreign < <(pacman -Qmq 2>/dev/null)
    local -A isforeign=(); for n in "${foreign[@]}"; do isforeign[$n]=1; done
    local -A explicit=(); for n in $(pacman -Qeq 2>/dev/null); do explicit[$n]=1; done
    add_row() {  # add_row NAME VERSION DESC
        local src=repo why=dependency
        [[ ${isforeign[$1]:-} ]] && src=AUR/local
        [[ ${explicit[$1]:-} ]] && why="installed by you"
        local ic=📦; [[ $src != repo ]] && ic=🧩
        keys+=("$1" "$ic $1 $2  ($src · $why — ${3:0:70})")
    }
    if [[ -z $q ]]; then
        while IFS= read -r n; do
            [[ ${explicit[$n]:-} ]] || continue
            v=$(pacman -Q -- "$n" 2>/dev/null | awk '{print $2}') || continue
            [[ -n $v ]] && add_row "$n" "$v" "$(LC_ALL=C pacman -Qi -- "$n" 2>/dev/null | awk -F': ' '/^Description/ {print $2; exit}')"
        done < <(grep -aoE '\[ALPM\] installed [^ ]+' /var/log/pacman.log 2>/dev/null | awk '{print $3}' | tac | awk '!s[$0]++' | head -n 120)
    else
        while IFS= read -r line; do
            if [[ $line =~ ^local/([^ ]+)\ ([^ ]+) ]]; then
                n=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}; IFS= read -r desc; desc=${desc#"${desc%%[! ]*}"}
                add_row "$n" "$v" "$desc"
            fi
        done < <(LC_ALL=C pacman -Qs -- "$q" 2>/dev/null | head -n 240)
    fi
    (( ${#keys[@]} )) || { ui_dialog "Nothing found" "No installed package matches '${q}'." 0 0 OK; return 0; }
    name=$(ui_choose "Uninstall" "📦 from the repositories · 🧩 AUR / local build" "${keys[@]}") || return 0

    if [[ $name =~ ^($PROTECTED_PKGS)$ ]] || [[ $name == "$(find_aur_helper)" && $name != none ]]; then
        ui_dialog "Protected package" "'$name' is part of the core system (or is your AUR helper). Removing it from here could leave the system unbootable or unable to update, so this menu does not do it.

If you really mean it, use pacman yourself: sudo pacman -R $name" 0 0 OK
        return 0
    fi
    info=$(LC_ALL=C pacman -Qi -- "$name" 2>/dev/null)
    field() { awk -F': ' -v k="$1" '$1 ~ "^"k" *$" {print $2; exit}' <<<"$info"; }
    local reqby optfor src how
    reqby=$(field "Required By"); [[ $reqby == None* ]] && reqby=""
    optfor=$(field "Optional For"); [[ $optfor == None* ]] && optfor=""
    if [[ ${isforeign[$name]:-} ]]; then src="not from the official repositories (AUR or a local build)"; else src="official repositories ($(LC_ALL=C pacman -Si -- "$name" 2>/dev/null | awk -F': ' '/^Repository/ {print $2; exit}'))"; fi
    how=$(pm_how_installed "$name")
    local head
    head="$(field Description)

Version $(field Version) · $(field "Installed Size") on disk
Source: $src
How it was installed: $how
Install reason: $(field "Install Reason")"
    [[ -n $reqby ]] && head+=$'\n'"⚠ Needed by: $reqby"
    [[ -n $optfor ]] && head+=$'\n'"Optional for: $optfor (they keep working without it)"

    local -a data sysd units=()
    mapfile -t data < <(pm_user_data "$name")
    mapfile -t sysd < <(pm_system_leftovers "$name")
    local u
    for u in $(pacman -Qlq -- "$name" 2>/dev/null | grep -E '/usr/lib/systemd/(system|user)/[^/]+\.(service|timer|socket)$'); do
        u=${u##*/}
        if systemctl is-enabled "$u" &>/dev/null; then units+=("system:$u"); elif systemctl --user is-enabled "$u" &>/dev/null; then units+=("user:$u"); fi
    done

    # what each choice removes
    local mode flags plan rm_list keep="" choice
    while :; do
        ui_dialog "Uninstall $name" "$head

Choose how far to go:
• Remove only — the package itself; everything it pulled in stays
• Remove + unneeded dependencies — also what was installed only for it
• Full clean — the above, its saved config backups, enabled services, and the data it created in your home folder" \
            1 3 "Remove only" "Remove + unneeded deps" "Full clean" Cancel
        case $TUI_CHOICE in 0) mode=only flags=(-R) ;; 1) mode=deps flags=(-Rs) ;; 2) mode=full flags=(-Rns) ;; *) return 0 ;; esac
        local pf=${flags[0]//n/}   # -n (no .pacsave) cannot be combined with --print; it does not change the list
        rm_list=$(LC_ALL=C pacman "$pf" -p --print-format '%n %v' -- "$name" 2>&1); local prc=$?
        if (( prc != 0 )) && ! grep -qiE 'breaks dependency|could not satisfy' <<<"$rm_list"; then
            ui_dialog "Cannot preview the removal" "pacman says:"$'\n'"$rm_list" 0 0 Back
            continue
        fi
        if (( prc != 0 )); then
            local cas; cas=$(LC_ALL=C pacman "${pf}c" -p --print-format '%n %v' -- "$name" 2>/dev/null)
            ui_dialog "Other packages need $name" "Removing $name alone would break: ${reqby:-other packages}.

pacman says:
$(grep -E 'breaks|error' <<<"$rm_list" | head -6)

You can remove it together with everything that needs it:
$(sed 's/^/  - /' <<<"$cas")" 1 1 "Remove all of these" Back
            (( TUI_CHOICE == 0 )) || continue
            flags=("${flags[@]/%/c}"); flags=("${flags[0]}"); rm_list=$cas
        fi
        plan="WILL BE REMOVED"$'\n'"$(sed 's/^/  - /' <<<"$rm_list")"
        # its dependencies that stay
        keep=""
        local dep dn
        for dep in $(field "Depends On" | sed 's/None//'); do
            dn=$(pkg_name_of "$dep")
            grep -qE "^$dn " <<<"$rm_list" && continue
            pacman -Qq -- "$dn" &>/dev/null || continue
            keep+="  ✓ $dn$(pm_dep_users "$dn")"$'\n'
        done
        [[ -n $keep ]] && plan+=$'\n\n'"STAYS INSTALLED (other packages or you still need it — keep it)"$'\n'"$keep"
        if [[ $mode == full ]]; then
            (( ${#units[@]} )) && plan+=$'\n'"SERVICES DISABLED AND STOPPED"$'\n'"$(printf '  - %s\n' "${units[@]#*:}")"$'\n'
            (( ${#data[@]} )) && plan+=$'\n'"YOUR DATA FOR IT (moved to the Trash — restorable)"$'\n'"$(for u in "${data[@]}"; do printf '  - %s (%s)\n' "${u/#$HOME/\~}" "$(du -sh -- "$u" 2>/dev/null | cut -f1)"; done)"$'\n'
            (( ${#sysd[@]} )) && plan+=$'\n'"LEFTOVERS IN SYSTEM FOLDERS (moved to /var/lib/smart-update/removed)"$'\n'"$(printf '  - %s\n' "${sysd[@]}")"$'\n'
            (( ${#data[@]} + ${#sysd[@]} )) || plan+=$'\n'"No data folders named after it were found in your home folder."
        fi
        plan+=$'\n'"Command: sudo pacman ${flags[*]} $name"
        ui_dialog "Confirm: uninstall $name" "$plan" 1 1 Uninstall Back
        (( TUI_CHOICE == 0 )) && break
    done

    ensure_sudo || return 1
    session_set task "Uninstalling $name"
    log_step "Uninstalling $name"
    if [[ $mode == full ]]; then
        for u in "${units[@]}"; do
            if [[ $u == user:* ]]; then systemctl --user disable --now "${u#user:}" 2>&1 | tail -1
            else sudo systemctl disable --now "${u#system:}" 2>&1 | tail -1; fi
            log_fix "Disabled ${u#*:}"
        done
    fi
    run_guarded remove sudo env LC_ALL=C pacman "${flags[@]}" --noconfirm -- "$name" 2>&1 | tee "$TMP/uninstall-$name.log"
    if pacman -Qq -- "$name" &>/dev/null; then
        log_error "$name is still installed — see the messages above"
        diagnose "$TMP/uninstall-$name.log" pacman; report_diagnosis
    else
        log_success "$name was removed"
        [[ $mode == full ]] && { (( ${#data[@]} )) && pm_trash "${data[@]}"; (( ${#sysd[@]} )) && pm_trash "${sysd[@]}"; }
    fi
    session_set menu
}

# ======================================================================
# ENTRY POINTS
# ======================================================================
create_config() {
    if [[ -f $CONFIG_FILE ]]; then echo "Config already exists: $CONFIG_FILE"; return; fi
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cat >"$CONFIG_FILE" <<EOF
# Arch Smart Update configuration (created $(date '+%F %T'))
AUR_HELPER="paru"          # paru|yay|pikaur|trizen|pamac
AUR_EXTRA_FLAGS=""         # e.g. "--skipreview" or "--devel"
FIX_MODE="ask"             # ask|auto|off
ALLOW_RISKY_AUTO=false     # auto mode may also move conflicting files / remove blocking AUR pkgs
MAX_ATTEMPTS=4
UI_MODE="auto"             # auto|cli|gui
NOTIFY_ENABLED=true
SNAPSHOT_TOOL="none"       # none|zfs|snapper|timeshift
ZFS_DATASETS="rpool/ROOT rpool/HOME"
ZFS_KEEP_SNAPSHOTS=5
PACCACHE_KEEP=3
JOURNAL_KEEP="2weeks"
MIRROR_UPDATE_DAYS=7
MIRROR_COUNTRY=""          # e.g. "Germany,Netherlands"
MIN_FREE_MB=1500
AI_SUGGEST_CMD=""          # e.g. "claude -p" to get an AI guess for unknown errors
EXTRA_MIRRORS=""           # extra mirrors tried first for blocked packages (Server templates, space separated)
PROXY_URL=""               # e.g. socks5h://127.0.0.1:10808 — used only for packages that cannot be downloaded directly
SNAP_KEEP_ROUTE=false      # true = keep the Snap Store route found on a filtered network, so snapd's own background refreshes work
MIRROR_COUNTRY_CODE=""     # e.g. IR, DE; empty = guess from the time zone (for in-country mirrors)
RESCUE_MAX_MIN=20          # minutes per blocked package
REPORT_MODE="auto"         # auto|deep|off — detailed system report after each run
NOTIFY_TIMEOUT=8           # seconds a desktop notification stays on screen
DO_AUR=true
DO_FLATPAK=true
DO_SNAP=true
DO_FIRMWARE=true
DO_CLEANUP=true
DO_HEALTH=true
EOF
    echo "Created $CONFIG_FILE"
}

install_desktop() {
    local f="$HOME/.local/share/applications/arch-smart-update.desktop"
    mkdir -p "${f%/*}"
    cat >"$f" <<EOF
[Desktop Entry]
Type=Application
Name=Arch Smart Update
Comment=Update your system and fix common problems automatically
Exec=bash "$SELF" --gui
Icon=system-software-update
Terminal=false
Categories=System;
EOF
    echo "Installed launcher: $f"
}

usage() {
    cat <<EOF
$APP_TITLE v$VERSION — a simple, self-repairing updater for Arch Linux

Usage: $PROG [OPTIONS]

Update control
  --dry-run            Show what would happen, change nothing
  --mirrors            Force mirror ranking before updating
  --download-only      Download official updates into the cache now, install later (resumable)
  --slow-net           Start in slow-network mode (no timeouts, fewer parallel downloads)
  --helper NAME        Preferred AUR helper (paru, yay, pikaur, trizen, pamac)
  --no-aur | --no-flatpak | --no-snap | --no-firmware | --no-cleanup | --no-health
  --zfs                ZFS snapshot before updating (or set SNAPSHOT_TOOL)

Error handling
  --auto               Apply safe fixes without asking (non-interactive)
  --risky              With --auto, also apply risky fixes (move unowned conflicting files,
                       remove a blocking AUR package and rebuild it afterwards)
  --no-fix             Diagnose only, never change anything to repair
  --attempts N         Attempts per step (default $MAX_ATTEMPTS)
  --diagnose FILE      Analyse a saved pacman/paru/yay error log and print likely causes and fixes

Interface
  (no options)         On a terminal: open the interactive menu. Otherwise: run the full update
  --menu, -i           Open the interactive menu
  --run                Run the full update directly (skip the menu)
  --install-helper [paru|yay|both]  Install an AUR helper (asks which when omitted)
  --gui                Dialogs + graphical progress (zenity/yad/kdialog), opens a terminal if needed
  --cli                Terminal only
  --no-notify          No desktop notifications

Other
  --setup              Check what the script needs, explain it, and install what is missing
  --config             Write a config template to $CONFIG_FILE
  --install-desktop    Add an application-menu launcher (GUI mode)
  --version, -h|--help

Keys while running
  Ctrl+\\               Emergency stop: ends the whole script from anywhere. During protected
                       steps (pacman installing/removing, keyring, mkinitcpio, locale-gen) it is
                       postponed with a warning and runs as soon as the step has finished.
  Ctrl+C               Cancel the current action (back to the menu), same protection
  [d] at a fix question  Shows what the fix changes and the exact commands it will run

Blocked downloads (filtering, censorship, throttling)
  Packages that fail on several mirrors are fetched one by one: in-country mirrors first (country from
  your time zone or MIRROR_COUNTRY_CODE), EXTRA_MIRRORS, every mirror over HTTP/1.1, plain HTTP,
  DNS-over-HTTPS, a local proxy (v2ray/xray/sing-box/clash/Tor are detected) or PROXY_URL, with aria2c
  multi-mirror downloads when installed. If one still fails and holding it back is provably safe, it
  is held back for this run only (you are asked). pacman verifies every package's signature anyway.
  --report             Write the detailed system report only (network probes included)

Logs: $LOG_DIR
EOF
}

parse_args() {
    while (( $# )); do
        case $1 in
            --dry-run)     DRY_RUN=true ;;
            --report)      REPORT_ONLY=true ;;
            --setup)       SETUP_REQUESTED=true ;;
            --mirrors)     FORCE_MIRRORS=true ;;
            --no-notify)   NOTIFY_ENABLED=false ;;
            --zfs)         SNAPSHOT_TOOL=zfs ;;
            --helper)      AUR_HELPER=${2:?--helper needs a name}; shift ;;
            --auto)        FIX_MODE=auto ;;
            --risky)       ALLOW_RISKY_AUTO=true ;;
            --no-fix)      FIX_MODE=off ;;
            --attempts)    MAX_ATTEMPTS=${2:?}; shift ;;
            --gui)         UI_MODE=gui ;;
            --cli)         UI_MODE=cli ;;
            --no-aur)      DO_AUR=false ;;
            --no-flatpak)  DO_FLATPAK=false ;;
            --no-snap)     DO_SNAP=false ;;
            --no-firmware) DO_FIRMWARE=false ;;
            --no-cleanup)  DO_CLEANUP=false ;;
            --no-health)   DO_HEALTH=false ;;
            --diagnose)    DIAGNOSE_FILE=${2:?--diagnose needs a log file}; shift ;;
            --menu|-i)     MENU_REQUESTED=true ;;
            --run)         MENU_REQUESTED=false ;;
            --download-only) DOWNLOAD_ONLY=true; DO_AUR=false; DO_CLEANUP=false ;;
            --slow-net)    SLOW_LEVEL=1 ;;
            --install-helper) INSTALL_HELPER=${2:-ask}; [[ ${2:-} != -* && -n ${2:-} ]] && shift ;;
            --config)      create_config; exit 0 ;;
            --install-desktop) install_desktop; exit 0 ;;
            --version)     echo "$VERSION"; exit 0 ;;
            -h|--help)     usage; exit 0 ;;
            *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
        esac
        shift
    done
}

on_exit() {
    local rc=$?
    (( TUI_ACTIVE > 0 )) && { TUI_ACTIVE=1; tui_leave; }
    [[ $PANEL_ON == true || -e ${TMP:-/nonexistent}/panel_on ]] && { panel_rows; printf '\033[r\033[%d;1H\n' "$P_ROWS" >/dev/tty 2>/dev/null; }
    [[ $BASHPID == "$$" ]] && snap_route_restore exit
    [[ $BASHPID == "$$" ]] && session_release
    [[ -n $STTY_ORIG ]] && stty "$STTY_ORIG" </dev/tty 2>/dev/null
    [[ -n $SUDO_PID ]] && kill "$SUDO_PID" 2>/dev/null
    [[ -n $TICKER_PID ]] && kill "$TICKER_PID" 2>/dev/null
    [[ -n $PROG_FD ]] && exec {PROG_FD}>&- 2>/dev/null
    [[ -t 1 ]] && printf '\033]0;\007'
    [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"
    exit "$rc"
}

init_runtime() {
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/smart-update.XXXXXX")
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/update_$(date +%Y%m%d_%H%M%S).log"
    trap on_exit EXIT
    trap 'echo; log_warning "Interrupted by user"; exit 130' INT
    trap on_term_signal TERM
    trap on_quit_signal QUIT
    ulimit -c 0 2>/dev/null            # no core files when Ctrl+\ stops a helper program
    [[ -t 0 ]] && STTY_ORIG=$(stty -g </dev/tty 2>/dev/null)
    RUN_EPOCH=$(date +%s)
    BASE_NET=$(net_rx_total)
    mapfile -t CACHE_DIRS < <(pacman-conf CacheDir 2>/dev/null | sed 's:/*$::')
    (( ${#CACHE_DIRS[@]} )) || CACHE_DIRS=(/var/cache/pacman/pkg)
    CACHE_DIR=${CACHE_DIRS[0]}
    DB_PATH=$(pacman-conf DBPath 2>/dev/null | sed 's:/*$::'); DB_PATH=${DB_PATH:-/var/lib/pacman}
    DISTRO_ID=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
    PLOG_START=$( { wc -l </var/log/pacman.log; } 2>/dev/null || echo 0)
}

main() {
    parse_args "$@"

    if [[ -n ${DIAGNOSE_FILE:-} ]]; then
        TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
        CACHE_DIRS=(/var/cache/pacman/pkg); CACHE_DIR=${CACHE_DIRS[0]}
        cp "$DIAGNOSE_FILE" "$TMP/input.log" || exit 1
        local dom; dom=$(guess_domain "$TMP/input.log")
        diagnose "$TMP/input.log" "$dom"; report_diagnosis
        exit 0
    fi

    # Decide on GUI vs CLI
    if [[ $UI_MODE == gui || ( $UI_MODE == auto && ! -t 0 && -n ${DISPLAY:-${WAYLAND_DISPLAY:-}} ) ]]; then
        if detect_gui_tool; then
            GUI=true
            if [[ ! -t 0 && -z ${SMART_UPDATE_IN_TERM:-} ]]; then relaunch_in_terminal || true; fi
        else
            echo "No zenity/yad/kdialog found — falling back to terminal mode (sudo pacman -S zenity)"
        fi
    fi

    # one session per user: a second terminal shows the first one's progress instead of starting another
    if [[ ${REPORT_ONLY:-} != true ]] && ! session_claim; then
        if [[ -t 0 && -t 1 ]]; then
            session_viewer || exit 0
        else
            state_read
            local msg="$APP_TITLE is already running (PID ${S[pid]:-?}, ${S[tty]:-?}) — not starting a second session."
            echo "$msg" >&2
            [[ $GUI == true ]] && ui_message "$APP_TITLE" "$msg"
            exit 3
        fi
    fi
    init_runtime
    state_write
    [[ $GUI == true && ! -t 0 ]] && setup_askpass
    have pacman || { echo "pacman not found — Arch Smart Update is for Arch Linux and Arch-based systems." >&2; exit 1; }
    [[ ${REPORT_ONLY:-} == true ]] || deps_check "${SETUP_REQUESTED:+setup}"
    [[ ${SETUP_REQUESTED:-} == true ]] && return 0
    start_ticker

    if [[ ${REPORT_ONLY:-} == true ]]; then
        write_report deep; cat "$REPORT_FILE"; return 0
    fi
    if [[ -n ${INSTALL_HELPER:-} ]]; then
        local arg=$INSTALL_HELPER; [[ $arg == ask ]] && arg=""
        install_aur_helper "$arg"; return
    fi
    if [[ $MENU_REQUESTED == true || ( -z $MENU_REQUESTED && $# -eq 0 && -t 0 && -t 1 ) ]]; then
        interactive_menu
        return 0
    fi
    gui_choose_tasks
    run_update
    local rc=$?
    if [[ -n ${SMART_UPDATE_IN_TERM:-} && -t 0 ]]; then read -r -p "Press Enter to close…" _; fi
    return "$rc"
}

run_update() {
    FIX_YES_ALL=0
    (( SLOW_LEVEL > 0 )) && build_pacman_conf
    RUN_START=$(date +%s)
    TASK_LABEL="Full update"; [[ $DRY_RUN == true ]] && TASK_LABEL="Preview (no changes)"; [[ $DOWNLOAD_ONLY == true ]] && TASK_LABEL="Download only"
    [[ $DO_OFFICIAL != true && $DO_AUR == true ]] && TASK_LABEL="AUR update"
    [[ $DO_OFFICIAL != true && $DO_AUR != true ]] && TASK_LABEL="Apps update"
    SESSION_MODE=update
    phases_init
    panel_on
    PLOG_START=$( { wc -l </var/log/pacman.log; } 2>/dev/null || echo 0)
    printf '\n  %s◆ %s%s  %sv%s%s\n' "$PURPLE$BOLD" "$APP_TITLE" "$NC" "$GRAY" "$VERSION" "$NC"
    printf '  %s%s  ·  fixes: %s  ·  Ctrl+C skips a step  ·  %s stops%s\n' "$GRAY" "$(date '+%a %-d %b, %H:%M')" "$FIX_MODE" "$STOP_KEY_LABEL" "$NC"
    [[ $DRY_RUN == true ]] && printf '  %sPreview only — nothing will be changed%s\n' "$YELLOW" "$NC"

    phase_begin pre
    preflight
    check_held_last_run
    create_snapshot

    local sys_ok=true
    if [[ $DO_OFFICIAL == true ]]; then
        phase_begin sys
        if update_official; then [[ $DRY_RUN == false ]] && : >"$TMP/sys_updated"; else sys_ok=false; phase_fail; fi
    fi
    if [[ $DO_AUR == true && $DOWNLOAD_ONLY != true ]]; then
        phase_begin aur
        if [[ $sys_ok == true ]]; then update_aur
        else
            log_warning "Skipping AUR updates because the official update did not finish (AUR builds on a half-updated system cause partial upgrades)"
            PHASE_STATE[PHASE_CUR]=skip
        fi
    fi
    # packages removed to unblock the update are rebuilt even when AUR updates are off for this run
    [[ $DO_OFFICIAL == true && $DOWNLOAD_ONLY != true ]] && phase_begin fixup
    rebuild_pending
    # problems that only show up after a successful update
    if [[ $sys_ok == true && $DO_OFFICIAL == true && $DOWNLOAD_ONLY != true ]]; then
        [[ $(find_aur_helper) != none ]] && check_rebuilds
        check_boot_images
    fi
    [[ $DO_FLATPAK == true || $DO_SNAP == true ]] && phase_begin apps
    [[ $DO_FLATPAK == true ]] && update_flatpak
    [[ $DO_SNAP == true ]] && update_snap
    phase_begin maint
    [[ $DO_FIRMWARE == true ]] && check_firmware

    post_maintenance
    [[ $DO_CLEANUP == true && $sys_ok == true ]] && cleanup
    phase_begin done
    [[ $DO_HEALTH == true ]] && health_report
    reboot_check
    if [[ $REPORT_MODE != off && $DRY_RUN == false ]]; then
        if [[ $REPORT_MODE == deep || ${#BLOCKED_FINAL[@]} -gt 0 ]] || printf '%s\n' "${ISSUES_SEEN[@]}" | grep -qE '^(NETWORK|SLOW_NET|MIRRORS|BLOCKED_DL|THIRDPARTY_DB)$'; then
            write_report deep
        else
            write_report
        fi
    fi
    summary
    panel_off
    SESSION_MODE=menu; state_write
    (( ${#UNRESOLVED[@]} == 0 ))
}

main "$@"
