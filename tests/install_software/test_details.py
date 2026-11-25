import contextlib
import io
import json
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from _helpers import SCRIPT, load_library


FIXTURE = Path(__file__).parent / "fixtures" / "aur-srcinfo-demo"
OFFICIAL_INFO = """Repository      : extra
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
"""


class DetailsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = load_library()

    def test_official_details_are_complete_and_honest(self):
        record = self.lib["parse_pacman_si"](OFFICIAL_INFO)
        self.assertIsNone(record["make_depends"])
        self.assertIsNone(record["check_depends"])
        self.assertTrue({"make_depends", "check_depends"}.issubset(
            record["_unavailable"]
        ))
        text = self.lib["package_details"](record)
        for expected in (
            "Package: demo 1.2-1",
            "Repository: extra",
            "Architecture: x86_64",
            "Package size: 1.5 MiB",
            "Installed size: 4.0 MiB",
            "Licenses: MIT",
            "Maintainer / packager: Example Packager <packager@example.invalid>",
            "First release: Not tracked by pacman",
            "Latest update:",
            "Package build date",
            "Runtime requirements: gtk4, glib2",
            "Optional requirements: demo-cli: CLI",
            "Build requirements: Not tracked by pacman",
            "Check requirements: Not tracked by pacman",
            "Votes: Not used for official packages",
        ):
            self.assertIn(expected, text)
        self.assertEqual(
            self.lib["format_date"](record["updated"]),
            time.strftime("%Y-%m-%d", time.localtime(record["updated"])),
        )
        self.assertEqual(self.lib["format_size"](1024), "1.0 KiB")
        self.assertEqual(self.lib["format_size"](1023), "1023 B")
        self.assertEqual(self.lib["format_size"](None), "Not available")

    def test_normalized_details_preserve_homepage_popularity_parent_state_and_addons(self):
        record = self.lib["new_package"]("demo-plugin")
        record.update({
            "source": "aur", "repository": "AUR", "version": "2.0-1",
            "url": "https://plugin.invalid", "votes": 7, "popularity": 1.25,
            "user_share": 3.25, "category": "plugin", "parent": "repo-demo",
            "parent_state": "selected", "addons": ["demo-plugin-extra"],
            "updated": 1700000000, "first_submitted": 1600000000,
        })
        text = self.lib["package_details"](record)
        for expected in (
            "Homepage: https://plugin.invalid",
            "AUR popularity: 1.25",
            "pkgstats popularity: 3.25",
            "Category: plugin",
            "Requires core: repo-demo (selected)",
            "Add-ons: 1 plugin(s) for it were found, e.g. demo-plugin-extra",
        ):
            self.assertIn(expected, text)

    def test_aur_details_are_complete_and_honest(self):
        lib = load_library()
        record = lib["normalize_aur"]({
            "Name": "demo", "Version": "1-1", "NumVotes": 9,
            "FirstSubmitted": 1600000000, "LastModified": 1700000000,
            "Maintainer": None, "Depends": ["gtk4"], "MakeDepends": ["meson"],
            "CheckDepends": ["python-pytest"], "OptDepends": ["demo-cli: CLI"],
            "License": ["MIT"],
        })
        with tempfile.TemporaryDirectory() as tmp:
            previous = os.getcwd()
            try:
                os.chdir(tmp)
                record = lib["parse_srcinfo"](FIXTURE.read_text(encoding="utf-8"), record)
            finally:
                os.chdir(previous)
            self.assertFalse((Path(tmp) / "should-not-exist").exists())
        text = lib["package_details"](record)
        for expected in (
            "Votes: 9", "First submitted to AUR", "AUR recipe update",
            "Runtime requirements: gtk4", "Build requirements: meson",
            "Check requirements: python-pytest",
            "Optional requirements: demo-cli: CLI",
            "Architecture: x86_64", "Licenses: MIT", "Orphaned",
            "Package size: Not published by AUR",
            "Installed size: Unknown until built",
        ):
            self.assertIn(expected, text)


