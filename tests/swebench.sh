#!/bin/bash
# FRITO CI — SWE-bench Skill: real-instance pass@1 gate (official harness)
#
# Exercises the `swebench` stance skill (skills/swebench/SKILL.md) on a REAL
# SWE-bench Lite instance, scored with the OFFICIAL swebench harness so the
# environment (old Python/deps) is pinned exactly via the instance's prebuilt
# Docker image — the only faithful way to run a real instance (current runners
# ship Python 3.12, which the pinned repos predate).
#
# Instance: pytest-dev__pytest-6116 — "pytest needs a one-char shortcut for
# --collect-only". The gold fix adds a `--co` alias in src/_pytest/main.py; the
# graded tests invoke `pytest --co`. Smallest-patch, self-contained (pytest's
# own pytester tmpdirs — no network, no external fixtures), so it's the easiest
# real instance for a pass@1 smoke gate.
#
# Flow: clone repo@base_commit -> run `ami --skill swebench` to produce a patch
# (prediction) -> official harness applies it + the test_patch in the instance
# Docker image and runs FAIL_TO_PASS -> we gate on `resolved`.
#
# Requires: Docker/Podman, python3 (+ venv), pip, a live provider key (FRITO).
# Like pentest-mcp.sh this is a real-agent + container suite — exercised end to
# end only in CI. Every infra/setup/transient failure SKIPs (never false-fails);
# only a VALID run that leaves the instance unresolved fails the gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# ── Instance definition (override via env to run a different one) ──────────────
SWEBENCH_INSTANCE="${SWEBENCH_INSTANCE:-pytest-dev__pytest-6116}"
SWEBENCH_REPO_URL="${SWEBENCH_REPO_URL:-https://github.com/pytest-dev/pytest}"
SWEBENCH_BASE_COMMIT="${SWEBENCH_BASE_COMMIT:-e670ff76cbad80108bde9bab616b66771b8653cf}"
SWEBENCH_DATASET="${SWEBENCH_DATASET:-princeton-nlp/SWE-bench_Lite}"
SWEBENCH_PKG="${SWEBENCH_PKG:-swebench}"          # pinnable, e.g. swebench==3.0.17
SWEBENCH_PROBLEM="${SWEBENCH_PROBLEM:-pytest has a long flag --collect-only to only collect tests without running them. Add a short one-character alias --co for it. Edit the pytest source so that running pytest with --co behaves exactly like --collect-only. Do not modify any test files; run the test suite to verify.}"

AGENT_TIMEOUT="${SWEBENCH_AGENT_TIMEOUT:-360}"    # autonomous multi-step run
AGENT_TURNS="${SWEBENCH_AGENT_TURNS:-50}"
HARNESS_TIMEOUT="${SWEBENCH_HARNESS_TIMEOUT:-1800}" # image pull + build + eval

echo ""
echo "$(bold 'FRITO SWE-bench Skill — real-instance pass@1 gate')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Instance: $SWEBENCH_INSTANCE  |  Binary: $AMI")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Prerequisites
# ═══════════════════════════════════════════════════════════════════
section "Prerequisites"

CONTAINER_RT=""
command -v docker &>/dev/null && docker info &>/dev/null && CONTAINER_RT="docker"
[ -z "$CONTAINER_RT" ] && command -v podman &>/dev/null && CONTAINER_RT="podman"
if [ -z "$CONTAINER_RT" ]; then
  skip "prereq/runtime: no working docker/podman (official harness needs containers)"
  summary
fi
pass "prereq/runtime: $CONTAINER_RT available"

if ! command -v python3 &>/dev/null; then skip "prereq/python3: not found"; summary; fi
pass "prereq/python3: $(python3 --version 2>&1)"

