# Install Software Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn **Install software** into a metadata-rich, multi-package installer with clear installed/plugin states, explainable package-variant recommendations, and reliable similar-application suggestions.

**Architecture:** Keep the self-contained Bash script and its existing terminal/GUI front ends. Extend the embedded Python enrichment with a normalized package record and pure, fixture-testable functions; load expensive details on demand and cache them for the current search. Build one selection model shared by comparison, plugin/core resolution, final preview, and grouped pacman/AUR installation.

**Tech Stack:** Bash, pacman, AUR RPC v5, pkgstats, embedded Python 3 standard library, existing modern TUI/Zenity/dialog/plain menus, Python `unittest` and pseudo-terminal integration tests.

## Global Constraints

- This document is the only deliverable of the current request; implementation has not started.
- Preserve the existing uncommitted menu-launch fixes. Integrate or commit them separately before making feature commits.
- Keep `smart-update.sh` self-contained. Do not add a runtime helper file, third-party Python package, AI service, or new required dependency.
- Do not execute a PKGBUILD to obtain metadata. AUR `.SRCINFO` may be downloaded and parsed as inert text.
- Represent unavailable metadata as `null` in records and `Not available` in the UI. Never substitute zero, an empty date, or an invented size.
- Votes, popularity, maintenance age, and recommendations are advisory. Never silently change the user's selected variant or start an installation from a recommendation.
- No package changes before one aggregated preview and explicit confirmation. Keep pacman/AUR helper confirmation prompts enabled.
- All automated installation tests use fixtures, command stubs, or a throwaway pacman database. Never install, remove, or upgrade a real package in a test.
- The repository currently has no test suite. Create the specified offline tests only when implementation of this approved plan begins; do not add unrelated scaffolding.
- Follow `CLAUDE.md`: create commits only when the user asks for them. The commit commands below are optional checkpoints, not permission to commit automatically.

---

## 1. Current Behavior to Preserve

The implementation already contains useful behavior; extend it rather than building a parallel installer.

| Existing code | Behavior to retain |
|---|---|
| `PM_ENRICH_PY` (`smart-update.sh:5822`) | Official/AUR search, pkgstats popularity, AUR votes, last-update labels, categories, plugin parent detection, and variant labels. |
| `pm_search` (`smart-update.sh:6070`) | Grouped `repo:name` / `aur:name` results and basic fallback when Python is unavailable. |
| `pm_about` (`smart-update.sh:6083`) | Details for votes, popularity, last update, homepage, and plugin parent. |
| `pm_install_plan` (`smart-update.sh:6188`) | Direct/runtime/build/optional dependency preview, already-installed dependencies, download estimate, and AUR warning. |
| `pm_pick_extras` (`smart-update.sh:6257`) | Repeated toggle interaction that can be generalized for package selection. |
| `action_install` (`smart-update.sh:6283`) | Installer choice, preview, optional extras, execution, diagnosis, and verification with `pacman -Qq`. |

Already visible and therefore **not** new requirements: AUR votes, last-update date, textual `✔ installed`, basic `needs <parent>` labels, and basic variant labels. New work must make these consistent in all UI modes and add the missing metadata, multi-select, comparison, recommendation, and similar-app behavior.

## 2. Normalized Package Record

Use one JSON-compatible record in `$TMP/search_meta.jsonl` and the per-search detail cache `$TMP/package-details/`. Keep the existing `$TMP/search_meta` temporarily for basic rendering, then remove it only after all callers use the normalized record.

```python
PACKAGE_FIELDS = {
    "name": "", "package_base": "", "source": "", "repository": "",
    "version": "", "description": "", "installed": False,
    "installed_version": "", "votes": None, "popularity": None,
    "user_share": None, "updated": None, "first_submitted": None,
    "out_of_date": None, "download_size": None, "installed_size": None,
    "depends": [], "make_depends": [], "check_depends": [],
    "optional_depends": [], "architectures": [], "licenses": [],
    "maintainer": None, "packager": None, "url": "",
    "provides": [], "conflicts": [], "groups": [], "keywords": [],
    "category": "app", "parent": "", "variant": "source",
}
```

Each record must contain every field. Copy lists when constructing a record so two packages never share a mutable default list.

### Metadata Sources and Honest Fallbacks

| Requested display | Official repositories | AUR |
|---|---|---|
| Votes | `Not used for official packages`; pkgstats share remains separate | `NumVotes`; also show `Popularity` as an AUR score, not a vote count |
| Latest update | `Build Date` from `pacman -Si`, labeled **Package build date** | `LastModified`, labeled **AUR recipe update** |
| First release | `Not tracked by pacman`; do not query the Arch Archive for every result | `FirstSubmitted`, labeled **First submitted to AUR** |
| Package size | `Download Size` from `pacman -Si`, in bytes internally | `Not published by AUR`; after a build, actual artifact size may be shown separately |
| Installed size | `Installed Size` from `pacman -Si` | `Unknown until built`; never estimate it from source size |
| Requirements | `Depends On`, `Optional Deps`; keep optional separate | `Depends`, `MakeDepends`, `CheckDepends`, `OptDepends` |
| Repository | Actual `core`, `extra`, `multilib`, or configured third-party repository | `AUR` |
| Architecture | `Architecture` from `pacman -Si` | Parse `arch =` entries from `.SRCINFO` only when details are opened; on failure show `Not available` |
| Licenses | `Licenses` from `pacman -Si` | `License` from RPC info; empty means `Not declared` |
| Maintainer | `Packager`, labeled **Packager** | `Maintainer`; empty means **Orphaned — no maintainer** |
| Installed state/version | `pacman -Qq` and `pacman -Q` | Same local pacman query; never infer installation from a matching AUR name alone |

Use integer Unix seconds for timestamps and integer bytes for sizes. Render dates with the user's local timezone and ISO `YYYY-MM-DD`; render bytes through the existing `human` helper or an equivalent Python formatter. A missing optional detail must not discard an otherwise valid search result.

### Detail Loading and Cache Rules

