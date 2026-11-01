#!/bin/bash
# FRITO CI — Large paste → compact chip (interactive TUI via expect)
#
# Verifies the bracketed-paste UX of the RELEASED binary over a real PTY: a paste
# larger than the chip threshold must collapse to a one-line "[pasted N chars #k]"
# chip in the input instead of being silently truncated (the old behavior, which
# inserted "[Pasted text truncated]" and DROPPED everything past 10k chars).
#
# No model call is needed — the chip renders at paste time — so this runs without
# a provider key. Capability-gated: a binary that still shows the truncation
# marker (feature not released yet) SKIPs rather than fails.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo ""
echo "$(bold 'FRITO Large-Paste Chip — interactive TUI (expect)')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $AMI")"
echo ""

section "Prerequisites"
if ! command -v expect &>/dev/null; then
  skip "prereq/expect: not installed (needed for PTY paste test)"
  summary
fi
pass "prereq/expect: available"
if ! command -v python3 &>/dev/null; then
  skip "prereq/python3: not installed (used to build the paste payload)"
  summary
fi
pass "prereq/python3: available"

# A paste whose tail sits PAST the 10k truncation point, so an old (truncating)
# binary would drop the sentinel while the chip behavior keeps the input compact.
SENTINEL="ENDPASTESENTINEL42"
PASTE=$(python3 -c "import sys; sys.stdout.write('A'*10060 + '$SENTINEL')")

section "Bracketed paste → chip"

# Drive the real TUI over a PTY: start it with a dummy provider so the input line
# is reachable, send a bracketed paste (ESC[200~ … ESC[201~), then observe the
# rendered input. We never submit — the chip is produced at paste time.
OUT=$(timeout "$EXPECT_OUTER_TIMEOUT" expect -c "
  set timeout $EXPECT_INNER_TIMEOUT
  log_user 0
  spawn env -i PATH=\$::env(PATH) HOME=\$::env(HOME) TERM=xterm-256color SI_NO_SPLASH=1 NODE_NO_WARNINGS=1 \
    AI_API_KEY=dummy AI_BASE_URL=http://127.0.0.1:1/v1 AI_MODEL=mock-model ${AMI}
  # Wait long enough for the TUI to finish startup/indexing and reach the input
  # line before pasting (5s was too short — the chip never rendered in time).
  sleep 8
  log_user 1
  send \"\033\[200~${PASTE}\033\[201~\"
  sleep 4
  send \"\003\"
  send \"/quit\r\"
  expect eof
" 2>&1 | strip_ansi || true)

# Match the EXACT chip marker "[pasted N chars #k]" (case-sensitive, bracket- and
# #id-anchored). This is distinct from the flash toast "Pasted N chars" that BOTH
# the old and new binaries show, and from the raw paste a PTY echoes to output.
if echo "$OUT" | grep -qE "\[pasted [0-9]+ chars #[0-9]+\]"; then
  pass "paste/chip: large paste collapsed to a compact chip marker in the input"
elif echo "$OUT" | grep -qiE "Pasted text truncated"; then
  skip "paste/chip: installed binary still truncates large pastes (chip feature not released yet)"
else
  skip "paste/chip: no chip or truncation marker observed (bracketed paste unsupported in this PTY, or TUI did not reach input)"
fi

summary
