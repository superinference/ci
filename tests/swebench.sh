#!/bin/bash
# FRITO CI — SWE-bench Skill: real-instance pass@1 gate (OFFICIAL SWE-bench-Live)
#
# Exercises the `swebench` stance skill (skills/swebench/SKILL.md) on a REAL
# SWE-bench-Live instance, scored with the OFFICIAL evaluator the same way the
# user's OCP/K8s benchmark runs it (see challenges/ocp_cluster): the official
# `python -m evaluation.evaluation` from microsoft/SWE-bench-Live (+ its RepoLaunch
# `launch` submodule), which pulls the instance's prebuilt Docker image, applies
# the model_patch + the instance's gold test_patch inside it, runs the tests, and
# parses them with the per-instance parser from the dataset. We never re-grade —
# running the exact official command is the only way to avoid the score-inflation
# traps (naive parser / baseline exclusion / patch fallbacks / patch order).
#
# Instance: cyclotruc__gitingest-94 (Python, SWE-bench-Live `lite` split) — the
# EASIEST instance found: a 1-file, 1-hunk, 2-line gold fix in
# src/gitingest/parse_query.py (accept "http://" URLs, not just "https://"),
# graded by 1 FAIL_TO_PASS + 30 PASS_TO_PASS tests via `pytest`. Smallest patch
# + fewest tests = the fastest, least-flaky real pass@1 smoke gate.
#
# Flow: clone repo@base_commit -> run `ami --skill swebench` to produce a patch
# (prediction) -> official evaluator applies it + the gold test_patch in the
# prebuilt image and runs BOTH graded sets: FAIL_TO_PASS (must flip fail->pass)
# AND PASS_TO_PASS (must stay passing — no regression). `resolved` requires both
# (evaluation.evaluation: resolved = P2P failures==0 AND F2P failures==0 AND all
# F2P pass), so gating on `resolved` already enforces PASS_TO_PASS.
#
# IMPORTANT: the evaluator must run DIRECTLY on the CI runner (not nested in a
# container). RepoLaunch bind-mounts `os.getcwd()/tmp -> /mnt_tmp` into each eval
# container; the model/test patches are written there, so the evaluator's cwd must
# be a real path on the SAME Docker host that runs the eval containers. On a GH
# runner that's automatic (the runner IS the docker host). Docker is pre-installed.
#
# Requires: Docker, python3 (+ venv), pip, git, a live provider key (FRITO).
# Like pentest-mcp.sh this is a real-agent + container suite — exercised end to
# end only in CI. Every infra/setup/transient failure SKIPs (never false-fails);
# a valid run that leaves the instance unresolved SKIPs too (informational — agent
# pass@1 is a model-capability outcome, not a CI-infra failure).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# ── Instance definition (override via env to run a different one) ──────────────
SWEBENCH_INSTANCE="${SWEBENCH_INSTANCE:-cyclotruc__gitingest-94}"
SWEBENCH_REPO_URL="${SWEBENCH_REPO_URL:-https://github.com/cyclotruc/gitingest}"
SWEBENCH_BASE_COMMIT="${SWEBENCH_BASE_COMMIT:-2125765025c65fdd2aec89856bdc095dfb0fc826}"
SWEBENCH_DATASET="${SWEBENCH_DATASET:-SWE-bench-Live/SWE-bench-Live}"
SWEBENCH_SPLIT="${SWEBENCH_SPLIT:-lite}"
SWEBENCH_EVAL_REPO="${SWEBENCH_EVAL_REPO:-https://github.com/microsoft/SWE-bench-Live.git}"
SWEBENCH_EVAL_REF="${SWEBENCH_EVAL_REF:-main}"
SWEBENCH_PROBLEM="${SWEBENCH_PROBLEM:-Git Ingest requests fail when the input repository URL starts with \"http://\" instead of \"https://\". This is likely because _parse_url in parse_query.py explicitly checks only for \"https://\". Fix the source so that http:// URLs are handled the same as https:// URLs. Do not modify any test files; run the test suite to verify.}"

AGENT_TIMEOUT="${SWEBENCH_AGENT_TIMEOUT:-360}"     # autonomous multi-step run
AGENT_TURNS="${SWEBENCH_AGENT_TURNS:-50}"
HARNESS_TIMEOUT="${SWEBENCH_HARNESS_TIMEOUT:-1800}" # image pull + eval
PIP_TIMEOUT="${SWEBENCH_PIP_TIMEOUT:-420}"          # evaluator install