- Search rows fetch only the existing lightweight summary: source, version, installed state, votes/popularity, last update, and description.
- Open details, compare, or final preview triggers the richer `pacman -Si`, AUR info, and optional `.SRCINFO` lookups.
- Batch `pacman -Si` for selected official packages and AUR `info?arg[]=` requests in chunks of at most 60.
- Cache successful records by `source:name` for the current search. Cache a failed optional lookup as unknown for five minutes in `$TMP/package-details/failures/` so moving between rows does not repeatedly time out.
- A 15-second metadata timeout produces `Not available` plus a small warning; it does not block selection or the package manager's own dependency resolution.
- Without Python, retain `pm_search_basic`, repeated-toggle multi-select, pacman metadata, and installation. AUR enrichment may be limited to the installed helper's output; label unavailable fields instead of failing the menu.

## 3. Interaction Contract

### Result Rows

- Unselected, not installed: `[ ] package-version`.
- Selected: `[✓] package-version`, using `T_SEL` and the existing accent color.
- Installed: `[installed] package-version installed-version`, using `T_OK` in the modern TUI and the literal marker in classic, GUI, and plain modes.
- Installed and selected for explicit reinstall: `[✓ installed]`, allowed only through **Reinstall**, not ordinary marking.
- Plugin: append `requires core: <parent>` and the parent's `installed`, `selected`, or `missing` state.
- Metadata warnings remain concise in rows; full dates, sizes, requirements, licenses, and maintainers belong in details/compare/preview.

### Controls

| Mode | Mark/unmark | Details | Compare | Install marked | Leave |
|---|---|---|---|---|---|
| Modern TUI | `Space`; keep the results open and advance to the next selectable row | `Enter` | `c` for the highlighted family or selected variants | `i` or the **Install marked** button | `Esc` |
| Classic/GUI | Activate a row to toggle; remain in the repeated selection menu | **Details** action, then choose a package | **Compare** action | **Install marked** | **Back** |
| Plain | Comma/range input such as `1,3-5` to toggle; `+N` / `-N` for one row | `d N` | `c N` | `i` | `q` |

Section headings are not selectable. Ordinary marking of an installed package explains that it is already installed and offers **Reinstall** as a separate action. Selection survives details, comparison, optional-extra selection, and a failed metadata lookup. Starting a new search clears it only after the user confirms when marks exist.

### Selection and Installation Invariants

- `PM_MARKED` stores canonical `repo:name` / `aur:name` keys, not display names.
- Plugin marking computes a required-core closure before the final preview. A missing core is marked automatically and announced: `Required core application <name> was added.`
- An already-installed core satisfies the requirement without being marked.
- If several packages provide the required core, ask which one to use. If none can be found, leave the plugin selected but block confirmation with the exact unresolved parent name.
- Unmarking a core while its plugin remains marked requires either restoring the core or unmarking the dependent plugins; never silently drop the plugin.
- Resolve cycles with a visited set. Pacman/AUR helpers remain authoritative for transitive package dependencies; this closure handles the application-level parent detected by the existing classifier.
- Conflicting selected variants produce a comparison/choice prompt. Do not assume every member of a name family conflicts: actual `Conflicts` metadata is authoritative.
- The final preview lists selected applications, auto-added cores, direct/runtime dependencies, AUR build-only dependencies, optional extras, sizes when known, and unknowns.
- Group execution into one official pacman command and one AUR-helper command, official first. Verify every requested package with `pacman -Qq`; report per-package installed/missing status and preserve failures for diagnosis.

## 4. Variant Comparison and Recommendation

Recognize candidates using `PackageBase`, intersecting `Provides`, the existing `alt`/parent classifier, and conservative normalized names (`foo`, `foo-bin`, `foo-git`). A suffix alone creates a comparison candidate, not a definite conflict or identity claim.

The comparison view contains one row per candidate: source/repository, variant kind, version, installed state, package/recipe update, first submission when available, votes/popularity, maintainer/orphan/out-of-date state, architectures, sizes, direct requirements, and build-only requirements. Label kinds as **official**, **binary repackaging (inferred from -bin)**, **VCS/development (inferred from -git)**, or **source/other — verify PKGBUILD**.

Recommendation order:

1. Identify maintained, not-out-of-date, non-VCS candidates. If none exist, explain that there is no maintained stable recommendation instead of silently promoting a development build.
2. Find the newest actual last-update timestamp in that stable set. If an official package is within 30 days of that timestamp, prefer the official package; otherwise prefer the most recently updated stable candidate. Repository reputation alone must not hide a substantially older build/recipe.
3. When stable candidates are within the same 30-day window, use AUR votes/popularity as the next tie-breaker after the official-package rule, then the exact timestamp. Explain `-bin` as usually faster with fewer build dependencies, and source builds as locally compiled; neither fact alone makes a package trustworthy.
4. Do not recommend `-git` over a maintained stable variant merely because its recipe is newer. Recommend VCS only when it is the sole candidate or the user explicitly asks for development builds.
5. An orphaned or out-of-date candidate receives a visible warning and is ranked below maintained candidates. Age alone never proves that stable software is unsafe.
6. Return `recommended_key`, `reason`, and per-candidate `comparison_rows`. Preselect nothing and never auto-install the recommendation; the user still chooses.

## 5. Similar-Application Suggestions

Similar suggestions are deterministic and explainable. Do not send selection history to an external service and do not invent suggestions when evidence is weak.

- Search the current normalized result set first using shared AUR keywords, pacman groups, category, and significant description terms.
- Exclude the target, members of the same variant family, libraries/documentation, and exact duplicates. Installed alternatives may appear with their installed marker.
- Score each shared keyword 6 points, shared group 4, shared significant description token 2 (maximum 6), and same high-level category 1. Require at least 6 points and return at most five.
- Sort by evidence score, then recent update, then votes/popularity. Attach a reason such as `Shared keyword: photography` or `Same group: video-editors`.
- If the current results contain no reliable alternative, permit one additional official/AUR search using the strongest shared keyword. Reuse the normal timeout/cache and return `No reliable similar applications found` when appropriate.
- Suggestions open in the same result/selection model, so their metadata, comparison, plugin rules, and multi-select behavior remain consistent.

---

### Task 1: Offline Harness and Normalized Metadata Parsers

**Files:**
- Modify: `smart-update.sh:5796-6068`
- Create: `tests/install_software/_helpers.py`
- Create: `tests/install_software/test_metadata.py`

**Interfaces:**
- Consumes: Existing `PM_ENRICH_PY`, AUR RPC info dictionaries, and `pacman -Si` text.
- Produces: `PACKAGE_FIELDS`, `new_package(name)`, `normalize_aur(raw, installed=False)`, `parse_pacman_si(text, installed=False)`, and `load_library()` for offline tests.

