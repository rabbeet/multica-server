---
name: marimo-pair
description: >-
  Work inside a running marimo notebook's kernel — execute code, create cells,
  and build a notebook as an artifact. Use when the user wants to start a
  marimo notebook or work in an active marimo session.
allowed-tools: Bash(bash **/scripts/discover-servers.sh *), Bash(bash **/scripts/execute-code.sh *), Bash(bash **/scripts/lint-and-persist.sh *), Read
---

# marimo Pair Programming Protocol

This skill gives you full access to a running marimo notebook. You can read
cell code, create and edit cells, install packages, run cells, and inspect
the reactive graph — all programmatically. The user sees results live in their
browser while you work through bundled scripts or MCP.

## Philosophy

marimo notebooks are a dataflow graph — cells are the fundamental unit of
computation, connected by the variables they define and reference. When a cell
runs, marimo automatically re-executes downstream cells. You have full access
to the running notebook.

- **Cells are your main lever.** Use them to break up work and choose how and
  when to bring the human into the loop. Not every cell needs rich output —
  sometimes the object itself is enough, sometimes a summary is better.
  Match the presentation to the intent.
- **Understand intent first.** When clear, act. When ambiguous, clarify.
- **Follow existing signal.** Check imports, `pyproject.toml`, existing cells,
  and `dir(ctx)` before reaching for external tools.
- **Stay focused.** Build first, polish later — cell names, layout, and styling
  can wait.

## Prerequisites

### How to invoke marimo

Only servers started with `--no-token` register in the local server registry
and are auto-discoverable — starting without a token makes discovery easier.
If a server has a token, set the `MARIMO_TOKEN` environment variable before
calling the execute script (avoids leaking the token in process listings). The
right way to invoke marimo depends on context (project
tooling, global install, sandbox mode). See
[finding-marimo.md](reference/finding-marimo.md) for the full decision tree.

**Do NOT use `--headless` unless the user asks for it.** Omitting it lets
marimo auto-open the browser, which is the expected pairing experience. If the
user explicitly requests headless, offer to open `http://localhost:<port>`
in their browser (`open` on macOS, `xdg-open` on Linux, `start` on Windows).

## Troubleshooting

### `SyntaxError` or `ImportError` from `execute-code.sh`

