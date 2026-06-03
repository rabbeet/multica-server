#!/usr/bin/env bash
# Shell-syntax + argparse check for interrupt.sh. Pure test — no live marimo.
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERRUPT="$SCRIPTS_DIR/interrupt.sh"
CLIENT="$SCRIPTS_DIR/client.py"

# 1. bash -n
bash -n "$INTERRUPT"

# 2. --help exits 0 and emits usage
out=$(bash "$INTERRUPT" --help 2>&1) || true
case "$out" in
    *Usage:*|*usage:*) ;;
    *)
        echo "test_interrupt_syntax: --help did not emit usage" >&2
        echo "$out" >&2
        exit 1
        ;;
esac

# 3. Unknown option exits 2
unk_rc=0
bash "$INTERRUPT" --bogus 2>/dev/null || unk_rc=$?
if [[ "$unk_rc" != "2" ]]; then
    echo "test_interrupt_syntax: --bogus exit was $unk_rc, want 2" >&2
    exit 1
fi

# 4. Unexpected positional arg exits 2
pos_rc=0
bash "$INTERRUPT" trailing 2>/dev/null || pos_rc=$?
if [[ "$pos_rc" != "2" ]]; then
    echo "test_interrupt_syntax: positional arg exit was $pos_rc, want 2" >&2
    exit 1
fi

# 5. client.py interrupt subcommand registered (with --help)
out=$(python3 "$CLIENT" interrupt --help 2>&1)
case "$out" in
    *usage:*) ;;
    *)
        echo "test_interrupt_syntax: client.py interrupt --help missing usage" >&2
        exit 1
        ;;
esac

echo "test_interrupt_syntax: ok"