- [ ] **Step 1: Write the failing parser tests**

Create `tests/install_software/_helpers.py`:

```python
import re
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "smart-update.sh"

def load_library():
    text = SCRIPT.read_text(encoding="utf-8")
    match = re.search(
        r"read -r -d '' PM_PACKAGE_LIB_PY <<'PYEOF'\n(.*?)\nPYEOF",
        text,
        re.S,
    )
    assert match, "PM_PACKAGE_LIB_PY is not defined"
    namespace = {"__name__": "pm_package_lib"}
    exec(match.group(1), namespace)
    return namespace
```

Create `tests/install_software/test_metadata.py`:

```python
import unittest
from _helpers import load_library

class MetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load_library()

    def test_aur_metadata_and_unknown_sizes(self):
        record = self.lib["normalize_aur"]({
            "Name": "demo-bin", "PackageBase": "demo-bin", "Version": "1.2-1",
            "Description": "Demo", "NumVotes": 42, "Popularity": 1.5,
            "FirstSubmitted": 1600000000, "LastModified": 1700000000,
            "Maintainer": "maint", "License": ["MIT"], "Depends": ["gtk4"],
            "MakeDepends": ["meson"], "CheckDepends": ["pytest"],
            "OptDepends": ["demo-cli: CLI"], "Keywords": ["utility"],
        })
        self.assertEqual(record["votes"], 42)
        self.assertEqual(record["first_submitted"], 1600000000)
        self.assertEqual(record["updated"], 1700000000)
        self.assertEqual(record["depends"], ["gtk4"])
        self.assertEqual(record["licenses"], ["MIT"])
        self.assertIsNone(record["download_size"])
        self.assertIsNone(record["installed_size"])

    def test_official_sizes_license_architecture_and_packager(self):
        record = self.lib["parse_pacman_si"]("""Repository      : extra
Name            : demo
Version         : 1.2-1
Description     : Demo
Architecture    : x86_64
Licenses        : MIT
Depends On      : gtk4  glib2
Optional Deps   : demo-cli: CLI
Download Size   : 1.50 MiB
Installed Size  : 4.00 MiB
Packager        : Example Packager <packager@example.invalid>
Build Date      : Sun Jan 7 03:04:05 2024
""")
        self.assertEqual(record["repository"], "extra")
        self.assertEqual(record["architectures"], ["x86_64"])
        self.assertEqual(record["download_size"], 1572864)
        self.assertEqual(record["installed_size"], 4194304)
        self.assertEqual(record["licenses"], ["MIT"])
        self.assertEqual(record["packager"], "Example Packager <packager@example.invalid>")
        self.assertIsNone(record["first_submitted"])

    def test_records_do_not_share_lists(self):
        first = self.lib["new_package"]("first")
        second = self.lib["new_package"]("second")
        first["depends"].append("gtk4")
        self.assertEqual(second["depends"], [])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
cd /home/mohsen/arch-smart-update
PYTHONPATH=tests/install_software python3 -m unittest discover -s tests/install_software -v
```

Expected: `test_aur_metadata_and_unknown_sizes` and the other tests error with `AssertionError: PM_PACKAGE_LIB_PY is not defined`. This proves the fixture is exercising the new production library rather than a duplicate model.

- [ ] **Step 3: Add the embedded library and parsers**

Add `PM_PACKAGE_LIB_PY` beside `PM_ENRICH_PY`. Implement these exact core functions; `parse_pacman_si` must also preserve continuation lines for optional dependencies and return `new_package(name)` on a missing `Name` only when the input is empty, otherwise raise `ValueError("pacman metadata has no Name")`.

```python
import copy
import re
import time

PACKAGE_FIELDS = {
    "name": "", "package_base": "", "source": "", "repository": "",
    "version": "", "description": "", "installed": False,
    "installed_version": "", "votes": None, "popularity": None,
    "user_share": None, "updated": None, "first_submitted": None,
    "out_of_date": None, "download_size": None, "installed_size": None,
    "depends": [], "make_depends": [], "check_depends": [],
    "optional_depends": [], "architectures": [], "licenses": [],
    "maintainer": None, "packager": None, "url": "",
    "provides": [], "conflicts": [], "groups": [], "keywords": [],
    "category": "app", "parent": "", "variant": "source",
}

def new_package(name):
    record = copy.deepcopy(PACKAGE_FIELDS)
    record["name"] = name
    record["package_base"] = name
    return record

def size_bytes(value):
    if not value or value == "None":
        return None
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*(B|KiB|MiB|GiB|TiB)", value.strip())
    if not match:
        raise ValueError("unknown pacman size: " + value)
    factor = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3, "TiB": 1024**4}
    return round(float(match.group(1)) * factor[match.group(2)])

def normalize_aur(raw, installed=False):
    record = new_package(raw["Name"])
    record.update({
        "package_base": raw.get("PackageBase") or raw["Name"], "source": "aur",
        "repository": "AUR", "version": raw.get("Version") or "",
        "description": raw.get("Description") or "", "installed": installed,
        "votes": raw.get("NumVotes"), "popularity": raw.get("Popularity"),
        "updated": raw.get("LastModified"), "first_submitted": raw.get("FirstSubmitted"),
        "out_of_date": raw.get("OutOfDate"), "depends": list(raw.get("Depends", [])),
        "make_depends": list(raw.get("MakeDepends", [])),
        "check_depends": list(raw.get("CheckDepends", [])),
        "optional_depends": list(raw.get("OptDepends", [])),
        "licenses": list(raw.get("License", [])), "maintainer": raw.get("Maintainer"),
        "url": raw.get("URL") or "", "provides": list(raw.get("Provides", [])),
        "conflicts": list(raw.get("Conflicts", [])), "groups": list(raw.get("Groups", [])),
        "keywords": list(raw.get("Keywords", [])),
    })
    record["variant"] = "binary" if record["name"].endswith("-bin") else (
        "vcs" if record["name"].endswith(("-git", "-svn", "-hg", "-bzr")) else "source")
    return record

def parse_pacman_si(text, installed=False):
    fields = {}
    optional = []
    in_optional = False
    for line in text.splitlines():
        match = re.match(r"^([A-Za-z][A-Za-z ]+?)\s*: (.*)$", line)
        if match:
            key, value = match.group(1), match.group(2)
            fields[key] = value
            in_optional = key == "Optional Deps" and value != "None"
            if in_optional:
                optional.append(value)
        elif in_optional and line.startswith(" "):
            optional.append(line.strip())
        else:
            in_optional = False
    if not fields and not text.strip():
        return new_package("")
    if "Name" not in fields:
        raise ValueError("pacman metadata has no Name")
    record = new_package(fields["Name"])
    split = lambda key: [] if fields.get(key, "None") == "None" else fields[key].split()
    record.update({
        "source": "repo", "repository": fields.get("Repository", ""),
        "version": fields.get("Version", ""), "description": fields.get("Description", ""),
        "installed": installed, "depends": split("Depends On"),
        "optional_depends": optional, "architectures": split("Architecture"),
        "licenses": split("Licenses"), "url": "" if fields.get("URL") == "None" else fields.get("URL", ""),
        "provides": split("Provides"), "conflicts": split("Conflicts With"),
        "groups": split("Groups"), "packager": fields.get("Packager"),
        "download_size": size_bytes(fields.get("Download Size")),
        "installed_size": size_bytes(fields.get("Installed Size")),
    })
    if fields.get("Build Date"):
        record["updated"] = int(time.mktime(time.strptime(fields["Build Date"], "%a %b %d %H:%M:%S %Y")))
    return record
```