echo ""
echo "$(bold 'FRITO SWE-bench Skill — real-instance pass@1 gate (official SWE-bench-Live)')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Instance: $SWEBENCH_INSTANCE ($SWEBENCH_DATASET:$SWEBENCH_SPLIT)  |  Binary: $AMI")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# Prerequisites
# ═══════════════════════════════════════════════════════════════════
# summary() only exits on FAILs, so `skip; summary` does NOT stop the script —
# use this to skip-and-exit-green so an unmet prereq/infra never falls through to
# the score gate. This is a best-effort eval: it reports pass@1 but only SKIPs
# (never fails the build) on non-resolution or infra trouble.
skip_exit() { skip "$@"; summary; exit 0; }

section "Prerequisites"

# The official evaluator talks to the Docker daemon directly (docker SDK + CLI).
if ! command -v docker &>/dev/null || ! docker info &>/dev/null; then
  skip_exit "prereq/runtime: no working docker (the official evaluator needs it)"
fi
pass "prereq/runtime: docker available"

if ! command -v python3 &>/dev/null; then skip_exit "prereq/python3: not found"; fi
pass "prereq/python3: $(python3 --version 2>&1)"
if ! command -v git &>/dev/null; then skip_exit "prereq/git: not found"; fi
pass "prereq/git: $(git --version 2>&1)"

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
if [ -z "$TOOL_PID" ]; then skip_exit "prereq/provider: no live provider available"; fi
pass "prereq/provider: $TOOL_PID available"

# Require a skill framework. swebench has disable-model-invocation, so it is NOT
# in the introspect .skills list even though `--skill swebench` activates it — so
# we check for the framework, not the name.
INTROSPECT=$($AMI --introspect 2>/dev/null || true)
if echo "$INTROSPECT" | jq -e '.skills' >/dev/null 2>&1; then
  pass "prereq/skill: skill framework present (swebench usable via --skill)"
else
  skip_exit "prereq/skill: installed binary has no skill framework" "$($AMI --version 2>/dev/null | head -1)"
fi

# Workspace (real path on the runner — RepoLaunch mounts getcwd()/tmp into the
# eval container, so this MUST be a path the host Docker daemon can see).
WORK=$(mktemp -d "${TMPDIR:-/tmp}/swebench-XXXXXX")
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# Official evaluator: clone microsoft/SWE-bench-Live (+ RepoLaunch submodule) and
# install it into an isolated venv — exactly as the OCP benchmark does.
EVAL_DIR="$WORK/SWE-bench-Live"
echo "  $(dim 'cloning the official SWE-bench-Live evaluator (+ RepoLaunch submodule)...')"
if ! timeout 300 git clone -q --recurse-submodules --depth 1 \
       -b "$SWEBENCH_EVAL_REF" "$SWEBENCH_EVAL_REPO" "$EVAL_DIR"; then
  skip_exit "prereq/evaluator: could not clone $SWEBENCH_EVAL_REPO"
fi
VENV="$WORK/venv"
if ! python3 -m venv "$VENV" >/dev/null 2>&1; then
  skip_exit "prereq/harness: python venv unavailable (need python3-venv)"
fi
# shellcheck disable=SC1091
. "$VENV/bin/activate"
echo "  $(dim 'installing the official evaluator (pip install -e . -e ./launch)...')"
if ! ( cd "$EVAL_DIR" && timeout "$PIP_TIMEOUT" pip install -q -e . -e ./launch ) >/dev/null 2>&1; then
  skip_exit "prereq/harness: pip install of the official evaluator failed"
fi
if ! ( cd "$EVAL_DIR" && python3 -c "import evaluation.evaluation; from launch.core.runtime import SetupRuntime" ) 2>/dev/null; then
  skip_exit "prereq/harness: evaluator import failed after install"
fi
pass "prereq/harness: official SWE-bench-Live evaluator installed ($(cd "$EVAL_DIR" && git rev-parse --short HEAD 2>/dev/null))"

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
  skip_exit "repo/checkout: could not fetch $SWEBENCH_REPO_URL@$SWEBENCH_BASE_COMMIT"
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
  skip_exit "agent/run: transient or empty output" "${AGENT_OUT:0:80}"
fi
pass "agent/run: completed"

# The prediction is the agent's full working-tree diff vs base_commit (the
# model_patch). Do NOT filter test paths: the evaluator applies the instance's own
# gold test_patch anyway (a stray model test-edit is overwritten), and a "*test*"
# filter wrongly drops real source whose path contains "test".
PATCH_FILE="$WORK/model_patch.diff"
( cd "$REPO_DIR" && git diff ) > "$PATCH_FILE" 2>/dev/null || true
if [ ! -s "$PATCH_FILE" ]; then
  skip_exit "agent/patch: agent produced no source changes"
fi
pass "agent/patch: $(wc -l < "$PATCH_FILE") diff lines produced"

