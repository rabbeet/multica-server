#!/usr/bin/env python3
"""AST-level guardrails for marimo notebooks.

Used by ``lint-and-persist.sh`` after the kernel state is flushed to disk.
Operates on the persisted ``.py`` file plus a JSON dump of cell runtime
state (status + errors) coming from the kernel via ``ctx.cells``.

Checks (in order):

1. **runtime errors** — any cell whose runtime status is exception /
   marimo-error / cancelled / interrupted, or which carries graph errors
   (multiply-defined variable, cycle, ...).
2. **top-level name collisions** — public (non-``_``-prefixed) names defined
   in 2+ ``@app.cell``-decorated functions. marimo's "one variable, one cell"
   rule will block these cells from running, surfacing as the red
   "This cell wasn't run because it has errors / redefines variables from
   other cells" banner.
3. **hide_code** (optional, ``--strict``) — every cell after the first must
   carry ``@app.cell(hide_code=True)``; the user wants tables and plots, not
   the SQL/imports underneath them.

Args: ``<notebook.py> <strict-bool> <cells.json-path>``.
Exits 0 on clean, 1 on lint failure. Stdout is human-readable.
"""
from __future__ import annotations

import ast
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# AST visitor: collect top-level names bound inside a single function body.
# Skips nested function / class / lambda / comprehension scopes (own scope),
# recurses into control-flow blocks (if / for / while / with / try), which
# do leak bindings to the enclosing function scope.
# ---------------------------------------------------------------------------


class _CellScopeVisitor(ast.NodeVisitor):
    def __init__(self) -> None:
        self.names: set[str] = set()

    # Nested scopes — record only the introduced name; don't recurse.
    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:  # noqa: N802
        self.names.add(node.name)

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:  # noqa: N802
        self.names.add(node.name)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:  # noqa: N802
        self.names.add(node.name)

    def visit_Lambda(self, node: ast.Lambda) -> None:  # noqa: N802
        return

    def visit_ListComp(self, node: ast.ListComp) -> None:  # noqa: N802
        return

    def visit_SetComp(self, node: ast.SetComp) -> None:  # noqa: N802
        return

    def visit_DictComp(self, node: ast.DictComp) -> None:  # noqa: N802
        return

    def visit_GeneratorExp(self, node: ast.GeneratorExp) -> None:  # noqa: N802
        return

    # Bindings.
    def _add_target(self, t: ast.AST) -> None:
        if isinstance(t, ast.Name):
            self.names.add(t.id)
        elif isinstance(t, (ast.Tuple, ast.List)):
            for elt in t.elts:
                self._add_target(elt)
        elif isinstance(t, ast.Starred):
            self._add_target(t.value)
        # Attribute / Subscript targets don't introduce new names.

    def visit_Assign(self, node: ast.Assign) -> None:  # noqa: N802
        for t in node.targets:
            self._add_target(t)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:  # noqa: N802
        # Augmented assign requires an existing binding; not a new def.
        return

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:  # noqa: N802
        self._add_target(node.target)

    def visit_NamedExpr(self, node: ast.NamedExpr) -> None:  # noqa: N802
        self._add_target(node.target)
        self.generic_visit(node)

    def visit_Import(self, node: ast.Import) -> None:  # noqa: N802
        for a in node.names:
            self.names.add(a.asname or a.name.split(".")[0])

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:  # noqa: N802
        for a in node.names:
            self.names.add(a.asname or a.name)

    def visit_For(self, node: ast.For) -> None:  # noqa: N802
        self._add_target(node.target)
        for s in node.body + node.orelse:
            self.visit(s)

    def visit_AsyncFor(self, node: ast.AsyncFor) -> None:  # noqa: N802
        self._add_target(node.target)
        for s in node.body + node.orelse:
            self.visit(s)

    def visit_With(self, node: ast.With) -> None:  # noqa: N802
        for it in node.items:
            if it.optional_vars is not None:
                self._add_target(it.optional_vars)
        for s in node.body:
            self.visit(s)

    def visit_AsyncWith(self, node: ast.AsyncWith) -> None:  # noqa: N802
        for it in node.items:
            if it.optional_vars is not None:
                self._add_target(it.optional_vars)
        for s in node.body:
            self.visit(s)

    def visit_Try(self, node: ast.Try) -> None:  # noqa: N802
        for s in node.body + node.orelse + node.finalbody:
            self.visit(s)
        for h in node.handlers:
            for s in h.body:
                self.visit(s)
            if h.name is not None:
                self.names.add(h.name)

    def visit_If(self, node: ast.If) -> None:  # noqa: N802
        for s in node.body + node.orelse:
            self.visit(s)

    def visit_While(self, node: ast.While) -> None:  # noqa: N802
        for s in node.body + node.orelse:
            self.visit(s)

    def visit_Match(self, node: ast.Match) -> None:  # noqa: N802
        for case in node.cases:
            for s in case.body:
                self.visit(s)