Extend `aur_json` info output with `FirstSubmitted`, `PackageBase`, `License`, and `Keywords`; preserve the existing fields consumed by `pm_install_plan`. Parse `.SRCINFO` with a line-oriented `key = value` reader into `architectures`; never source it.

- [ ] **Step 4: Run the parser tests and verify GREEN**

Run the command from Step 2. Expected: `Ran 3 tests` and `OK`. Also run `bash -n smart-update.sh`; expect exit `0`.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh tests/install_software/_helpers.py tests/install_software/test_metadata.py
git commit -m "feat: normalize install package metadata"
```

### Task 2: Complete Details View and On-Demand Cache

**Files:**
- Modify: `smart-update.sh:5796-6104`
- Create: `tests/install_software/test_details.py`
- Create: `tests/install_software/fixtures/aur-srcinfo-demo`

**Interfaces:**
- Consumes: Task 1 normalized records and existing `pm_about NAME`.
- Produces: `package_details(record)`, `pm_details_record SOURCE NAME`, `parse_srcinfo(text, record)`, and `$TMP/package-details/<safe-key>.json`.

- [ ] **Step 1: Write failing rendering/cache tests**

Test that official output contains repository, architecture, download/install sizes, licenses, packager, runtime/optional requirements, and `First release: Not tracked by pacman`. Test that AUR output contains votes, first submission, recipe update, runtime/build/check/optional requirements, maintainer/orphan state, `.SRCINFO` architectures, and explicit unknown sizes. Use `unittest.mock.patch` on the detail-fetch function to prove a second `pm_details_record` call reads cache without another network call.

```python
import unittest
from unittest.mock import patch
from _helpers import load_library

class DetailsTests(unittest.TestCase):
    def test_aur_details_are_complete_and_honest(self):
        lib = load_library()
        record = lib["normalize_aur"]({
            "Name": "demo", "Version": "1-1", "NumVotes": 9,
            "FirstSubmitted": 1600000000, "LastModified": 1700000000,
            "Maintainer": None, "Depends": ["gtk4"], "MakeDepends": ["meson"],
            "CheckDepends": ["python-pytest"], "OptDepends": ["demo-cli: CLI"],
            "License": ["MIT"],
        })
        record = lib["parse_srcinfo"]("pkgbase = demo\narch = x86_64\n", record)
        text = lib["package_details"](record)
        for expected in ("Votes: 9", "First submitted to AUR", "AUR recipe update",
                         "Runtime requirements: gtk4", "Build requirements: meson",
                         "Check requirements: python-pytest", "Architecture: x86_64",
                         "Licenses: MIT", "Orphaned", "Package size: Not published by AUR",
                         "Installed size: Unknown until built"):
            self.assertIn(expected, text)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run details tests and verify RED**

Run `PYTHONPATH=tests/install_software python3 -m unittest discover -s tests/install_software -v`. Expected: the new test fails with `KeyError: 'parse_srcinfo'` or `KeyError: 'package_details'`; Task 1 tests remain green.

- [ ] **Step 3: Implement rendering and cached detail loading**

Add pure functions with these exact labels and null behavior:

```python
def parse_srcinfo(text, record):
    result = dict(record)
    architectures = []
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if key == "arch" and value:
            architectures.append(value)
    result["architectures"] = sorted(set(architectures))
    return result

def join_or(values, fallback):
    return ", ".join(values) if values else fallback

def package_details(record):
    first = ("Not tracked by pacman" if record["source"] == "repo"
             else format_date(record["first_submitted"]))
    package_size = (format_size(record["download_size"]) if record["source"] == "repo"
                    else "Not published by AUR")
    installed_size = (format_size(record["installed_size"]) if record["source"] == "repo"
                      else "Unknown until built")
    maintainer = ((record["packager"] if record["source"] == "repo"
                   else (record["maintainer"] or "Orphaned — no maintainer")) or "Not available")
    lines = [
        "Package: " + record["name"] + " " + record["version"],
        "Repository: " + record["repository"],
        "Architecture: " + join_or(record["architectures"], "Not available"),
        "Package size: " + package_size,
        "Installed size: " + installed_size,
        "Licenses: " + join_or(record["licenses"], "Not declared"),
        "Maintainer / packager: " + maintainer,
        "First release: " + first,
        "Latest update: " + format_date(record["updated"]),
        "Runtime requirements: " + join_or(record["depends"], "None declared"),
        "Build requirements: " + join_or(record["make_depends"], "None declared"),
        "Check requirements: " + join_or(record["check_depends"], "None declared"),
        "Optional requirements: " + join_or(record["optional_depends"], "None declared"),
        "Votes: " + (str(record["votes"]) if record["votes"] is not None else "Not used for official packages"),
    ]
    return "\n".join(lines)
```

Add these exact formatting functions to the same embedded library so tests and Bash use identical formatting:

```python
def format_date(timestamp):
    if timestamp is None:
        return "Not available"
    return time.strftime("%Y-%m-%d", time.localtime(timestamp))

def format_size(value):
    if value is None:
        return "Not available"
    amount = float(value)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if amount < 1024 or unit == "TiB":
            return "%d %s" % (amount, unit) if unit == "B" else "%.1f %s" % (amount, unit)
        amount /= 1024
    raise AssertionError("unreachable size unit")
```


Implement `pm_details_record` with this flow: canonical cache path → cached JSON → batched official/AUR info → AUR `.SRCINFO` only when required → normalized JSON written with `os.replace`. Change `pm_about` to print `package_details` for normalized records and retain the old output only as the basic fallback.

- [ ] **Step 4: Run all metadata/details tests and verify GREEN**

Run the discovery command. Expected: all tests pass, including cache-hit and timeout-to-unknown cases. Run `bash -n smart-update.sh` and `git diff --check`; both must exit `0`.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh tests/install_software
git commit -m "feat: add complete package details"
```

### Task 3: Multi-Select Results and Installed-State Presentation

**Files:**
- Modify: `smart-update.sh:4562-5051` and `smart-update.sh:6009-6140` and `smart-update.sh:6282-6335`
- Create: `tests/install_software/selection_harness.py`
- Create: `tests/install_software/test_selection.py`
- Create: `tests/install_software/pty_selection.py`

**Interfaces:**
- Consumes: Existing `R_KEYS`, `R_LABELS`, `ui_choose`, `tui_menu`, and normalized installed state.
- Produces: global associative `PM_MARKED`, `PM_ACTION`, `PM_FOCUS`, `ui_multiselect`, and `pm_toggle_key KEY`.

- [ ] **Step 1: Write failing selection and PTY tests**

Cover these cases offline: first mark adds a key; second mark adds without clearing the first; unmark removes only that key; section headings and installed packages cannot be marked ordinarily; explicit reinstall can mark an installed key; selection survives a details action. In the PTY test, return three packages, press `Space`, verify the menu remains open and the second row is highlighted, press `Space` again, then `i`, and assert the submitted keys are exactly the first two.

```python
import unittest
from selection_harness import SelectionModel

class SelectionTests(unittest.TestCase):
    def test_sequential_marks_and_installed_guard(self):
        model = SelectionModel({"repo:one": False, "repo:two": False, "aur:old": True})
        self.assertTrue(model.toggle("repo:one"))
        self.assertTrue(model.toggle("repo:two"))
        self.assertEqual(model.keys, ["repo:one", "repo:two"])
        self.assertFalse(model.toggle("aur:old"))
        self.assertEqual(model.notice, "aur:old is already installed; choose Reinstall to install it again")
        self.assertTrue(model.toggle("aur:old", reinstall=True))

if __name__ == "__main__":
    unittest.main()