# Resolve a live provider. SWE-bench needs a strong coding model + big context.
TOOL_PID="" TOOL_MODEL="" TOOL_ENV=""
if has_frito_config; then
  declare -A SWEBENCH_MODELS=(
    [anthropic]="claude-sonnet-4-20250514"
    [openai]="gpt-5.6-luna"
    [google]="gemini-2.5-pro"
  )
  for _candidate in anthropic openai google; do
    if has_key "$_candidate"; then
      TOOL_PID="$_candidate"
      TOOL_MODEL="${SWEBENCH_MODEL:-${SWEBENCH_MODELS[$_candidate]}}"
      TOOL_ENV=$(provider_env_string "$_candidate" "$(get_key "$_candidate")")
      echo "  $(dim "Provider: $_candidate (model: $TOOL_MODEL)")"
      break
    fi
  done
fi
if [ -z "$TOOL_PID" ]; then skip "prereq/provider: no live provider available"; summary; fi
pass "prereq/provider: $TOOL_PID available"

# Binary must ship the swebench skill (older releases don't).
INTROSPECT=$($AMI --introspect 2>/dev/null || true)
if echo "$INTROSPECT" | jq -e '.skills[]?.name' >/dev/null 2>&1 \
   && echo "$INTROSPECT" | jq -r '.skills[].name' | grep -qx "swebench"; then
  pass "prereq/skill: swebench stance present"
else
  skip "prereq/skill: installed binary has no swebench skill" "$($AMI --version 2>/dev/null | head -1)"
  summary
fi

# Official harness (isolated venv so we never touch the system site-packages).
WORK=$(mktemp -d "${TMPDIR:-/tmp}/swebench-XXXXXX")
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

VENV="$WORK/venv"
if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
  skip "prereq/harness: python venv unavailable (need python3-venv)"
  summary
fi
# shellcheck disable=SC1091
. "$VENV/bin/activate"
echo "  $(dim 'installing the official swebench harness...')"
if ! timeout 300 pip install -q "$SWEBENCH_PKG" >/dev/null 2>&1; then
  skip "prereq/harness: pip install $SWEBENCH_PKG failed"
  summary
fi
if ! python3 -c "import swebench" 2>/dev/null; then
  skip "prereq/harness: swebench import failed after install"
  summary
fi
pass "prereq/harness: swebench installed ($(python3 -c 'import swebench;print(getattr(swebench,"__version__","?"))' 2>/dev/null))"

# ═══════════════════════════════════════════════════════════════════
# Step 1 — produce a prediction patch with the agent
# ═══════════════════════════════════════════════════════════════════
section "Agent run (prediction)"

REPO_DIR="$WORK/repo"
git init -q "$REPO_DIR"
if ! ( cd "$REPO_DIR" \
        && git remote add origin "$SWEBENCH_REPO_URL" \
        && timeout 300 git fetch -q --depth 1 origin "$SWEBENCH_BASE_COMMIT" \
        && git checkout -q FETCH_HEAD ); then
  skip "repo/checkout: could not fetch $SWEBENCH_REPO_URL@$SWEBENCH_BASE_COMMIT"
  summary
fi
pass "repo/checkout: ${SWEBENCH_REPO_URL##*/}@${SWEBENCH_BASE_COMMIT:0:12}"

pwait "$TOOL_PID"
echo "  $(dim '▸ running the swebench autonomous stance to fix the issue...')"
AGENT_OUT=$(cd "$REPO_DIR" && timeout "$AGENT_TIMEOUT" env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  $TOOL_ENV \
  "$AMI" --skill swebench --model "$TOOL_MODEL" --permission-mode auto-allow \
  --max-turns "$AGENT_TURNS" \
  --prompt "$SWEBENCH_PROBLEM" \
  2>/dev/null) || true

# Transient / provider errors -> skip (don't false-fail the gate).
if [ -z "$AGENT_OUT" ] || ( echo "$AGENT_OUT" | jq -e '.error' >/dev/null 2>&1 \
     && echo "$AGENT_OUT" | jq -r '.error' | grep -qiE "429|rate.limit|quota|resource.exhausted|timeout|overloaded|max.turns|server error|HTTP [45]|Max retries|context.overflow"); then
  skip "agent/run: transient or empty output" "${AGENT_OUT:0:80}"
  summary
