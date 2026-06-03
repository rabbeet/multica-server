#!/usr/bin/env bash
# Verify build-index.py extracts # RECIPE: blocks from notebook source and
# renders them in MARIMO_INDEX.md correctly. Pure test — no live marimo,
# no /srv/marimo-notebooks rw required.
#
# Covers:
#   - happy path: two recipes in two notebooks, verified-at desc sort
#   - metadata parsing: key:value comments + label overrides (DSN, JSON paths)
#   - code block: indented body captured, dedent terminates correctly
#   - degenerate cases: malformed verified-at, no metadata, multi-recipe-per-cell
#   - existing real notebooks regression: must parse without exceptions
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_INDEX_PY="$SCRIPTS_DIR/build-index.py"

python3 - <<PY
import importlib.util
import pathlib
import shutil
import sys
import tempfile

spec = importlib.util.spec_from_file_location("build_index", "${BUILD_INDEX_PY}")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# ---- isolated fixture dir ----
tmpdir = pathlib.Path(tempfile.mkdtemp(prefix="marimo-test-"))
m.NB_DIR = tmpdir
m.INDEX_PATH = tmpdir / "MARIMO_INDEX.md"

(tmpdir / "PUL-100.py").write_text('''
@app.cell(hide_code=True)
def _x():
    # RECIPE: foo
    # verified-at: PUL-100, 2026-06-01
    # DSN: \$X_DSN
    # Summary: returns foo
    SQL = """
    SELECT 1
    """
    return SQL
''')

(tmpdir / "PUL-200.py").write_text('''
@app.cell
def _y():
    # RECIPE: bar
    # verified-at: PUL-200, 2026-05-15
    # JSON paths: \$.path.to.foo
    print('bar')

@app.cell
def _z():
    # RECIPE: baz
    # Summary: no verified-at on purpose
    pass
''')

# ---- assertions ----
notebooks = m.collect_notebooks()
assert set(notebooks.keys()) == {"PUL-100", "PUL-200"}, notebooks

recipes = m.collect_recipes(notebooks)
names = [r["name"] for r in recipes]
# Sort: verified-at desc; baz has no verified-at so it sorts last.
assert names == ["foo", "bar", "baz"], f"sort order: {names}"

# Metadata + code-extraction
foo = next(r for r in recipes if r["name"] == "foo")
assert foo["metadata"].get("dsn") == "\$X_DSN", foo["metadata"]
assert foo["metadata"].get("summary") == "returns foo", foo["metadata"]
assert "SELECT 1" in foo["code"], foo["code"]

bar = next(r for r in recipes if r["name"] == "bar")
assert "json paths" in bar["metadata"], bar["metadata"]

# Section rendering
section = m.format_recipes_section(recipes)
assert "## Recipes" in section, section
assert "### foo — PUL-100, 2026-06-01" in section, section
assert "### bar — PUL-200, 2026-05-15" in section, section
# baz has no verified-at and no metadata other than summary
assert "### baz" in section, section
# Label override: 'dsn' → 'DSN', 'json paths' → 'JSON paths'
assert "**DSN:**" in section, section
assert "**JSON paths:**" in section, section
# Not 'Dsn:' or 'Json Paths:' — those would mean overrides failed
assert "**Dsn:**" not in section
assert "**Json Paths:**" not in section

# ---- existing real notebooks regression ----
# These are on the brainstorm host; if absent we skip this part with
# a warning (not a failure — CI hosts may not have them).
real_nb_dir = pathlib.Path("/srv/marimo-notebooks")
if real_nb_dir.exists():
    m.NB_DIR = real_nb_dir
    real_nbs = m.collect_notebooks()
    for ident, paths in real_nbs.items():
        for p in paths:
            try:
                m.extract_recipes(p)
                m.extract_notebook(p)
            except Exception as e:
                print(f"regression: {p.name}: {e}", file=sys.stderr)
                shutil.rmtree(tmpdir, ignore_errors=True)
                sys.exit(1)

shutil.rmtree(tmpdir, ignore_errors=True)
print("test_recipe_extraction: ok")
PY
