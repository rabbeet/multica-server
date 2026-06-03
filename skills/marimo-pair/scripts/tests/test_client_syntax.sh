#!/usr/bin/env bash
# Verify client.py imports cleanly and its argparse spec is sound.
# Pure test — no live marimo required.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$SCRIPTS_DIR/client.py"

# 1. Syntax-check (AST parse).
python3 -c "import ast; ast.parse(open('$CLIENT').read())"

# 2. Each subcommand must respond to --help with exit 0 and emit usage.
for sub in discover ping dump-cells edit-and-run run-cell; do
  out=$(python3 "$CLIENT" "$sub" --help 2>&1)
  case "$out" in
    *usage:*) ;;
    *)
      echo "test_client_syntax: '$sub --help' did not emit usage" >&2
      echo "$out" >&2
      exit 1
      ;;
  esac
done

# 3. edit-and-run requires --cell-id and --code-file.
if python3 "$CLIENT" edit-and-run 2>/dev/null; then
  echo "test_client_syntax: edit-and-run accepted no args (should require --cell-id)" >&2
  exit 1
fi

# 4. The build_parser() factory is importable (catches argparse spec drift).
PYTHONPATH="$SCRIPTS_DIR" python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('client', '$CLIENT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
p = m.build_parser()
sub_names = [a.choices for a in p._subparsers._actions if hasattr(a, 'choices') and a.choices]
flat = []
for d in sub_names:
    flat.extend(d.keys())
required = {'discover', 'ping', 'dump-cells', 'edit-and-run', 'run-cell'}
missing = required - set(flat)
assert not missing, f'missing subcommands: {missing}'
"

echo "test_client_syntax: ok"
