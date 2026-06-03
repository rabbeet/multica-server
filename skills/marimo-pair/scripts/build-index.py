#!/usr/bin/env python3
"""Build /srv/marimo-notebooks/MARIMO_INDEX.md.

Source:
  - `multica issue list --project <marimo>` (titles, descriptions, statuses)
  - `/srv/marimo-notebooks/PUL-*.py` (DSNs, tables, ClickEvt namespaces,
    event names, JSON paths — extracted by regex)

A marimo-task agent grep's the produced file by ticket keywords *before*
descending into /srv/agent-context/pulse/{pg,external}/. If a past ticket
already routed to the same data, the notebook path is right there.

Idempotent. Re-runnable. Atomic write (temp + rename). Falls back to
notebooks-only mode with a warning header if `multica issue list` is
unreachable.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

NB_DIR = Path("/srv/marimo-notebooks")
INDEX_PATH = NB_DIR / "MARIMO_INDEX.md"
MARIMO_PROJECT_ID = "458aa700-b3cd-402f-a50b-77c0d207eef2"

DSN_RE = re.compile(r'os\.environ\[\s*["\']([A-Z][A-Z0-9_]*_DSN)["\']\s*\]')
TABLE_RE = re.compile(
    r'(?<!\.)\b(?:FROM|JOIN)\s+'
    r'([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)'
    r'\b(?!\s+import)',
    re.IGNORECASE,
)
JSON_PATH_RE = re.compile(r"(?:e\.|details)((?:->'[^']+')+(?:->>'[^']+')?)")
NAMESPACE_RE = re.compile(r"namespace\s*=\s*['\"]([^'\"]+)['\"]", re.IGNORECASE)
EVENT_RE = re.compile(r"\bevent\s*=\s*['\"]([a-z_][a-z0-9_]*)['\"]")

TABLE_NOISE = {
    "psycopg.rows", "urllib.parse", "urllib", "psycopg", "psycopg2", "public",
    "jsonb_array_elements", "jsonb_array_elements_text",
    "jsonb_each", "jsonb_each_text",
    "json_array_elements", "unnest", "generate_series",
    "system.tables", "pg_tables", "information_schema",
}

# Recipe markers in notebook source. A recipe is a `# RECIPE: <name>` line
# inside a cell, followed by contiguous `key: value` comment-metadata, then
# the code block that backs it. See `extract_recipes` for the parsing rules
# and the `## Recipes` section in MARIMO_INDEX.md for the rendered output.
RECIPE_RE = re.compile(r"^(?P<indent>[ \t]*)#\s*RECIPE:\s*(?P<name>\S+)\s*$")
RECIPE_META_RE = re.compile(
    r"^(?P<indent>[ \t]*)#\s*(?P<key>[A-Za-z][A-Za-z0-9 _-]*)"
    r":\s*(?P<value>.*?)\s*$"
)
# verified-at format: "PUL-N, YYYY-MM-DD" (date used for sort key, PUL-N for
# back-link). Anything else is best-effort displayed verbatim.
VERIFIED_AT_RE = re.compile(
    r"(?P<pul>PUL-\d+)\s*,\s*(?P<date>\d{4}-\d{2}-\d{2})"
)


def extract_recipes(path: Path) -> list[dict]:
    """Scan a notebook for `# RECIPE: <name>` blocks.

    Recipe shape inside a notebook cell::

        @app.cell(hide_code=True)
        def _name(...):
            # RECIPE: fds-unavail-by-supplier
            # verified-at: PUL-268, 2026-06-02
            # DSN: $FDS_DB_DSN
            # Tables: trips_YYYYMMDD_HHMM
            # Summary: ...one-liner...

            <code, possibly empty>

    Parsing rules:

    - The recipe name is the token after `RECIPE:` on the marker line.
    - Metadata is a contiguous run of comment lines (same indent as the
      marker) immediately after the marker line. A comment that does NOT
      match ``key: value`` ends the metadata run and is silently skipped.
    - Code starts at the first non-comment, non-blank line after metadata.
      It runs until the next non-blank line whose indent is strictly less
      than the marker's indent (dedent out of the cell function), or EOF.
    - One recipe per marker. Multiple recipes in the same cell are allowed.

    Returns a list of dicts: ``{name, metadata, code, source}``. Never
    raises — a malformed recipe (e.g. unparseable verified-at) just lands
    with whatever metadata could be salvaged.
    """
    try:
        src = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    lines = src.splitlines()
    recipes: list[dict] = []
    i = 0
    while i < len(lines):
        m = RECIPE_RE.match(lines[i])
        if not m:
            i += 1
            continue

        marker_indent = m.group("indent")
        name = m.group("name")

        # Walk metadata: contiguous comment lines at marker indent.
        metadata: dict[str, str] = {}
        j = i + 1
        while j < len(lines):
            line = lines[j]
            if not line.strip():
                # Blank line terminates metadata block.
                break
            stripped = line.lstrip()
            if not stripped.startswith("#"):
                break
            # Comment lines must start at the marker indent or deeper.
            line_indent_len = len(line) - len(stripped)
            if line_indent_len < len(marker_indent):
                break
            meta_match = RECIPE_META_RE.match(line)
            if meta_match:
                metadata[meta_match.group("key").strip().lower()] = (
                    meta_match.group("value")
                )
            # Non-matching comment is silently skipped (might be prose).
            j += 1

        # Walk code: from first non-blank line that is at >= marker indent,
        # until dedent below marker indent or EOF.
        code_lines: list[str] = []
        k = j
        # Skip leading blank lines between metadata and code.
        while k < len(lines) and not lines[k].strip():
            k += 1
        while k < len(lines):
            line = lines[k]
            if not line.strip():
                code_lines.append(line)
                k += 1
                continue
            line_indent_len = len(line) - len(line.lstrip())
            if line_indent_len < len(marker_indent):
                break
            code_lines.append(line)
            k += 1

        # Drop trailing blank lines from code.
        while code_lines and not code_lines[-1].strip():
            code_lines.pop()

        try:
            src_label = str(path.relative_to(NB_DIR))
        except ValueError:
            src_label = path.name

        recipes.append({
            "name": name,
            "metadata": metadata,
            "code": "\n".join(code_lines),
            "source": src_label,
        })
        i = max(k, i + 1)

    return recipes


def collect_recipes(notebooks: dict[str, list[Path]]) -> list[dict]:
    """Aggregate recipes across all notebooks, sorted by verified-at desc.

    Recipes without a parseable verified-at sort last (treated as 0001-01-01).
    Per-notebook exceptions are caught and logged to stderr; one bad notebook
    never breaks the whole index build.
    """
    all_recipes: list[dict] = []
    for paths in notebooks.values():
        for path in paths:
            try:
                all_recipes.extend(extract_recipes(path))
            except Exception as e:  # noqa: BLE001
                print(
                    f"build-index: recipe extraction failed for "
                    f"{path.name}: {e}",
                    file=sys.stderr,
                )

    def _sort_key(r: dict) -> tuple[str, str]:
        verified = r.get("metadata", {}).get("verified-at", "")
        m = VERIFIED_AT_RE.search(verified)
        date = m.group("date") if m else ""
        return (date or "0001-01-01", r.get("name", ""))

    all_recipes.sort(key=_sort_key, reverse=True)
    return all_recipes


# Display labels for metadata keys: regular Title-case loses common
# domain capitalization (DSN, SQL, JSON, FDS, PG, CH). Map overrides win
# over the default `key.replace('-', ' ').title()`.
_META_LABEL_OVERRIDES = {
    "dsn": "DSN",
    "dsns": "DSNs",
    "json-paths": "JSON paths",
    "json paths": "JSON paths",
    "pg": "PG",
    "ch": "CH",
    "fds": "FDS",
    "sql": "SQL",
    "url": "URL",
    "id": "ID",
}


def _meta_label(key: str) -> str:
    k = key.strip().lower()
    if k in _META_LABEL_OVERRIDES:
        return _META_LABEL_OVERRIDES[k]
    return key.replace("-", " ").title()


def format_recipes_section(recipes: list[dict]) -> str:
    """Render the `## Recipes` section of MARIMO_INDEX.md."""
    if not recipes:
        return ""

    out = [
        "## Recipes",
        "",
        "Готовые куски, помеченные `# RECIPE: <name>` в notebook'ах. "
        "Сортировка — `verified-at` desc; перепроверяй дату, если рецепт "
        "касается партиций или схем, которые могли поменяться.",
        "",
    ]
    for r in recipes:
        name = r["name"]
        src = r["source"]
        meta = r.get("metadata", {})
        verified = meta.get("verified-at", "")
        m = VERIFIED_AT_RE.search(verified)
        header = f"### {name}"
        if m:
            header += f" — {m.group('pul')}, {m.group('date')}"
        elif verified:
            header += f" — {verified}"
        out.append(header)
        out.append(f"- **Source:** [`{src}`]({src})")
        ordered_keys = ["summary", "dsn", "tables", "namespace", "events",
                        "json paths", "json-paths"]
        seen_keys: set[str] = set()
        for key in ordered_keys:
            if key in meta:
                out.append(f"- **{_meta_label(key)}:** {meta[key]}")
                seen_keys.add(key)
        for key, value in meta.items():
            if key in seen_keys or key == "verified-at":
                continue
            out.append(f"- **{_meta_label(key)}:** {value}")
        if r.get("code", "").strip():
            out.append("")
            out.append("```python")
            out.append(r["code"])
            out.append("```")
        out.append("")
    return "\n".join(out).rstrip() + "\n"


def extract_notebook(path: Path) -> dict:
    src = path.read_text()
    dsns = sorted(set(DSN_RE.findall(src)))
    tables_raw = TABLE_RE.findall(src)
    tables: list[str] = []
    seen: set[str] = set()
    for raw in tables_raw:
        t = raw.rstrip(".")
        tl = t.lower()
        if not t or tl in {"select", "where", "on", "and", "or", "as"}:
            continue
        if t in TABLE_NOISE or tl in TABLE_NOISE:
            continue
        if tl in seen:
            continue
        seen.add(tl)
        tables.append(t)
    json_paths = sorted(set(JSON_PATH_RE.findall(src)), key=len)[:6]
    namespaces = sorted(set(NAMESPACE_RE.findall(src)))
    events = sorted(set(EVENT_RE.findall(src)))
    return {
        "dsns": dsns,
        "tables": tables[:10],
        "json_paths": json_paths,
        "namespaces": namespaces,
        "events": events,
    }


def list_marimo_issues() -> list[dict]:
    cmd = [
        "multica", "issue", "list",
        "--project", MARIMO_PROJECT_ID,
        "--limit", "200",
        "--output", "json",
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if res.returncode != 0:
        raise RuntimeError(
            f"multica issue list failed (rc={res.returncode}): "
            f"{res.stderr.strip()[:200]}"
        )
    payload = json.loads(res.stdout)
    return payload.get("issues", []) if isinstance(payload, dict) else payload


def first_paragraph(text: str | None, limit: int = 280) -> str:
    if not text:
        return ""
    paragraphs = [p.strip() for p in text.split("\n\n") if p.strip()]
    for p in paragraphs:
        stripped = re.sub(r"!\[[^\]]*\]\([^)]+\)", "", p).strip()
        if not stripped:
            continue
        flat = re.sub(r"\s+", " ", stripped)
        if len(flat) > limit:
            flat = flat[: limit - 1].rstrip() + "…"
        return flat
    return ""


def collect_notebooks() -> dict[str, list[Path]]:
    """Map PUL-N → all PUL-N(-suffix)?.py under /srv/marimo-notebooks/."""
    result: dict[str, list[Path]] = {}
    for p in NB_DIR.glob("PUL-*.py"):
        m = re.match(r"(PUL-\d+)", p.stem)
        if m:
            result.setdefault(m.group(1), []).append(p)
    for paths in result.values():
        paths.sort()
    return result


def _append_nb_bullets(out: list[str], ext: dict, indent: str = "") -> None:
    bullets = []
    if ext["dsns"]:
        bullets.append(
            "**DSN:** " + ", ".join(f"`${d}`" for d in ext["dsns"])
        )
    if ext["tables"]:
        bullets.append(
            "**Tables:** " + ", ".join(f"`{t}`" for t in ext["tables"])
        )
    if ext["namespaces"]:
        bullets.append(
            "**ClickEvt namespace:** "
            + ", ".join(f"`{n}`" for n in ext["namespaces"])
        )
    if ext["events"]:
        bullets.append(
            "**Events:** " + ", ".join(f"`{e}`" for e in ext["events"])
        )
    if ext["json_paths"]:
        bullets.append(
            "**JSON paths:** "
            + ", ".join(f"`details{p}`" for p in ext["json_paths"])
        )
    for b in bullets:
        out.append(f"{indent}- {b}")


def format_entry(issue: dict, notebooks: dict[str, list[Path]]) -> str:
    ident = issue.get("identifier", "")
    title = (issue.get("title") or "").strip() or "_(no title)_"
    desc = first_paragraph(issue.get("description"))
    status = issue.get("status", "")
    nbs = notebooks.get(ident, [])

    out = [f"### {ident} — {title}"]
    if desc:
        out.append(f"_{desc}_")
    out.append(
        f"- **Status:** `{status}`" if status else "- **Status:** _(unknown)_"
    )
    if not nbs:
        out.append("- **Notebook:** _(none yet)_")
        return "\n".join(out)

    if len(nbs) == 1:
        nb = nbs[0]
        out.append(f"- **Notebook:** `{nb.name}`")
        _append_nb_bullets(out, extract_notebook(nb))
    else:
        out.append(f"- **Notebooks:** {len(nbs)} files")
        for nb in nbs:
            out.append(f"  - `{nb.name}`")
            _append_nb_bullets(out, extract_notebook(nb), indent="    ")
    return "\n".join(out)


def main() -> int:
    if not NB_DIR.exists():
        print(f"build-index: {NB_DIR} missing", file=sys.stderr)
        return 1

    warning = ""
    try:
        issues = list_marimo_issues()
    except Exception as e:
        warning = (
            f"> ⚠ marimo issue list failed ({e}); "
            "index built from notebooks only.\n\n"
        )
        issues = []

    notebooks = collect_notebooks()

    if not issues and notebooks:
        issues = [
            {"identifier": ident, "title": "", "description": "", "status": ""}
            for ident in notebooks
        ]

    def _sort_key(i: dict) -> int:
        m = re.match(r"PUL-(\d+)", i.get("identifier", "") or "")
        return -int(m.group(1)) if m else 0

    issues.sort(key=_sort_key)

    header = textwrap.dedent("""\
        # MARIMO_INDEX

        Лог marimo-тикетов: о чём спрашивали → куда ходили за данными.
        Grep этот файл по ключевым словам тикета ДО того, как идти в
        `/srv/agent-context/pulse/{pg,external}/`. Если нашёлся релевантный
        PUL-N — открой `/srv/marimo-notebooks/PUL-N*.py` и переиспользуй его
        DSN/таблицы/JSON-пути.

        Авто-генерируется из `multica issue list --project marimo` +
        `/srv/marimo-notebooks/PUL-*.py`. Не редактировать руками — изменения
        будут затёрты следующим запуском `build-index.sh`.
        """) + "\n"
    body = "\n\n".join(format_entry(i, notebooks) for i in issues)
    recipes_section = format_recipes_section(collect_recipes(notebooks))
    content = header + warning + body + "\n"
    if recipes_section:
        content += "\n" + recipes_section

    try:
        NB_DIR.mkdir(parents=True, exist_ok=True)
        fd = tempfile.NamedTemporaryFile(
            "w",
            dir=NB_DIR,
            prefix=".MARIMO_INDEX.",
            suffix=".tmp",
            delete=False,
            encoding="utf-8",
        )
        try:
            fd.write(content)
            fd.flush()
        finally:
            fd.close()
        Path(fd.name).replace(INDEX_PATH)
    except (OSError, PermissionError) as e:
        print(
            f"build-index: cannot write {INDEX_PATH} ({e}). "
            "Probably running in a sandbox without /srv/marimo-notebooks rw "
            "(e.g. agent-2 brainstorm host). Index unchanged.",
            file=sys.stderr,
        )
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
