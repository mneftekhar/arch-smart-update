import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from _helpers import SCRIPT, load_enrichment


OFFICIAL_INFO = """Repository      : extra
Name            : repo-demo
Version         : 1.0-1
Description     : Demo application
Architecture    : x86_64
Licenses        : MIT
URL             : https://summary.invalid
Depends On      : gtk4  glib2
Optional Deps   : demo-cli: CLI
Provides        : demo-api=1
Conflicts With  : other-demo>=2
Groups          : demo-tools
Download Size   : 1.00 KiB
Installed Size  : 2.00 KiB
Packager        : Test Packager <test@example.invalid>
Build Date      : Sun Jan 7 03:04:05 2024
"""


class FakeResponse:
    def __init__(self, payload):
        self.payload = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return self.payload


class SearchSummaryIntegrationTests(unittest.TestCase):
    def test_real_enrichment_jsonl_flows_into_selection_with_empty_detail_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo_file = root / "search_repo"
            legacy_file = root / "search_meta"
            jsonl_file = root / "search_meta.jsonl"
            repo_file.write_text(
                "repo-demo|extra|1.0-1|1|Demo application\n", encoding="utf-8"
            )
            aur_hits = [
                {
                    "Name": "repo-demo-plugin", "PackageBase": "plugin-base",
                    "Version": "2.0-1", "Description": "Plugin for repo-demo",
                    "NumVotes": 7, "Popularity": 1.25, "LastModified": 1700000000,
                    "FirstSubmitted": 1600000000, "OutOfDate": None,
                    "URL": "https://plugin.invalid", "Maintainer": "maint",
                },
                {
                    "Name": "aur-unknown", "PackageBase": "aur-unknown",
                    "Version": "1-1", "Description": "Unknown metadata",
                    "NumVotes": None, "Popularity": None, "LastModified": 0,
                    "FirstSubmitted": 0, "OutOfDate": None,
                    "URL": None, "Maintainer": None,
                },
            ]
            plugin_info = {
                "Name": "repo-demo-plugin", "PackageBase": "plugin-base",
                "Version": "2.0-1", "Description": "Plugin for repo-demo",
                "NumVotes": 7, "Popularity": 1.25, "LastModified": 1700000000,
                "FirstSubmitted": 1600000000, "OutOfDate": None,
                "URL": "https://plugin.invalid", "Maintainer": "maint",
                "Depends": ["repo-demo>=1"], "Provides": ["demo-plugin-api=2"],
                "Conflicts": ["other-plugin>=1"], "Groups": ["repo-demo-addons"],
                "Keywords": ["photography", "editor"], "License": ["GPL"],
            }

            def pacman_run(command, **kwargs):
                if command[:2] == ["pacman", "-Si"]:
                    stdout = OFFICIAL_INFO
                elif command[:2] == ["pacman", "-Q"]:
                    stdout = "repo-demo 1.0-1\n"
                elif command[:2] == ["pacman", "-Qq"]:
                    stdout = "repo-demo\n"
                elif command[:2] == ["pacman", "-Slq"]:
                    stdout = "repo-demo\n"
                else:
                    raise AssertionError("unexpected pacman command: %r" % command)
                return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")

            def http_get(request, timeout=15):
                url = request.full_url
                if "/rpc/v5/search/" in url:
                    return FakeResponse({"results": aur_hits})
                if "/rpc/v5/info" in url:
                    return FakeResponse({"results": [plugin_info]})
                if "pkgstats.archlinux.de/api/packages?" in url:
                    return FakeResponse({"packagePopularities": [
                        {"name": "repo-demo", "popularity": 12.5},
                        {"name": "repo-demo-plugin", "popularity": 3.25},
                    ]})
                if "pkgstats.archlinux.de/api/packages/aur-unknown" in url:
                    return FakeResponse({})
                raise AssertionError("unexpected URL: " + url)

            argv = ["pm_enrich", "demo", str(repo_file), str(legacy_file), str(jsonl_file)]
            search_output = io.StringIO()
            with patch.object(sys, "argv", argv):
                with patch.object(subprocess, "run", side_effect=pacman_run):
                    with patch("urllib.request.urlopen", side_effect=http_get):
                        with contextlib.redirect_stdout(search_output):
                            enriched = load_enrichment()

            self.assertTrue(jsonl_file.exists(), "real PM_ENRICH did not emit search_meta.jsonl")
            headings = [line for line in search_output.getvalue().splitlines() if line.startswith("@plug-")]
            self.assertEqual(len(headings), 1)
            self.assertNotIn("installed", headings[0])
            summaries = {
                record["source"] + ":" + record["name"]: record
                for record in (json.loads(line) for line in jsonl_file.read_text().splitlines())
            }
            self.assertEqual(set(summaries), {
                "repo:repo-demo", "aur:repo-demo-plugin", "aur:aur-unknown",
            })
            for record in summaries.values():
                self.assertTrue(set(enriched["PACKAGE_FIELDS"]).issubset(record))
            plugin = summaries["aur:repo-demo-plugin"]
            self.assertEqual(plugin["package_base"], "plugin-base")
            self.assertEqual(plugin["category"], "plugin")
            self.assertEqual(plugin["parent"], "repo-demo")
            self.assertEqual(plugin["user_share"], 3.25)
            self.assertEqual(plugin["votes"], 7)
            self.assertEqual(plugin["popularity"], 1.25)
            self.assertEqual(plugin["depends"], ["repo-demo>=1"])
            self.assertEqual(plugin["provides"], ["demo-plugin-api=2"])
            self.assertEqual(plugin["conflicts"], ["other-plugin>=1"])
            self.assertEqual(plugin["groups"], ["repo-demo-addons"])
            self.assertEqual(plugin["keywords"], ["photography", "editor"])
            self.assertEqual(summaries["repo:repo-demo"]["installed_version"], "1.0-1")
            self.assertEqual(summaries["repo:repo-demo"]["addons"], ["repo-demo-plugin"])
            unknown = summaries["aur:aur-unknown"]
            self.assertIsNone(unknown["updated"])
            self.assertIsNone(unknown["first_submitted"])
            self.assertIsNone(unknown["votes"])
            self.assertIsNone(unknown["popularity"])

            detail = enriched["parse_pacman_si"](OFFICIAL_INFO)
            detail["version"] = "9.0-1"
            detail["url"] = "https://detail.invalid"
            failures = {
                "aur:repo-demo-plugin": enriched["unknown_package"]("aur", "repo-demo-plugin"),
                "aur:aur-unknown": enriched["unknown_package"]("aur", "aur-unknown"),
            }
            for record in failures.values():
                record["_detail_error"] = "offline fixture"
            fetch = Mock(return_value={"repo:repo-demo": detail, **failures})
            requests = [("repo", "repo-demo"), ("aur", "repo-demo-plugin"), ("aur", "aur-unknown")]
            self.assertFalse((root / "package-details").exists())
            with patch.dict(enriched, {"fetch_details": fetch}):
                with contextlib.redirect_stderr(io.StringIO()):
                    records = enriched["selection_records"](
                        requests, tmp, str(legacy_file), {"repo-demo"}
                    )
            fetch.assert_called_once_with(requests)
            merged = records["repo:repo-demo"]
            self.assertEqual(merged["version"], "9.0-1")
            self.assertEqual(merged["url"], "https://detail.invalid")
            self.assertEqual(merged["user_share"], 12.5)
            self.assertEqual(merged["installed_version"], "1.0-1")
            self.assertEqual(merged["addons"], ["repo-demo-plugin"])
            retained = records["aur:repo-demo-plugin"]
            self.assertEqual(retained["user_share"], 3.25)
            self.assertEqual(retained["package_base"], "plugin-base")
            self.assertEqual(retained["votes"], 7)
            self.assertEqual(retained["popularity"], 1.25)
            self.assertEqual(retained["category"], "plugin")
            self.assertEqual(retained["parent"], "repo-demo")
            self.assertEqual(retained["depends"], ["repo-demo>=1"])
            self.assertEqual(records["aur:aur-unknown"]["updated"], None)