def _is_app_cell_decorator(deco: ast.expr) -> bool:
    target = deco.func if isinstance(deco, ast.Call) else deco
    return (
        isinstance(target, ast.Attribute)
        and target.attr == "cell"
        and isinstance(target.value, ast.Name)
        and target.value.id == "app"
    )


def _hide_code_from_decorator(deco: ast.expr) -> bool | None:
    if not isinstance(deco, ast.Call):
        return None
    for kw in deco.keywords:
        if kw.arg == "hide_code" and isinstance(kw.value, ast.Constant):
            return bool(kw.value.value)
    return None


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: _lint.py <notebook.py> <strict-hide-code:true|false> "
            "<cells-json-path>",
            file=sys.stderr,
        )
        return 2

    notebook_path = Path(sys.argv[1])
    strict_hide_code = sys.argv[2] == "true"
    cells = json.loads(Path(sys.argv[3]).read_text())

    problems: list[str] = []

    # 1. Runtime error / graph error check.
    bad_statuses = {"exception", "marimo-error", "cancelled", "interrupted"}
    errored = [
        c
        for c in cells
        if ((c.get("status") or "").split(".")[-1] in bad_statuses)
        or c.get("errors")
    ]
    if errored:
        lines = ["x cells with errors:"]
        for c in errored:
            head = (c.get("code", "").lstrip().split("\n", 1)[0] or "<empty>")[:80]
            lines.append(
                f"  - {c['id']} ({c.get('name') or 'unnamed'}) "
                f"[{c.get('status')}]: {head}"
            )
            for e in c.get("errors", []):
                lines.append(f"      {e.get('kind')}: {e.get('msg')}")
        lines.append(
            "    Fix: re-run the cell from the marimo UI (or `ctx.run_cell(...)`); "
            "if it still errors, address the exception before publishing."
        )
        problems.append("\n".join(lines))

    # 2. AST collision check.
    source = notebook_path.read_text()
    try:
        tree = ast.parse(source, filename=str(notebook_path))
    except SyntaxError as exc:
        problems.append(f"x cannot parse {notebook_path}: {exc}")
        for p in problems:
            print(p)
        return 1

    cell_funcs: list[tuple[str, int, bool | None, set[str]]] = []
    for node in tree.body:
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        decos = [d for d in node.decorator_list if _is_app_cell_decorator(d)]
        if not decos:
            continue
        v = _CellScopeVisitor()
        for s in node.body:
            v.visit(s)
        arg_names = {a.arg for a in node.args.args + node.args.kwonlyargs + node.args.posonlyargs}
        if node.args.vararg:
            arg_names.add(node.args.vararg.arg)
        if node.args.kwarg:
            arg_names.add(node.args.kwarg.arg)
        names = v.names - arg_names
        cell_funcs.append((node.name, node.lineno, _hide_code_from_decorator(decos[0]), names))

    public_to_cells: dict[str, list[tuple[str, int]]] = {}
    for fname, lineno, _hc, names in cell_funcs:
        for n in names:
            if n.startswith("_"):
                continue
            public_to_cells.setdefault(n, []).append((fname, lineno))

    collisions = {n: locs for n, locs in public_to_cells.items() if len(locs) > 1}
    if collisions:
        lines = [
            "x top-level name defined in 2+ @app.cell functions "
            "(marimo blocks these cells with 'redefines variables from other cells'):"
        ]
        for name, locs in sorted(collisions.items()):
            loc_str = ", ".join(f"{f}@L{ln}" for f, ln in locs)
            lines.append(f"  - {name!r} defined in: {loc_str}")
        lines.append(
            "    Fix: keep one definition (move imports/clients to a single setup cell), "
            "or rename per-cell scratch names with a leading underscore (e.g. _rows, _fig, _ax)."
        )
        problems.append("\n".join(lines))

    # 3. hide_code strict mode.
    if strict_hide_code:
        bad = []
        for idx, (fname, lineno, hc, _names) in enumerate(cell_funcs):
            if idx == 0:
                continue  # let the leading intro/markdown cell be its own choice
            if hc is not True:
                bad.append((fname, lineno))
        if bad:
            lines = ["x cells without hide_code=True (--strict-hide-code):"]
            for n, ln in bad:
                lines.append(f"  - {n}@L{ln}")
            lines.append(
                "    Fix: change @app.cell to @app.cell(hide_code=True) on data/plot/table cells."
            )
            problems.append("\n".join(lines))

    if problems:
        print()
        for p in problems:
            print(p)
        print()
        return 1

    n = len(cell_funcs)
    print(f"ok {n} cells linted: no collisions, no errors" + (", hide_code OK" if strict_hide_code else "") + ".")
    return 0


if __name__ == "__main__":
    sys.exit(main())