```

Create `tests/install_software/selection_harness.py` as a wrapper around the real Bash function, not a Python copy of its rules:

```python
import os
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
            result = subprocess.run(
                ["bash", "-c", harness, "--", key, "true" if reinstall else "false"],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
            self.notice = notice.read_text().strip()
            self.keys = keys.read_text().splitlines() if keys.exists() else []
            return result.returncode == 0
```

- [ ] **Step 2: Run selection tests and verify RED**

Run both new test commands:

```bash
PYTHONPATH=tests/install_software python3 -m unittest discover -s tests/install_software -v
python3 tests/install_software/pty_selection.py
```

Expected: shell tests fail because `pm_toggle_key` is undefined; PTY fails because `Space` activates a single result and no marked installation is submitted.

- [ ] **Step 3: Implement shared selection state and all UI modes**

Implement this state transition in Bash and call it from every front end:

```bash
declare -A PM_MARKED=()
PM_ACTION=""
PM_FOCUS=""
PM_NOTICE=""

pm_toggle_key() {
    local key=$1 reinstall=${2:-false} name=${key#*:}
    [[ $key != @* ]] || { PM_NOTICE="Section headings cannot be selected"; return 1; }
    if pacman -Qq -- "$name" &>/dev/null && [[ $reinstall != true ]]; then
        PM_NOTICE="$name is already installed; choose Reinstall to install it again"
        return 1
    fi
    if [[ -n ${PM_MARKED[$key]:-} ]]; then
        unset 'PM_MARKED[$key]'
    else
        PM_MARKED[$key]=1
    fi
    PM_NOTICE=""
    return 0
}
```

Add a multi-select mode to `tui_menu`: selected rows receive a marker and `T_SEL`, installed rows use `T_OK`, `Space` calls `pm_toggle_key` and advances one selectable row, `Enter` returns `details`, `c` returns `compare`, and `i` returns `install` only when `PM_MARKED` is nonempty. Do not route modern `Space` through the existing single-choice `break` path.

Build `ui_multiselect` around the same state for classic/GUI/plain modes using repeated activation and explicit **Details**, **Compare**, **Install marked**, and **Back** rows. Return only through `PM_ACTION` and `PM_MARKED`; do not encode arrays in command-substitution strings.

- [ ] **Step 4: Run all selection tests and verify GREEN**

Run the commands from Step 2. Expected: all unit tests pass and the PTY script prints `PASS: sequential Space selection, installed state, and marked submission`. Check modern, whiptail/dialog, mocked Zenity, and plain modes; no selection may start a real installer.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh tests/install_software
git commit -m "feat: allow marking multiple software packages"
```

### Task 4: Plugin/Core Closure and Aggregated Installation

**Files:**
- Modify: `smart-update.sh:6168-6335`
- Create: `tests/install_software/test_selection_closure.py`
- Create: `tests/install_software/test_batch_install.py`

**Interfaces:**
- Consumes: `PM_MARKED`, normalized `parent`, `depends`, `provides`, `conflicts`, and installed state.
- Produces: `close_selection(records, selected, installed, core_candidates)`, `PM_INSTALL_REPO`, `PM_INSTALL_AUR`, `PM_NOTICES`, `PM_CONFLICTS`, and `pm_install_plan_many`.

- [ ] **Step 1: Write failing plugin, conflict, and batch tests**

Include: installed core adds nothing; missing core adds its canonical key and notice; two plugins share one core; transitive plugin/core chains terminate; cycles terminate; ambiguous providers require choice; unresolved parent blocks confirmation; unmarking a required core reports dependent plugins; actual conflicts require comparison; compatible family members do not produce a false conflict. Stub `pm_run_logged` and assert official packages precede AUR packages and every requested package is verified.

```python
import unittest
from _helpers import load_library

class ClosureTests(unittest.TestCase):
    def test_missing_shared_core_is_added_once(self):
        lib = load_library()
        records = {
            "aur:one-plugin": {"name": "one-plugin", "parent": "coreapp", "conflicts": []},
            "aur:two-plugin": {"name": "two-plugin", "parent": "coreapp", "conflicts": []},
            "repo:coreapp": {"name": "coreapp", "parent": "", "conflicts": []},
        }
        result = lib["close_selection"](
            records, ["aur:one-plugin", "aur:two-plugin"], set(), {"coreapp": ["repo:coreapp"]})
        self.assertEqual(result["selected"], ["aur:one-plugin", "aur:two-plugin", "repo:coreapp"])
        self.assertEqual(result["added"], ["repo:coreapp"])
        self.assertEqual(result["conflicts"], [])

    def test_installed_core_satisfies_requirement(self):
        lib = load_library()
        result = lib["close_selection"](
            {"aur:plugin": {"name": "plugin", "parent": "coreapp", "conflicts": []}},
            ["aur:plugin"], {"coreapp"}, {"coreapp": ["repo:coreapp"]})
        self.assertEqual(result["selected"], ["aur:plugin"])
        self.assertEqual(result["added"], [])

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run closure/batch tests and verify RED**

Run test discovery. Expected: `KeyError: 'close_selection'`; batch tests fail because `action_install` still submits one `$name` rather than the two grouped arrays.

- [ ] **Step 3: Implement closure, aggregated preview, and grouped execution**

Implement `close_selection` as a pure breadth-first traversal using a `pending` list and `visited` set. Return a dictionary with stable user-selection order followed by auto-added cores, `added`, `notices`, `unresolved`, `ambiguous`, and `conflicts`. Never resolve an ambiguous provider by alphabetical order.

Use this result contract for the two core cases:

```python
def close_selection(records, selected, installed, core_candidates):
    result = {"selected": [], "added": [], "notices": [], "unresolved": [],
              "ambiguous": [], "conflicts": []}
    pending = list(selected)
    queued = set(selected)
    visited = set()

    def append_once(bucket, value):
        if value not in result[bucket]:
            result[bucket].append(value)

    while pending:
        key = pending.pop(0)
        if key in visited:
            continue
        visited.add(key)
        record = records.get(key)
        if record is None:
            append_once("unresolved", key)
            continue
        result["selected"].append(key)
        parent = record.get("parent", "")
        if not parent or parent in installed:
            continue
        if any(records[item]["name"] == parent for item in result["selected"]):
            continue
        candidates = core_candidates.get(parent, [])
        if any(candidate in queued for candidate in candidates):
            continue
        if len(candidates) == 1:
            core = candidates[0]
            if core not in records:
                append_once("unresolved", parent)
                continue
            append_once("added", core)
            result["notices"].append("Required core application %s was added" % parent)
            if core not in queued:
                pending.append(core)
                queued.add(core)
        elif candidates:
            append_once("ambiguous", {"parent": parent, "candidates": candidates})
        else:
            append_once("unresolved", parent)

    selected_names = {records[key]["name"] for key in result["selected"]}
    for key in result["selected"]:
        for other in sorted(set(records[key].get("conflicts", [])) & selected_names):
            pair = tuple(sorted((records[key]["name"], other)))
            append_once("conflicts", pair)
    return result
```

This is the complete core traversal: canonical keys and the `queued` set handle shared parents, while `visited` terminates cycles. Pacman/AUR helpers remain responsible for dependency version constraints. `pm_install_plan_many` must refuse confirmation while `unresolved`, `ambiguous`, or `conflicts` is nonempty.

Aggregate existing `pm_install_plan` output for each selected package, deduplicate dependency preview rows by canonical key, sum only known sizes, and display `Unknown size for: <names>` separately. Construct:

```bash
PM_INSTALL_REPO=()
PM_INSTALL_AUR=()
for key in "${!PM_MARKED[@]}"; do
    case $key in
        repo:*) PM_INSTALL_REPO+=("${key#*:}") ;;
        aur:*)  PM_INSTALL_AUR+=("${key#*:}") ;;
    esac
done
```

Sort keys before building the arrays so logs/tests are deterministic. Execute `sudo pacman -S --needed -- "${PM_INSTALL_REPO[@]}"` when nonempty, then the chosen AUR helper for `PM_INSTALL_AUR`. Preserve optional extras per owning package and do not flatten build-only dependencies into the requested application list.

- [ ] **Step 4: Run closure/batch tests and verify GREEN**

Run test discovery. Expected: all closure and command-stub tests pass, no test invokes real `sudo`, pacman installation, or an AUR helper, and the final preview identifies auto-added cores explicitly.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh tests/install_software
git commit -m "feat: install marked packages with plugin dependencies"
```

### Task 5: Variant Comparison and Explainable Maintenance Recommendations

**Files:**
- Modify: `smart-update.sh:5914-6067` and `smart-update.sh:6282-6335`
- Create: `tests/install_software/test_variants.py`

**Interfaces:**
- Consumes: Normalized records, `package_base`, `provides`, maintainer/update/vote fields, and `PM_MARKED`.
- Produces: `variant_family(record)`, `compare_variants(records, now)`, `recommend_variant(records, now)`, `PM_COMPARE_TEXT`, and `PM_RECOMMENDED_KEY`.

- [ ] **Step 1: Write failing comparison/recommendation tests**

Use an official `demo`, AUR `demo-bin`, AUR `demo-git`, and an orphaned/out-of-date `demo-source`. Assert grouping, full comparison fields, maintained-stable-over-VCS ranking, votes as the tie-breaker only within 30 days, and an explanation containing actual dates and source. Add a separate case proving an old but maintained stable candidate is not labeled unsafe solely because of age.