class ReservedSearchTests(unittest.TestCase):
    def run_reserved_search(self, query):
        source = SCRIPT.read_text(encoding="utf-8")
        trailer = 'main "$@"\n'
        self.assertTrue(source.endswith(trailer))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / "runtime"
            runtime.mkdir()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            pacman = bin_dir / "pacman"
            pacman.write_text(r'''#!/bin/bash
if [[ $1 == -Ss ]]; then
    printf '%s\n' 'extra/demo 1.0-1' '    Demo package'
    exit 0
fi
exit 1
''', encoding="utf-8")
            pacman.chmod(0o755)
            curl = bin_dir / "curl"
            curl.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
            curl.chmod(0o755)
            python_wrapper = bin_dir / "python3"
            python_wrapper.write_text(r'''#!/bin/bash
prelude=$(cat <<'PY'
import types
import subprocess
import urllib.request

class OfflineResponse:
    def __enter__(self): return self
    def __exit__(self, *args): return False
    def read(self): return b'{"results": []}'

def offline_run(command, **kwargs):
    if command[:2] == ["pacman", "-Si"]:
        output = "Repository      : extra\nName            : demo\nVersion         : 1.0-1\nDescription     : Demo package\n"
    elif command[:2] == ["pacman", "-Q"]:
        output = ""
    elif command[:2] == ["pacman", "-Slq"]:
        output = "demo\n"
    else:
        raise AssertionError("unexpected subprocess: %r" % command)
    return types.SimpleNamespace(returncode=0, stdout=output, stderr="")

subprocess.run = offline_run
urllib.request.urlopen = lambda request, timeout=15: OfflineResponse()
PY
)
exec ''' + sys.executable + r''' -I -c "$prelude
$3" "${@:4}"
''', encoding="utf-8")
            python_wrapper.chmod(0o755)
            scenario = root / "scenario.sh"
            scenario.write_text(source[:-len(trailer)] + r'''
TMP=$1
AUR_HELPER=none
find_aur_helper() { printf 'none\n'; }
pm_search "$2"
printf 'RC=%s\n' "$?"
printf 'KEY <%s>\n' "${R_KEYS[@]}"
printf 'LABEL <%s>\n' "${R_LABELS[@]}"
''', encoding="utf-8")
            env = dict(os.environ)
            env.update(PATH=str(bin_dir) + os.pathsep + env.get("PATH", ""),
                       LC_ALL="C.UTF-8")
            result = subprocess.run(
                ["bash", str(scenario), str(runtime), query], text=True,
                capture_output=True, env=env, timeout=15, check=False,
            )
            errors = runtime / "search_err"
            return result, errors.read_text() if errors.exists() else ""

    def test_reserved_queries_never_enter_details_cli(self):
        for query in ("--details", "--selection-records"):
            with self.subTest(query=query):
                result, search_errors = self.run_reserved_search(query)
                output = result.stdout + result.stderr + search_errors
                self.assertEqual(result.returncode, 0, output)
                self.assertEqual(result.stderr, "", output)
                self.assertIn("RC=0", result.stdout)
                self.assertIn("KEY <@weak>", result.stdout, output)
                self.assertIn("KEY <repo:demo>", result.stdout, output)
                self.assertNotIn("Traceback", output)
                self.assertNotIn("ValueError", output)
                self.assertNotIn("{", result.stdout)


if __name__ == "__main__":
    unittest.main()