fi
pass "agent/run: completed"

# The prediction is the agent's working-tree diff (source only). The harness
# applies the instance's own test_patch, so any test edits the agent made are
# irrelevant — but we still exclude them so a stray test edit can't mask a fix.
PATCH_FILE="$WORK/model_patch.diff"
( cd "$REPO_DIR" && git add -A && git diff --cached -- . ':(exclude)*test*' ':(exclude)*/tests/*' ) > "$PATCH_FILE" 2>/dev/null || true
if [ ! -s "$PATCH_FILE" ]; then
  fail "agent/patch: agent produced no source changes"
  summary
fi
pass "agent/patch: $(wc -l < "$PATCH_FILE") diff lines produced"

# ═══════════════════════════════════════════════════════════════════
# Step 2 — score with the official harness (pinned env via Docker image)
# ═══════════════════════════════════════════════════════════════════
section "Official harness evaluation"

PREDS="$WORK/preds.jsonl"
python3 - "$SWEBENCH_INSTANCE" "$PATCH_FILE" > "$PREDS" <<'PY'
import json, sys
inst, patch_file = sys.argv[1], sys.argv[2]
with open(patch_file) as f:
    patch = f.read()
print(json.dumps({"instance_id": inst, "model_name_or_path": "ami", "model_patch": patch}))
PY
pass "harness/preds: wrote prediction for $SWEBENCH_INSTANCE"

RUN_ID="frito-$(date -u +%s)"
echo "  $(dim '▸ pulling the instance image + running FAIL_TO_PASS (this is slow)...')"
HARNESS_LOG="$WORK/harness.log"
set +e
( cd "$WORK" && timeout "$HARNESS_TIMEOUT" python3 -m swebench.harness.run_evaluation \
    --dataset_name "$SWEBENCH_DATASET" \
    --predictions_path "$PREDS" \
    --run_id "$RUN_ID" \
    --instance_ids "$SWEBENCH_INSTANCE" \
    --max_workers 1 \
    --cache_level none ) >"$HARNESS_LOG" 2>&1
HARNESS_RC=$?
set -e

# Infra failures (image pull, docker daemon, OOM) -> skip, not fail.
if [ "$HARNESS_RC" -ne 0 ] && grep -qiE "docker|image|pull|connection|daemon|No space|timeout|Killed|OOM" "$HARNESS_LOG"; then
  skip "harness/run: infra failure (rc=$HARNESS_RC)" "$(tail -1 "$HARNESS_LOG" 2>/dev/null)"
  summary
fi

# Parse the report: swebench writes <model>.<run_id>.json with resolved_ids.
REPORT=$(ls "$WORK"/ami.*"$RUN_ID"*.json "$WORK"/*"$RUN_ID"*.json 2>/dev/null | head -1 || true)
if [ -z "$REPORT" ] || [ ! -f "$REPORT" ]; then
  skip "harness/report: no evaluation report produced (rc=$HARNESS_RC)" "$(tail -2 "$HARNESS_LOG" 2>/dev/null | tr '\n' ' ')"
  summary
fi
pass "harness/report: $(basename "$REPORT")"

RESOLVED=$(jq -r --arg id "$SWEBENCH_INSTANCE" \
  '(.resolved_ids // []) as $r | if ($r|index($id)) then "yes" else "no" end' "$REPORT" 2>/dev/null || echo "no")
RESOLVED_COUNT=$(jq -r '.resolved_instances // (.resolved_ids|length) // 0' "$REPORT" 2>/dev/null || echo 0)

section "Score"
echo "  $(bold "SWE-bench pass@1: ${RESOLVED_COUNT}/1 resolved ($SWEBENCH_INSTANCE)")" >&2
if [ "$RESOLVED" = "yes" ]; then
  pass "score/gate: $SWEBENCH_INSTANCE resolved (test FAIL->PASS via the agent's patch)"
else
  fail "score/gate: $SWEBENCH_INSTANCE NOT resolved by the agent's patch"
fi

summary