```python
import unittest
from _helpers import load_library

class VariantTests(unittest.TestCase):
    def test_recent_maintained_binary_beats_vcs_and_orphan(self):
        lib = load_library()
        now = 1800000000
        official = dict(name="demo", source="repo", package_base="demo", provides=[],
                        updated=100, maintainer=None, packager="Packager", out_of_date=None,
                        votes=None, popularity=None, conflicts=[], version="1")
        binary = dict(name="demo-bin", source="aur", package_base="demo-bin", provides=["demo"],
                      updated=now - 86400, maintainer="maint", out_of_date=None,
                      votes=30, popularity=2.0, conflicts=["demo"], version="2")
        vcs = dict(name="demo-git", source="aur", package_base="demo-git", provides=["demo"],
                   updated=now, maintainer="maint", out_of_date=None,
                   votes=100, popularity=4.0, conflicts=["demo"], version="2.r1")
        result = lib["recommend_variant"]([official, binary, vcs], now)
        self.assertEqual(result["recommended_key"], "aur:demo-bin")
        self.assertIn("maintained stable variant", result["reason"])
        self.assertIn("Last update", result["reason"])

if __name__ == "__main__":
    unittest.main()
```

The fixture's official timestamp `100` deliberately proves that an official build date does not automatically defeat a maintained AUR candidate without an explicit explanation; comparison must show that trade-off rather than hiding it.

- [ ] **Step 2: Run variant tests and verify RED**

Run test discovery. Expected: `KeyError: 'recommend_variant'` and no comparison view is reachable from the result menu.

- [ ] **Step 3: Implement comparison and recommendation**

Implement conservative family keys and stable recommendation sorting. Return no recommendation when only ambiguous identity evidence exists.

```python
def variant_family(record):
    if record.get("package_base"):
        base = record["package_base"]
    else:
        base = record["name"]
    for suffix in ("-bin", "-git", "-svn", "-hg", "-bzr"):
        if base.endswith(suffix):
            base = base[:-len(suffix)]
            break
    return base

def recommend_variant(records, now):
    if not records:
        return {"recommended_key": "", "reason": "No comparable variants", "comparison_rows": []}
    stable = [
        record for record in records
        if not record["name"].endswith(("-git", "-svn", "-hg", "-bzr"))
        and bool(record.get("maintainer") or record.get("packager"))
        and not record.get("out_of_date")
    ]
    if not stable:
        if len(records) == 1:
            chosen = records[0]
        else:
            return {"recommended_key": "",
                    "reason": "No maintained stable variant; choose a development build explicitly",
                    "comparison_rows": records}
    else:
        newest = max(record.get("updated") or 0 for record in stable)
        recent = [record for record in stable
                  if newest - (record.get("updated") or 0) <= 30 * 86400]
        official = [record for record in recent if record["source"] == "repo"]
        candidates = official or recent
        chosen = max(candidates, key=lambda record: (
            record.get("votes") or 0, record.get("popularity") or 0,
            record.get("updated") or 0, record["name"]))
    kind = "official package" if chosen["source"] == "repo" else "maintained stable variant"
    reason = "%s; Last update %s; votes %s; popularity %s" % (
        kind, format_date(chosen.get("updated")), chosen.get("votes"),
        chosen.get("popularity"))
    return {"recommended_key": chosen["source"] + ":" + chosen["name"],
            "reason": reason, "comparison_rows": records}
```

`compare_variants` must return every field listed in Section 4 and flag actual conflicts. Wire `c` / **Compare** to this view and include **Use this variant** and **Back** actions; never change `PM_MARKED` until **Use this variant** is activated.

- [ ] **Step 4: Run variant and existing tests and verify GREEN**

Run test discovery. Expected: all variant rules and previous tests pass. In the PTY comparison test, selecting a recommendation changes only the highlighted choice; installation still requires the aggregated confirmation.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh tests/install_software
git commit -m "feat: compare package variants and recommend maintained builds"
```

### Task 6: Evidence-Based Similar Applications

**Files:**
- Modify: `smart-update.sh:5914-6104` and `smart-update.sh:6282-6335`
- Create: `tests/install_software/test_similar.py`

**Interfaces:**
- Consumes: Normalized keywords, groups, category, description, variant family, and metadata cache.
- Produces: `similar_packages(target, candidates)`, `PM_SIMILAR_KEYS`, `PM_SIMILAR_REASONS`, and a **Similar apps** details action.

- [ ] **Step 1: Write failing similarity tests**

Provide candidates sharing a keyword, sharing only a common word such as `program`, belonging to the same variant family, and having no relationship. Assert the threshold, exclusion rules, maximum of five, deterministic ordering, and human-readable evidence.

```python
import unittest
from _helpers import load_library

class SimilarTests(unittest.TestCase):
    def test_shared_keyword_beats_generic_description(self):
        lib = load_library()
        target = dict(name="photo-one", package_base="photo-one", keywords=["photography"],
                      groups=[], category="app", description="Raster editor", updated=10,
                      votes=1, popularity=0)
        related = dict(name="photo-two", package_base="photo-two", keywords=["photography"],
                       groups=[], category="app", description="Image effects", updated=20,
                       votes=5, popularity=1)
        generic = dict(name="writer", package_base="writer", keywords=[], groups=[], category="app",
                       description="A program for notes", updated=100, votes=100, popularity=50)
        result = lib["similar_packages"](target, [target, related, generic])
        self.assertEqual([row["name"] for row in result], ["photo-two"])
        self.assertEqual(result[0]["reason"], "Shared keyword: photography")

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run similarity tests and verify RED**

Run test discovery. Expected: `KeyError: 'similar_packages'`.

- [ ] **Step 3: Implement deterministic suggestions and one optional follow-up search**

Implement tokenization that drops a documented stop-word set (`program`, `application`, `tool`, `utility`, `package`, `linux`, `arch`, `free`, `open`, `source`, and single-character tokens). Apply Section 5's exact score and threshold. Return records augmented only with `reason`; do not mutate the cached package record.