Code runs **inside the running marimo kernel** — `execute-code.sh` POSTs it
over HTTP and never invokes a local Python. So errors here are not caused by
the local Python version, missing venv, or `uv` vs `pip` — they're problems
with the code being sent. Fix the code (use a heredoc for anything
multiline; don't try to one-line compound statements with `;`).

### User keeps getting prompted to allow Bash commands

The skill declares `allowed-tools` in its frontmatter, but Claude Code may
still prompt for each Bash call. To fix this, the user should add the absolute
paths to the scripts to their `.claude/settings.json` (project-level) or
`~/.claude/settings.json` (global):

```json
{
  "permissions": {
    "allow": [
      "Bash(bash /absolute/path/to/skills/marimo-pair/scripts/discover-servers.sh *)",
      "Bash(bash /absolute/path/to/skills/marimo-pair/scripts/execute-code.sh *)",
      "Bash(bash /absolute/path/to/skills/marimo-pair/scripts/lint-and-persist.sh *)"
    ]
  }
}
```

## How to Discover Servers and Execute Code

Three operations: **discover servers**, **execute code**, and **persist + lint**.

| Operation | Script | MCP |
|-----------|--------|-----|
| Discover servers | `bash scripts/discover-servers.sh` | `list_sessions()` tool |
| Execute code | `bash scripts/execute-code.sh -c "code"` | `execute_code(code=..., session_id=...)` tool |
| Execute code (multiline) | `bash scripts/execute-code.sh <<'EOF'` | same |
| Execute code (by URL) | `bash scripts/execute-code.sh --url http://localhost:2718 -c "code"` | same (with `url` param) |
| Persist kernel + lint | `bash scripts/lint-and-persist.sh [session-id]` | — (script-only) |

Scripts auto-discover sessions from the local server registry. Use
`--port` to target a specific server when multiple are running,
`--session` to target a specific session when multiple notebooks are
open on the same server, or `--url` to skip discovery and connect to a
server by URL (e.g. `--url http://localhost:2718`). **On Windows, prefer
direct `--url` when registry discovery is empty** — see the next section
for why. Set the `MARIMO_TOKEN` env var to authenticate when the server
has token auth enabled (`--token` flag also works but exposes the token
in process listings). If the server was started with `--mcp`, you'll
have MCP tools available as an alternative.

### Discovery finds nothing but the user has a server running?

Only `--no-token` servers are in the registry. If discovery comes up empty,
the server likely has token auth — ask the user for the token and set it as
the `MARIMO_TOKEN` environment variable.

On **Windows (Git Bash / MSYS2)**, discovery can also come up empty even for
a running `--no-token` server. If the user confirms marimo is reachable
locally, fall back to `--url http://127.0.0.1:<port>` (ask for the port).

### No servers running?

**Always discover before starting.** Background task "completed" notifications
do not mean the server died — check the output or run discover first.

If no servers are found, read the user's intent — if they want a notebook,
start one. **Always start marimo as a background task** (using
`run_in_background` on the Bash tool) so the server automatically gets cleaned
up when the session ends and doesn't block the conversation. See
[finding-marimo.md](reference/finding-marimo.md).

If there's no `.py` file yet, pick a descriptive filename based on context
(e.g., `exploration.py`, `analysis.py`, `dashboard.py`). Don't ask — just
pick something reasonable.

**Avoid shell escaping issues.** `-c` works for simple one-liners, but for
multiline code or code with quotes/backticks/`${}`, use a heredoc or a file:

```bash
# heredoc (single-quoted delimiter prevents shell interpolation)
bash scripts/execute-code.sh <<'EOF'
import marimo._code_mode as cm

async with cm.get_context() as ctx:
    ctx.create_cell("x = 1")
EOF

# file
bash scripts/execute-code.sh /tmp/code.py

# target a specific port (skips auto-selection when multiple servers run)
bash scripts/execute-code.sh --port 2718 -c "1 + 1"
```

## Executing Code

Every execute-code call runs inside the notebook's kernel. All cell variables
are in scope — `print(df.head())` just works. Nothing you define persists
between calls (variables, imports, side-effects all reset), but you can freely
introspect the notebook: inspect variables, test code snippets, check types
and shapes. Use this to explore, prototype, and validate before committing
anything to the notebook — then create cells to persist state and make results
visible to the user.

To mutate the notebook's dataflow graph — create, edit, and delete cells,
install packages, and run cells — use `marimo._code_mode`:

```python
import marimo._code_mode as cm

async with cm.get_context() as ctx:
    cid = ctx.create_cell("x = 1")
    ctx.packages.add("pandas")
    ctx.run_cell(cid)
```

You **must** use `async with` — without it, operations silently do nothing.
All `ctx.*` methods are **synchronous** — they queue operations and the
context manager flushes them on exit. Do **not** `await` them.

The kernel supports top-level `await`, so use `async with` directly. Do
**not** wrap calls in `async def main(): ...` + `asyncio.run(main())` — it's
unnecessary and easy to get wrong (compound statements like `async with`
can't follow `def name():` on the same line, so cramming it into a `-c`
one-liner produces a `SyntaxError`).

**Cells are not auto-executed.** `create_cell` and `edit_cell` are structural
changes only — use `run_cell` to queue execution.

`code_mode` is a tested, safe API for notebook mutations — prefer it for all
structural changes. You also have access to marimo internals from the kernel,
but treat that as a last resort and only with high confidence after exploration.

**Edit cells through `code_mode`, never the file system. Direct file writes
are silently lost.** It is tempting to reach for `Edit`/`Write` for a small
tweak since `edit_cell` requires the full new cell body. Don't — without
`--watch` (off by default) the kernel never sees those edits and overwrites
them on its next save, so the user sees nothing. (`Read` on the `.py` is
okay, but content may lag the live kernel; prefer `ctx.cells[target].code`.)

## Persistence — edits stay in-kernel until you flush them

`ctx.create_cell` / `ctx.edit_cell` / `ctx.delete_cell` mutate the live
kernel's notebook document. They do **not** touch the `.py` file on disk —
marimo only writes the file when something calls `/api/kernel/save`. Until
then, any frontend reload (Cmd+R, a kernel restart, the user opening the
file in another tab) re-reads the *old* `.py` from disk and **silently
clobbers** every in-kernel edit you made. The user reports "your fix didn't
stick", and you're chasing a ghost.

Flush after every edit batch. The bundled `scripts/lint-and-persist.sh`
script does exactly that and also runs the lint checks below — use it as
the publication gate instead of calling `/api/kernel/save` by hand:

```bash
# After ctx.edit_cell / ctx.create_cell / ctx.delete_cell — flush + lint.
bash scripts/lint-and-persist.sh                    # current session
bash scripts/lint-and-persist.sh s_abc123           # specific session
bash scripts/lint-and-persist.sh --strict-hide-code # also enforce hide_code
```

Exit 0 = persisted and clean (`.py` on disk now matches the kernel). Exit 1
= the file is persisted **but the lint failed**; tell the user what failed,
don't publish the tailnet URL until the next run is green. Exit 2/3 = bad
args or transport failure (server unreachable, missing session id).

The script needs the `Marimo-Server-Token` to call `/api/kernel/save`. It
extracts the token from the index page automatically; nothing for you to
configure on a `--no-token` server. For token-auth servers, set
`MARIMO_TOKEN=...` as usual.

## Cell-variable scoping — "one variable, one cell"

marimo's reactive graph keys on top-level variable definitions. Every
public (non-`_`-prefixed) name defined at the top level of a `@app.cell`
function becomes a node in the graph. **If the same public name is defined
in two cells, marimo blocks both cells from running** and replaces their
rendered output with the red banner: "This cell wasn't run because it has
errors / redefines variables from other cells". The user sees the cell's
source (e.g. raw `ch.query(...)` SQL) instead of the table or chart.

`scripts/lint-and-persist.sh` detects this statically by parsing the
persisted `.py` AST and reporting every public name defined in 2+ cells,
with file:line for each collision. Three rules avoid hitting it in the
first place:

- **One setup cell for shared imports + long-lived clients.** Put `import
  pandas as pd`, `mo`, `ch`, `pg_conn`, etc. in a single cell. Every other
  cell consumes them as function arguments — never re-imports.
- **Scratch variables are private to the cell — prefix them with `_`.**
  `_rows`, `_fig`, `_ax`, `_query`, `_total_n`. These names live inside
  the cell's Python scope but are *not* registered in the reactive graph,
  so any number of cells may share them with no conflict.
- **Data / plot / table cells use `@app.cell(hide_code=True)`** so the
  user sees the table or chart, not the SQL/`pd.DataFrame(...)`/`plt.subplots(...)`
  underneath. Pair with `--strict-hide-code` if you want the lint to enforce
  it (intro markdown cell is exempt).

**UI state lives outside the reactive graph.** Anywidget traitlets can be read
or set directly (e.g., `slider.value = 5`). For `mo.ui.*` elements, use
`ctx.set_ui_value(element, new_value)` inside `code_mode`.

### First Step: Explore the API

The `code_mode` API can change between marimo versions. Explore it at the
start of each session — dig deeper into anything you're unsure about.

```python
import marimo._code_mode as cm
help(cm)
```

## Guard Rails

Skip these and the UI breaks:

- **Install packages via `ctx.packages.add()`, not `uv add` or `pip`.**
  The code API handles kernel restarts and dependency resolution correctly.
  Only fall back to external CLIs if the API is unavailable or fails.
- **Custom widget = anywidget.** For bespoke visual components, use anywidget
  with HTML/CSS/JS. Composed `mo.ui` is fine for simple forms and controls.
  See [rich-representations.md](reference/rich-representations.md).
- **NEVER `Edit`, `Write`, or `NotebookEdit` the notebook `.py` file while a
  session is running. Direct writes are silently destroyed and never reach the
  user.** marimo only watches the file with `--watch`, which is off by
  default. Without it, the kernel doesn't pick up file edits — and on its
  next save, the kernel writes its own state and clobbers yours. The user sees
  no change, you think the work landed, and the bug is invisible. Always use
  `ctx.edit_cell(target, code=...)` with the full new cell body — even for a
  one-character change. (`Read` is allowed, but disk content may lag the live
  kernel; for the current truth prefer `ctx.cells[target].code`.)
- **No temp-file deps in cells.** `pathlib.Path("/tmp/...")` in cell code is a bug.
- **Avoid empty cells.** Prefer `edit_cell` into existing empty cells rather
  than creating new ones. Clean up any cells that end up empty after edits.
- **Don't worry about cell names.** Most cells don't need explicit names —
  see [notebook-improvements.md](reference/notebook-improvements.md#cell-names).

## Widgets and Reactivity

Anywidget state (traitlets) lives outside marimo's reactive graph. To hook a
widget trait into the graph, pick one strategy per widget — never mix them:

- **`mo.state` + `.observe()`** — you pick specific traits to bridge. Default choice.
- **`mo.ui.anywidget()`** — wraps all synced traits into one reactive `.value`. Convenient but coarser.

Read [rich-representations.md](reference/rich-representations.md) before wiring either.

## Keep in Mind

- **The user is editing too.** The notebook can change between your calls —
  re-inspect notebook state if it's been a while since you last looked.
- **Deletions are destructive.** Deleting a cell removes its variables from
  kernel memory — restoring means recreating the cell and re-running it and
  its dependents. If intent seems ambiguous, ask first.
- **Installing packages changes the project.** `ctx.packages.add()` adds
  real dependencies — confirm when it's not obvious from context.

## References

- [finding-marimo.md](reference/finding-marimo.md) — how to find and invoke the right marimo
- [gotchas.md](reference/gotchas.md) — cached module proxies and other traps
- [rich-representations.md](reference/rich-representations.md) — custom widgets and visualizations
- [notebook-improvements.md](reference/notebook-improvements.md) — improving existing notebooks
- `scripts/lint-and-persist.sh` — flush kernel state to disk and lint for cell-scope collisions / errors / `hide_code`