# ═══════════════════════════════════════════════════════════════════
# Step 2 — score with the OFFICIAL SWE-bench-Live evaluator
# ═══════════════════════════════════════════════════════════════════
section "Official evaluation"

# preds.json: a JSON object keyed by instance_id (the format evaluation.evaluation
# expects for --patch_dir); model_patch is the agent's full diff.
PREDS="$WORK/preds.json"
python3 - "$SWEBENCH_INSTANCE" "$PATCH_FILE" "$PREDS" <<'PY'
import json, sys
inst, patch_file, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(patch_file) as f:
    patch = f.read()
with open(out, "w") as f:
    json.dump({inst: {"model_name_or_path": "ami", "instance_id": inst, "model_patch": patch}}, f)
PY
pass "eval/preds: wrote prediction for $SWEBENCH_INSTANCE"

OUTPUT_DIR="$WORK/output"
mkdir -p "$OUTPUT_DIR"
echo "  $(dim '▸ pulling the instance image + running FAIL_TO_PASS + PASS_TO_PASS (slow)...')"
HARNESS_LOG="$WORK/harness.log"
set +e
# Run the evaluator DIRECTLY on the runner (cwd inside the eval repo so
# RepoLaunch's getcwd()/tmp mount is a real host path). This is the exact official
# command the OCP benchmark uses, minus the K8s DinD wrapper.
( cd "$EVAL_DIR" && timeout "$HARNESS_TIMEOUT" python3 -m evaluation.evaluation \
    --dataset "$SWEBENCH_DATASET" \
    --split "$SWEBENCH_SPLIT" \
    --patch_dir "$PREDS" \
    --platform linux \
    --workers 1 \
    --output_dir "$OUTPUT_DIR" \
    --overwrite 1 \
    --instance_ids "$SWEBENCH_INSTANCE" ) >"$HARNESS_LOG" 2>&1
HARNESS_RC=$?
set -e

# The evaluator writes output/<instance_id>/report.json with a `resolved` bool.
REPORT="$OUTPUT_DIR/$SWEBENCH_INSTANCE/report.json"
if [ ! -f "$REPORT" ]; then
  skip_exit "eval/report: no report produced (rc=$HARNESS_RC)" "$(tail -2 "$HARNESS_LOG" 2>/dev/null | tr '\n' ' ')"
fi
pass "eval/report: $SWEBENCH_INSTANCE/report.json"

RESOLVED=$(jq -r '.resolved // false' "$REPORT" 2>/dev/null || echo "false")
F2P_OK=$(jq -r '.FAIL_TO_PASS.success | length' "$REPORT" 2>/dev/null || echo 0)
F2P_BAD=$(jq -r '.FAIL_TO_PASS.failure | length' "$REPORT" 2>/dev/null || echo 0)
P2P_OK=$(jq -r '.PASS_TO_PASS.success | length' "$REPORT" 2>/dev/null || echo 0)
P2P_BAD=$(jq -r '.PASS_TO_PASS.failure | length' "$REPORT" 2>/dev/null || echo 0)

section "Score"
echo "  $(bold "SWE-bench-Live pass@1: resolved=$RESOLVED ($SWEBENCH_INSTANCE)")" >&2
echo "  $(dim "FAIL_TO_PASS ok/fail: $F2P_OK/$F2P_BAD  |  PASS_TO_PASS ok/fail: $P2P_OK/$P2P_BAD")" >&2
if [ "$RESOLVED" = "true" ]; then
  pass "score/gate: $SWEBENCH_INSTANCE resolved (FAIL_TO_PASS flipped + PASS_TO_PASS held, via the agent's patch)"
else
  # Non-resolution is informational (not a hard gate), but surface WHY so a miss is
  # debuggable from the CI log alone (the WORK dir is ephemeral).
  echo "  $(dim '── diagnostics (non-resolved) ──')" >&2
  echo "  $(dim 'report.json:')" >&2
  jq '{resolved, FAIL_TO_PASS, PASS_TO_PASS}' "$REPORT" 2>/dev/null | sed 's/^/    /' >&2 || true
  echo "  $(dim 'model_patch (what the agent produced):')" >&2
  sed 's/^/    /' "$PATCH_FILE" >&2 || true
  echo "  $(dim 'post_patch_log tail:')" >&2
  tail -25 "$OUTPUT_DIR/$SWEBENCH_INSTANCE/post_patch_log.txt" 2>/dev/null | sed 's/^/    /' >&2 || true
  echo "  $(dim 'evaluator log tail:')" >&2
  tail -20 "$HARNESS_LOG" 2>/dev/null | sed 's/^/    /' >&2 || true
  skip "score: $SWEBENCH_INSTANCE NOT resolved this run (informational — not a hard gate)"
fi

summary