class CachedDetailsTests(unittest.TestCase):
    def setUp(self):
        self.lib = load_library()
        self.record = self.lib["normalize_aur"]({
            "Name": "demo", "Version": "1-1", "NumVotes": 9,
            "FirstSubmitted": 1600000000, "LastModified": 1700000000,
            "Maintainer": "maint", "Depends": ["gtk4"], "License": ["MIT"],
        })
        self.record = self.lib["parse_srcinfo"](
            FIXTURE.read_text(encoding="utf-8"), self.record
        )

    def test_second_details_call_uses_success_cache(self):
        fetch = Mock(return_value={"aur:demo": self.record})
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(self.lib, {"fetch_details": fetch}):
                first = self.lib["pm_details_record"]("aur", "demo", tmp)
                second = self.lib["pm_details_record"]("aur", "demo", tmp)
            self.assertEqual(first, self.record)
            self.assertEqual(second, self.record)
            self.assertEqual(first["make_depends"], [])
            self.assertEqual(first["check_depends"], [])
            self.assertEqual(second["make_depends"], [])
            self.assertEqual(second["check_depends"], [])
            self.assertEqual(fetch.call_count, 1)
            fetch.assert_called_once_with([("aur", "demo")])
            cache = Path(tmp) / "package-details"
            self.assertEqual(len(list(cache.glob("*.json"))), 1)
            cached = json.loads(next(cache.glob("*.json")).read_text(encoding="utf-8"))
            self.assertEqual(cached["source"], "aur")
            self.assertEqual(cached["name"], "demo")
            self.assertEqual(cached["architectures"], ["x86_64"])
            self.assertEqual(cached["make_depends"], [])
            self.assertEqual(cached["check_depends"], [])
            text = self.lib["package_details"](second)
            self.assertIn("Build requirements: None declared", text)
            self.assertIn("Check requirements: None declared", text)

    def test_timeout_becomes_unknown_and_failure_cache_expires(self):
        fetch = Mock(side_effect=TimeoutError("metadata timed out"))
        with tempfile.TemporaryDirectory() as tmp:
            stderr = io.StringIO()
            with patch.dict(self.lib, {"fetch_details": fetch}):
                with contextlib.redirect_stderr(stderr):
                    first = self.lib["pm_details_record"]("aur", "demo", tmp)
                second = self.lib["pm_details_record"]("aur", "demo", tmp)
                self.assertEqual(fetch.call_count, 1)
                self.assertEqual(first, second)
                self.assertIsNone(first["updated"])
                self.assertIsNone(first["architectures"])
                self.assertIn("Not available", self.lib["package_details"](first))
                self.assertIn("15 seconds", stderr.getvalue())
                self.assertIn("Warning:", stderr.getvalue())

                failures = Path(tmp) / "package-details" / "failures"
                failure_files = list(failures.glob("*.json"))
                self.assertEqual(len(failure_files), 1)
                failure = json.loads(failure_files[0].read_text(encoding="utf-8"))
                failure["failed_at"] = time.time() - 301
                failure_files[0].write_text(json.dumps(failure), encoding="utf-8")
                with contextlib.redirect_stderr(stderr):
                    self.lib["pm_details_record"]("aur", "demo", tmp)
                self.assertEqual(fetch.call_count, 2)

    def assert_failed_details_are_honest(self, source):
        fetch = Mock(side_effect=TimeoutError("metadata timed out"))
        with tempfile.TemporaryDirectory() as tmp:
            with patch.dict(self.lib, {"fetch_details": fetch}):
                with contextlib.redirect_stderr(io.StringIO()):
                    first = self.lib["pm_details_record"](source, "demo", tmp)
                    second = self.lib["pm_details_record"](source, "demo", tmp)
            text = self.lib["package_details"](first)
            self.assertEqual(text, self.lib["package_details"](second))
            self.assertEqual(fetch.call_count, 1)
            expected_unavailable = {
                "version", "package_base", "repository", "architectures", "download_size",
                "installed_size", "licenses", "maintainer", "packager", "updated",
                "first_submitted", "depends", "make_depends", "check_depends",
                "optional_depends", "votes", "provides", "conflicts", "parent",
                "groups", "keywords", "category",
            }
            self.assertEqual(set(first["_unavailable"]), expected_unavailable)
            for record in (first, second):
                for field in expected_unavailable:
                    self.assertIsNone(record[field], "%s must be None" % field)
            failures = Path(tmp) / "package-details" / "failures"
            failure_files = list(failures.glob("*.json"))
            self.assertEqual(len(failure_files), 1)
            raw = json.loads(failure_files[0].read_text(encoding="utf-8"))["record"]
            self.assertEqual(set(raw["_unavailable"]), expected_unavailable)
            for field in expected_unavailable:
                self.assertIsNone(raw[field], "raw %s must be JSON null" % field)
        for expected in (
            "Package: demo Not available",
            "Repository: Not available",
            "Maintainer / packager: Not available",
            "Licenses: Not available",
            "Runtime requirements: Not available",
            "Optional requirements: Not available",
        ):
            self.assertIn(expected, text)
        if source == "repo":
            self.assertIn("Build requirements: Not tracked by pacman", text)
            self.assertIn("Check requirements: Not tracked by pacman", text)
        else:
            self.assertIn("Build requirements: Not available", text)
            self.assertIn("Check requirements: Not available", text)
        self.assertNotIn("Not declared", text)
        self.assertNotIn("None declared", text)
        return text

    def test_failed_aur_details_do_not_fabricate_known_empty_metadata(self):
        text = self.assert_failed_details_are_honest("aur")
        self.assertIn("Votes: Not available", text)
        self.assertNotIn("Orphaned", text)
        self.assertNotIn("Not used for official packages", text)

    def test_failed_official_details_do_not_fabricate_known_empty_metadata(self):
        text = self.assert_failed_details_are_honest("repo")
        self.assertIn("Votes: Not used for official packages", text)

    def test_srcinfo_timeout_preserves_aur_fields_and_uses_failure_cache(self):
        info = Mock(return_value=[{
            "Name": "demo", "Version": "1-1", "NumVotes": 9,
            "Maintainer": "maint", "Depends": ["gtk4"], "License": ["MIT"],
        }])
        srcinfo = Mock(side_effect=TimeoutError("metadata timed out"))
        with tempfile.TemporaryDirectory() as tmp:
            replacements = {"fetch_aur_info": info, "fetch_srcinfo": srcinfo}
            with patch.dict(self.lib, replacements):
                with contextlib.redirect_stderr(io.StringIO()):
                    first = self.lib["pm_details_record"]("aur", "demo", tmp)
                second = self.lib["pm_details_record"]("aur", "demo", tmp)
            self.assertEqual(first, second)
            self.assertEqual(first["version"], "1-1")
            self.assertEqual(first["votes"], 9)
            self.assertIsNone(first["architectures"])
            self.assertIsNone(second["architectures"])
            text = self.lib["package_details"](first)
            for expected in (
                "Repository: AUR", "Votes: 9", "Maintainer / packager: maint",
                "Licenses: MIT", "Runtime requirements: gtk4",
                "Architecture: Not available",
            ):
                self.assertIn(expected, text)
            self.assertEqual(info.call_count, 1)
            self.assertEqual(srcinfo.call_count, 1)
            cache = Path(tmp) / "package-details"
            self.assertEqual(list(cache.glob("*.json")), [])
            failure_files = list((cache / "failures").glob("*.json"))
            self.assertEqual(len(failure_files), 1)
            raw = json.loads(failure_files[0].read_text(encoding="utf-8"))["record"]
            self.assertIsNone(raw["architectures"])
            self.assertEqual(raw["version"], "1-1")
            self.assertEqual(raw["votes"], 9)
            self.assertEqual(raw["depends"], ["gtk4"])
            self.assertEqual(raw["licenses"], ["MIT"])

    def test_loader_batches_official_and_aur_info_at_sixty(self):
        requests = (
            [("repo", "repo-%d" % i) for i in range(61)]
            + [("aur", "aur-%d" % i) for i in range(61)]
        )

        def repo_info(names):
            return "\n\n".join(
                "Repository      : extra\nName            : %s\nVersion         : 1-1\n" % name
                for name in names
            )

        def aur_info(names):
            return [{"Name": name, "Version": "1-1"} for name in names]

        repo_fetch = Mock(side_effect=repo_info)
        aur_fetch = Mock(side_effect=aur_info)
        srcinfo_fetch = Mock(return_value="pkgbase = demo\narch = x86_64\n")
        replacements = {
            "run_pacman_si": repo_fetch,
            "fetch_aur_info": aur_fetch,
            "fetch_srcinfo": srcinfo_fetch,
        }
        with patch.dict(self.lib, replacements):
            records = self.lib["fetch_details"](requests)
        self.assertEqual(len(records), 122)
        self.assertEqual(repo_fetch.call_count, 2)
        self.assertEqual(aur_fetch.call_count, 2)
        self.assertEqual(srcinfo_fetch.call_count, 61)
        for call in list(repo_fetch.call_args_list) + list(aur_fetch.call_args_list):
            self.assertLessEqual(len(call.args[0]), 60)
        self.assertEqual(records["repo:repo-60"]["source"], "repo")
        self.assertEqual(records["aur:aur-60"]["architectures"], ["x86_64"])

    def test_selection_records_batches_only_cache_misses_and_reuses_new_caches(self):
        requests = [("repo", "cached"), ("repo", "failed"), ("repo", "one"), ("repo", "two")]
        with tempfile.TemporaryDirectory() as tmp:
            cached = self.lib["new_package"]("cached")
            cached.update(source="repo", repository="extra", version="1-1")
            self.lib["atomic_json"](
                self.lib["package_cache_path"](tmp, "repo:cached"), cached
            )
            failed = self.lib["unknown_package"]("repo", "failed")
            self.lib["atomic_json"](
                self.lib["package_cache_path"](tmp, "repo:failed", failure=True),
                {"failed_at": time.time(), "reason": "offline", "record": failed},
            )
            fetched = {}
            for name in ("one", "two"):
                record = self.lib["new_package"](name)
                record.update(source="repo", repository="extra", version="1-1")
                fetched["repo:" + name] = record
            fetch = Mock(return_value=fetched)
            with patch.dict(self.lib, {"fetch_details": fetch}):
                records = self.lib["selection_records"](requests, tmp, "", set())
                again = self.lib["selection_records"](requests, tmp, "", set())
            self.assertEqual(records, again)
            fetch.assert_called_once_with([("repo", "one"), ("repo", "two")])
            self.assertEqual(records["repo:cached"]["version"], "1-1")
            self.assertIn("repository", records["repo:failed"]["_unavailable"])
            self.assertEqual(records["repo:one"]["name"], "one")
            self.assertEqual(records["repo:two"]["name"], "two")
            successes = list((Path(tmp) / "package-details").glob("*.json"))
            self.assertEqual(len(successes), 3)

    def test_shell_selection_records_load_batches_production_cache_misses(self):
        script = SCRIPT.read_text(encoding="utf-8")
        trailer = 'main "$@"\n'
        self.assertTrue(script.endswith(trailer))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = root / "runtime"
            runtime.mkdir()
            bin_dir = root / "bin"
            bin_dir.mkdir()
            pacman = bin_dir / "pacman"
            pacman.write_text(r'''#!/bin/bash
if [[ $1 == -Qq ]]; then exit 0; fi
if [[ $1 == -Si ]]; then
    printf 'SI\n' >>"$TEST_CALLS"
    printf '%s\n\n' \
        'Repository      : extra' 'Name            : one' 'Version         : 1.0-1'
    printf '%s\n' \
        'Repository      : extra' 'Name            : two' 'Version         : 2.0-1'
    exit 0
fi
exit 1
''', encoding="utf-8")
            pacman.chmod(0o755)
            scenario = root / "scenario.sh"
            scenario.write_text(
                script[:-len(trailer)] + r'''
TMP=$1
R_KEYS=(repo:one repo:two)
pm_selection_records_load
printf 'rc=%s\n' "$?"
''',
                encoding="utf-8",
            )
            env = dict(os.environ)
            env.update(PATH=str(bin_dir) + os.pathsep + env.get("PATH", ""),
                       TEST_CALLS=str(root / "calls"))
            result = subprocess.run(
                ["bash", str(scenario), str(runtime)], text=True,
                capture_output=True, env=env, timeout=15, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            self.assertEqual(result.stderr, "")
            self.assertIn("rc=0", result.stdout)
            calls = (root / "calls").read_text() if (root / "calls").exists() else ""
            self.assertEqual(calls.splitlines().count("SI"), 1, calls)
            records = json.loads((runtime / "selection-records.json").read_text())
            self.assertEqual(sorted(records), ["repo:one", "repo:two"])

    def test_shell_details_and_one_argument_about_work_offline(self):
        script = SCRIPT.read_text(encoding="utf-8")
        library = re.search(
            r"read -r -d '' PM_PACKAGE_LIB_PY <<'PYEOF'\n.*?\nPYEOF",
            script,
            re.S,
        )
        details = re.search(r"^pm_details_record\(\) \{.*?^\}", script, re.S | re.M)
        about = re.search(r"^pm_about\(\) \{.*?^\}", script, re.S | re.M)
        self.assertIsNotNone(details, "pm_details_record shell function is missing")
        self.assertIsNotNone(about, "pm_about shell function is missing")
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            pacman = bin_dir / "pacman"
            pacman.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = -Si ]; then\n"
                "cat <<'PACMAN_EOF'\n" + OFFICIAL_INFO + "PACMAN_EOF\n"
                "elif [ \"$1\" = -Qq ]; then\n"
                "printf '%s\\n' demo\n"
                "fi\n",
                encoding="utf-8",
            )
            pacman.chmod(0o755)
            cache_tmp = Path(tmp) / "runtime"
            cache_tmp.mkdir()
            summary = self.lib["new_package"]("demo")
            summary.update({
                "source": "repo", "repository": "extra", "version": "1.2-1",
                "url": "https://summary.invalid", "user_share": 9.5,
                "category": "plugin", "parent": "core", "addons": ["demo-addon"],
                "installed_version": "1.1-1",
            })
            (cache_tmp / "search_meta.jsonl").write_text(
                json.dumps(summary) + "\n", encoding="utf-8"
            )
            command = "\n".join((
                library.group(0), details.group(0), about.group(0),
                "TMP=\"$1\"",
                "R_KEYS=(repo:demo)",
                "pm_about demo",
            ))
            env = dict(os.environ)
            env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
            result = subprocess.run(
                ["bash", "-c", command, "bash", str(cache_tmp)],
                capture_output=True,
                text=True,
                env=env,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertIn("Package: demo 1.2-1", result.stdout)
            self.assertIn("Package build date", result.stdout)
            self.assertIn("First release: Not tracked by pacman", result.stdout)
            self.assertIn("Homepage: https://summary.invalid", result.stdout)
            self.assertIn("pkgstats popularity: 9.5", result.stdout)
            self.assertIn("Category: plugin", result.stdout)
            self.assertIn("Installed: yes; version 1.1-1", result.stdout)
            self.assertIn("Requires core: core (missing)", result.stdout)
            self.assertIn("Add-ons: 1 plugin(s) for it were found, e.g. demo-addon", result.stdout)
            self.assertEqual(
                len(list((cache_tmp / "package-details").glob("*.json"))), 1
            )


if __name__ == "__main__":
    unittest.main()
