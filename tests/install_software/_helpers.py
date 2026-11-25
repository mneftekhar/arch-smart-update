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


def load_enrichment():
    text = SCRIPT.read_text(encoding="utf-8")
    library = re.search(
        r"read -r -d '' PM_PACKAGE_LIB_PY <<'PYEOF'\n(.*?)\nPYEOF",
        text,
        re.S,
    )
    enrichment = re.search(
        r"read -r -d '' PM_ENRICH_PY <<'PYEOF'\n(.*?)\nPYEOF",
        text,
        re.S,
    )
    assert library and enrichment, "embedded package enrichment is missing"
    namespace = {"__name__": "pm_enrich"}
    exec(library.group(1), namespace)
    exec(enrichment.group(1), namespace)
    return namespace