```python
def similar_packages(target, candidates):
    target_family = variant_family(target)
    target_words = significant_words(target.get("description", ""))
    scored = []
    for candidate in candidates:
        if candidate["name"] == target["name"] or variant_family(candidate) == target_family:
            continue
        if candidate.get("category") in ("lib", "other"):
            continue
        shared_keywords = sorted(set(target.get("keywords", [])) & set(candidate.get("keywords", [])))
        shared_groups = sorted(set(target.get("groups", [])) & set(candidate.get("groups", [])))
        shared_words = sorted(target_words & significant_words(candidate.get("description", "")))
        score = 6 * len(shared_keywords) + 4 * len(shared_groups) + min(6, 2 * len(shared_words))
        score += int(candidate.get("category") == target.get("category"))
        if score < 6:
            continue
        reasons = (["Shared keyword: " + ", ".join(shared_keywords)] if shared_keywords else
                   ["Same group: " + ", ".join(shared_groups)] if shared_groups else
                   ["Shared description terms: " + ", ".join(shared_words)])
        row = dict(candidate)
        row["reason"] = reasons[0]
        row["similarity_score"] = score
        scored.append(row)
    scored.sort(key=lambda row: (-row["similarity_score"], -(row.get("updated") or 0),
                                -(row.get("votes") or 0), -(row.get("popularity") or 0), row["name"]))
    return scored[:5]
```

Add the exact tokenizer used by both target and candidates:

```python
STOP_WORDS = frozenset({
    "program", "application", "tool", "utility", "package", "linux", "arch",
    "free", "open", "source", "for", "with", "and", "the", "that", "this",
})

def significant_words(text):
    return {
        word for word in re.findall(r"[a-z0-9][a-z0-9+._-]+", text.lower())
        if len(word) > 1 and word not in STOP_WORDS
    }
```

If no row passes, invoke at most one `pm_search` using the strongest target keyword; merge new normalized records into the cache before rerunning `similar_packages`. Never recursively start another similarity search.

- [ ] **Step 4: Run similarity and existing tests and verify GREEN**

Run test discovery. Expected: all similarity rules and previous tests pass, no network is used by unit tests, and an empty-result PTY case displays `No reliable similar applications found` rather than weak matches.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh tests/install_software
git commit -m "feat: suggest similar applications with evidence"
```

### Task 7: End-to-End Integration, Documentation, and Acceptance

**Files:**
- Modify: `smart-update.sh:6282-6335`
- Modify: `README.md:11-12` and the Install software usage section
- Create: `tests/install_software/e2e_install_menu.py`

**Interfaces:**
- Consumes: All previous interfaces.
- Produces: One complete search → mark → details/compare/similar → core closure → aggregated preview → grouped install/verification flow.

- [ ] **Step 1: Add the failing end-to-end scenario**

Use fixture pacman/AUR responses and a PTY. Search for two applications and one plugin; mark two applications in a row; observe installed coloring/marker on a fourth row; open details and verify every requested field; compare `bin`, source, and `git`; open a similar suggestion; mark a plugin and verify its missing core is added; submit and inspect the aggregated preview. Stub the installer to record commands and emulate `pacman -Qq` only after the fake install.

- [ ] **Step 2: Run the end-to-end scenario and verify RED**

Run `python3 tests/install_software/e2e_install_menu.py`. Expected: a specific failure at the first unfinished integration boundary, with captured terminal output and no real package command executed.

- [ ] **Step 3: Complete integration and user documentation**

Make `action_install` a loop around `ui_multiselect`, details/compare/similar actions, `close_selection`, `pm_install_plan_many`, one confirmation, grouped execution, and per-package verification. Refresh installed labels after success and allow another selection without discarding the original search cache.

Update `README.md` with the actual controls and data limitations, including the two AUR size limitations and the difference between official build time and AUR recipe update time. Do not claim first release for official packages or automatic recommendation-based installation.

- [ ] **Step 4: Run the complete verification gate**

```bash
cd /home/mohsen/arch-smart-update
bash -n smart-update.sh
git diff --check
PYTHONPATH=tests/install_software python3 -m unittest discover -s tests/install_software -v
python3 tests/install_software/pty_selection.py
python3 tests/install_software/e2e_install_menu.py
```

Expected: syntax/diff commands exit `0`, every unit test reports `OK`, and both PTY scripts print `PASS`. Inspect captured output to ensure there are no tracebacks, raw JSON records, unescaped terminal sequences in plain mode, real package transactions, or empty recommendations presented as reliable.

- [ ] **Step 5: Optional checkpoint when commits are authorized**

```bash
git add smart-update.sh README.md tests/install_software
git commit -m "feat: complete metadata-rich multi-package installer"
```

## Requirement Acceptance Matrix

| User requirement | Where implemented | Required proof |
|---|---|---|
| Votes | Tasks 1–2 | AUR detail shows `NumVotes`; official rows do not fabricate votes. |
| Latest update | Tasks 1–2 | Official build date and AUR recipe update are labeled distinctly. |
| First release | Tasks 1–2 | AUR `FirstSubmitted`; official explicitly unavailable. |
| Package size | Tasks 1–2 | Official download bytes; AUR explicitly unpublished. |
| Requirements | Tasks 1–2 and 4 | Runtime/build/check/optional lists plus aggregated preview. |
| Repository | Tasks 1–2 | Actual official repository or AUR. |
| Architecture | Tasks 1–2 | Official `Architecture`; AUR inert `.SRCINFO` parse or unknown. |
| Installed size | Tasks 1–2 | Official `Installed Size`; AUR unknown until built. |
| Licenses | Tasks 1–2 | Official `Licenses`; AUR `License`; missing means not declared. |
| Maintainers | Tasks 1–2 | AUR maintainer/orphan; official packager. |
| Mark multiple in a row | Task 3 | PTY presses `Space` twice without leaving results; two keys submitted. |
| Installed marker/color | Tasks 1 and 3 | Exact local pacman state, modern color, literal fallback, separate reinstall action. |
| Plugin core explanation and mark | Task 4 | Missing core auto-added once and announced; installed core satisfies it; ambiguity blocks safely. |
| Compare bin/source/build variants | Task 5 | Comparison contains all variant metadata and actual conflicts. |
| Recommendation based on last update | Task 5 | Stable maintained candidate ranking and explanation with actual date; VCS not favored blindly. |
| Similar apps when available | Task 6 | Evidence threshold, reason, at most one follow-up search, honest empty result. |

## Final Self-Review Notes

- The requested fields each have an explicit source and an explicit unavailable state; no AUR size or official first-release value is fabricated.
- Existing votes/update/installed/plugin/variant behavior is treated as a base, not duplicated as a new search engine.
- Multi-select and plugin/core marking cannot change the system until the aggregated confirmation.
- Recommendations and similar apps are deterministic, explainable, bounded, and independent of external AI services.
- All network and package-management boundaries have offline fixtures or stubs; interactive behavior is exercised through real pseudo-terminals.
