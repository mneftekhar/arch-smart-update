<div align="center">

# ◆ Arch Smart Update

**One command to update Arch Linux — and fix what goes wrong along the way.**

A free, self-repairing **Arch Linux updater** (Bash script): **pacman**, **AUR** (paru / yay),
**Flatpak** and **Snap** in the right order, a clean live view while it works, and a plain-language
explanation, plus a one-click fix, when something fails: keyring and PGP signature errors, mirrors,
db.lck locks, file conflicts, broken dependencies, AUR build failures and partial upgrades.
**Scheduled automatic updates** (late at night, when idle, or at a set time) and a **software search**
that shows popularity, votes and last update. Works on Arch, Manjaro, EndeavourOS, CachyOS and Garuda.

**[Website](https://mneftekhar.github.io/arch-smart-update/)** · [Install](#install) · [What it can fix](#what-it-can-fix)

![Arch Smart Update main menu: update, repair, install software and scheduled updates](screenshots/menu.png)

</div>

---

## Contents

- [Why](#why)
- [Features](#features)
- [Screenshots](#screenshots)
- [Install](#install)
- [Usage](#usage)
- [Scheduled updates](#scheduled-updates)
- [What it can fix](#what-it-can-fix)
- [Configuration](#configuration)
- [Safety](#safety)
- [Requirements](#requirements)
- [License](#license)

---

## Why

Updating Arch is usually one command — until it isn't. A keyring is too old, a mirror is down, an AUR
package won't build, a file conflicts, the network drops halfway. Arch Smart Update runs the whole
update for you, and when a step fails it tells you **what happened, why, and what it will do about
it** — then does it, if you agree.

<sub>[↑ back to contents](#contents)</sub>

## Features

- **Everything in one run** — pre-flight checks and Arch news, official packages, AUR, rebuilds of AUR
  packages broken by library updates, Flatpak, Snap, firmware, cleanup and a health check.
- **A calm live view** — a fixed status panel at the bottom shows the phase, progress, time and data
  used, while the output scrolls above it. Long builds collapse into a single progress line.
- **Explains failures, then fixes them** — 60+ known problems are recognised; each comes with the
  likely cause, the exact commands of the fix, and an undo when there is one.
- **Mouse and keyboard menu** — every item has a hotkey (`1-9`, `0`, `a-z`), arrows work, clicks work.
- **Built for unreliable networks** — resumable downloads, DNS-over-HTTPS fallback, in-country mirrors,
  local proxy detection, and per-package rescue when only some files are blocked.
- **Safe by default** — nothing that changes your system runs without asking (unless you choose
  `--auto`), and stopping is refused while pacman is in the middle of installing.

<sub>[↑ back to contents](#contents)</sub>

## Screenshots

![Demo: a full update from the menu to the summary](site/demo.gif)

<sub>A full update, start to finish — sped up about 3×.</sub>

| Live update | A fix, explained before it runs |
|:---:|:---:|
| ![Live update with the status panel](screenshots/update.png) | ![Fix dialog](screenshots/fix.png) |
| **Summary at the end** | **Settings** |
| ![Summary](screenshots/summary.png) | ![Settings](screenshots/settings.png) |

<sub>Personal details in the screenshots are blurred.</sub>

<sub>[↑ back to contents](#contents)</sub>

## Install

```bash
git clone https://github.com/mneftekhar/arch-smart-update.git
cd arch-smart-update
chmod +x smart-update.sh
./smart-update.sh
```

Optional: add it to your application menu with `./smart-update.sh --install-desktop`.

<sub>[↑ back to contents](#contents)</sub>

## Usage

| Command | What it does |
|---|---|
| `./smart-update.sh` | Opens the menu |
| `./smart-update.sh --run` | Full update straight away |
| `./smart-update.sh --dry-run` | Shows what would be updated, changes nothing |
| `./smart-update.sh --auto` | Applies safe fixes without asking |
| `./smart-update.sh --detailed` | Detailed view: full output, a plan first, you answer every question and can skip steps |
| `./smart-update.sh --schedule` | Set up scheduled updates (see below) |
| `./smart-update.sh --download-only` | Downloads now, install later (good on slow internet) |
| `./smart-update.sh --diagnose FILE` | Explains a saved pacman / paru / yay error log |
| `./smart-update.sh --setup` | Checks what the script needs, explains why, installs what's missing |
| `./smart-update.sh --help` | All options |

**Keys while it runs:** `Ctrl+C` skips the current step · `Ctrl+\` stops everything (postponed
until pacman has finished, so your system is never left half-updated).

<sub>[↑ back to contents](#contents)</sub>

## Scheduled updates

Menu → **⏰ Scheduled updates** (or `./smart-update.sh --schedule`). It installs a systemd **user**
timer (`~/.config/systemd/user/arch-smart-update.timer`), so there is no cron and no root daemon.
Every few minutes the timer runs a quick check, and the update starts only when the moment is right.

| Choice | Options |
|---|---|
| **When** | 🌙 late at night inside a window you pick (e.g. `01:00-06:00`, may cross midnight) while the computer is idle · 💤 any time it is idle · 🕒 at a fixed time |
| **How often** | daily · once a week (pick the day) · weekdays · weekends · your own days (`Mon,Thu`) |
| **Idle means** | no keyboard/mouse for N minutes, CPU load below a limit, no app keeping the screen awake (video, call); a locked screen counts as idle |
| **View** | 🤖 **simple**: fully automatic in the background, safe fixes applied, notification at the end · 🔍 **detailed**: a terminal window opens with a plan and the full output. You answer pacman/AUR/Flatpak questions yourself, confirm every fix, and can skip each step. It counts down 90 s before starting, and you can postpone 1 h or skip |
| **What** | full smart update · official packages only · download only |
| **Rules** | only on AC power · skip on metered connections · a missed run happens at the next idle moment or in the next window · a night with no idle moment is skipped (with a notification) or run at the window's end |

`--schedule status` shows the next run and the last result, `--schedule test` explains why it would
or would not run right now, and `--schedule log` prints its log (`~/.local/state/smart-update/schedule.log`).
To watch a background run live, open the menu in any terminal.

Notes: idle time on KDE Plasma, Sway and Hyprland (Wayland) is read with `swayidle` (the setup
offers to install it); GNOME and X11 work without it; without any of them it waits for the screen to
lock. The simple view needs sudo without a password prompt (the setup explains the options). Turn on
*Run while logged out* (linger) if night updates should also run at the login screen.

<sub>[↑ back to contents](#contents)</sub>

## What it can fix

<details>
<summary><b>pacman and the system</b></summary>

Keyring and signature errors · locked database · broken or outdated mirrors · corrupted downloads ·
file and package conflicts · dependency blocks (including `IgnorePkg`) · removed repositories in
`pacman.conf` · unknown `pacman.conf` options · old database format · partial upgrades · a broken
pacman (via pacman-static) · stale pacman hooks · failed boot-image hooks · DKMS modules · low disk
space · wrong clock / TLS errors · locale warnings · failed services after the update.
</details>

<details>
<summary><b>AUR</b></summary>

Broken AUR helper after a pacman update · missing build tools · missing PGP keys · broken PKGBUILDs ·
unreachable source servers · out-of-memory builds · dependencies that no longer exist · packages that
need a rebuild after library updates · `~/.gnupg` permission problems · stuck gpg-agent.
</details>

<details>
<summary><b>Flatpak and Snap</b></summary>

Disabled or misconfigured Flatpak remotes and missing signing keys · the Flatpak system helper ·
Snap Store unreachable (finds a working route on filtered networks) · snapd not running ·
operations already in progress · snaps blocked by open apps · missing `/snap` link · squashfs
after a kernel update · AppArmor profiles · disk space.
</details>

<details>
<summary><b>Network</b></summary>

DNS failures (DNS-over-HTTPS fallback) · slow or unstable connections · mirrors that time out ·
packages blocked on many mirrors (fetched one by one over other routes, verified by pacman).
</details>

<details>
<summary><b>Leftovers</b></summary>

Broken symlinks — each is classified: leftovers of removed programs and services enabled before they
were renamed are moved to a backup; harmless ones (optional features, packaging quirks) are only listed.
</details>

<sub>[↑ back to contents](#contents)</sub>

## Configuration

Create a commented config file with `./smart-update.sh --config`
(`~/.config/arch-update.conf`). The most useful settings:

| Setting | Default | Meaning |
|---|---|---|
| `FIX_MODE` | `ask` | `ask` before each fix · `auto` apply safe fixes · `off` diagnose only |
| `AUR_HELPER` | `paru` | `paru`, `yay`, `pikaur`, `trizen` or `pamac` |
| `DO_AUR`, `DO_FLATPAK`, `DO_SNAP` | `true` | What a full update includes |
| `MIRROR_COUNTRY` | — | Countries for mirror ranking, e.g. `Germany,Netherlands` |
| `PROXY_URL` | — | Proxy for downloads that are blocked directly |
| `SNAP_KEEP_ROUTE` | `false` | Keep a working Snap Store route between runs |

Most of these can also be changed from **Settings** in the menu.

<sub>[↑ back to contents](#contents)</sub>

## Safety

- Every fix shows what it changes and the exact commands (`Details`) before it runs.
- Your files are moved to a backup folder, not deleted, and the restore command is printed. Only things
  pacman recreates by itself are removed: stale lock files, damaged downloads and package databases.
- Risky fixes (moving conflicting files, removing a blocking package) always ask first,
  even in `--auto` mode unless you also pass `--risky`.
- Every run is logged to `~/.local/log/arch-updates/`.

<sub>[↑ back to contents](#contents)</sub>

## Requirements

Arch Linux or an Arch-based distribution. **You don't need to prepare anything:** on the first run the
script checks what it uses, tells you what is missing and *why*, and installs it if you agree.

| | Packages | Why |
|---|---|---|
| **Needed** | `sudo` `curl` `gawk` `sed` `grep` `findutils` `util-linux` `procps-ng` | Run pacman as root, check the network and read pacman's output — on almost every Arch system already |
| **Recommended** | `pacman-contrib` `reflector` | Count updates safely, clean the cache, merge `.pacnew` files, pick fast mirrors |
| | `git` `base-devel` `rebuild-detector` | Build AUR packages and rebuild the ones a library update broke *(only if you use the AUR)* |
| | `libnotify` | Desktop notifications *(only if they're on)* |
| **Optional** | `aria2` `psmisc` `lm_sensors` `iproute2` | Faster rescue downloads, "who holds this file", temperatures, local proxy detection |

If your package lists are too old to install something on its own, it is queued and installed together
with the next full update — never as a risky partial upgrade. Run the check again anytime with
`./smart-update.sh --setup` or **Repair tools → Check requirements**. Flatpak, Snap and fwupd are used
when installed, never required.

<sub>[↑ back to contents](#contents)</sub>

## License

[MIT](LICENSE) — free to use, change and share.

<sub>[↑ back to contents](#contents)</sub>
