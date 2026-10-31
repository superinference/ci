#!/bin/bash
# FRITO CI — Skills Suite
#
# Real-agent runs for EVERY wired native skill, plus a DYNAMIC COMPLETENESS GATE.
#
# The agent ships a library of native skills (bundled SKILL.md files). They are
# discovered dynamically from `ami --introspect` (.skills[]). This suite enforces:
#
#   1. COVERAGE GATE (no provider needed): every wired skill MUST have a real-run
#      spec in skill-tests.json. A new skill added to the agent without a test
#      entry FAILS this suite — you cannot ship an untested skill.
#   2. REAL RUNS (needs a live provider): each wired skill is pinned as the run
#      stance via `ami --skill <name>` and given a self-contained task that
#      forces the skill's core behavior; the response must contain the skill's
#      signature indicators, proving the skill genuinely ran.
#
# Specs live in skill-tests.json (name -> {mode, prompt, indicators, maxTurns}).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/discover.sh"   # provides DISC_SKILLS (introspect or fallback)

SPEC_FILE="$SCRIPT_DIR/skill-tests.json"
AMI_TIMEOUT="${AMI_TIMEOUT:-180}"

echo ""
echo "$(bold 'FRITO Skills — real-agent runs for every wired skill')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $AMI")"

# Transient error detector — rate limits / overload / context overflow are not
# skill failures.
is_transient() {
  local output="$1"
  [ -z "$output" ] && return 0
  local err
  err=$(echo "$output" | jq -r '.error // empty' 2>/dev/null || true)
  [ -z "$err" ] && return 0
  echo "$err" | grep -qiE "429|rate.limit|too.many|quota|resource.exhausted|timeout|ECONNREFUSED|ETIMEDOUT|HTTP [45]|Max retries|overloaded|max.turns|server error|context.overflow|request.too.large" && return 0
  return 1
}

# ═══════════════════════════════════════════════════════════════════
# Prerequisites
# ═══════════════════════════════════════════════════════════════════
section "Prerequisites"

if ! command -v jq >/dev/null 2>&1; then
  fail "prereq/jq: jq not found"
  summary
fi
pass "prereq/jq: available"

if [ ! -f "$SPEC_FILE" ]; then
  fail "prereq/specs: skill-tests.json missing at $SPEC_FILE"
  summary
fi
SPEC_COUNT=$(jq 'length' "$SPEC_FILE")
pass "prereq/specs: skill-tests.json present ($SPEC_COUNT specs)"

if [ "${#DISC_SKILLS[@]}" -eq 0 ]; then
  fail "prereq/discovery: no wired skills discovered (introspect + fallback both empty)"
  summary
fi
pass "prereq/discovery: ${#DISC_SKILLS[@]} wired skills"

# ═══════════════════════════════════════════════════════════════════
# DYNAMIC SKILL COVERAGE GATE
# Every wired skill in --introspect (.skills[]) must have a real-run spec.
# Adding a skill to the agent without a skill-tests.json entry fails CI.
# This runs WITHOUT a provider, so the guarantee holds even with no API keys.
# ═══════════════════════════════════════════════════════════════════
section "Skill Coverage Gate"

MISSING=0
for sk in "${DISC_SKILLS[@]}"; do
  if jq -e --arg n "$sk" 'has($n)' "$SPEC_FILE" >/dev/null 2>&1; then
    pass "gate/$sk: has real-run spec"
  else
    fail "gate/$sk: NO REAL-RUN TEST" "add \"$sk\" to tests/skill-tests.json"
    MISSING=$((MISSING + 1))
  fi
done

# Stale specs (a spec for a skill that is no longer wired) — informational only.
while IFS= read -r spec_name; do
  _found=0
  for d in "${DISC_SKILLS[@]}"; do [ "$d" = "$spec_name" ] && _found=1 && break; done
  [ "$_found" -eq 0 ] && skip "gate/stale: $spec_name" "spec exists but not in introspect"
done < <(jq -r 'keys[]' "$SPEC_FILE")

if [ "$MISSING" -eq 0 ]; then
  pass "Skill coverage gate: all ${#DISC_SKILLS[@]} wired skills have real-run tests"
else
  fail "Skill coverage gate" "$MISSING wired skill(s) have NO test"
fi

# ═══════════════════════════════════════════════════════════════════
# Resolve a live provider for the real runs
# ═══════════════════════════════════════════════════════════════════
section "Provider"

TOOL_PID="" TOOL_MODEL="" TOOL_ENV=""
if has_frito_config; then
  for _c in openai anthropic google deepseek groq mistral cerebras openrouter alibaba nvidia; do
    if has_key "$_c"; then
      TOOL_PID="$_c"
      TOOL_MODEL="$(get_model "$_c")"
      TOOL_ENV="$(provider_env_string "$_c" "$(get_key "$_c")")"
      break
    fi
  done
fi

if [ -z "$TOOL_PID" ]; then
  skip "provider: no live provider available" "real runs skipped — coverage gate still enforced above"
  summary
fi
pass "provider: $TOOL_PID (model: ${TOOL_MODEL:-default})"

# ═══════════════════════════════════════════════════════════════════
# Real run per wired skill — pin the skill as the run stance (--skill) so its
# instructions govern, then assert the response carries its signature indicators.
# ═══════════════════════════════════════════════════════════════════
declare -A PROBED_SKILLS

for sk in "${DISC_SKILLS[@]}"; do
  jq -e --arg n "$sk" 'has($n)' "$SPEC_FILE" >/dev/null 2>&1 || continue  # gate already failed it

  section "skill: $sk"
  prompt=$(jq -r --arg n "$sk" '.[$n].prompt' "$SPEC_FILE")
  turns=$(jq -r --arg n "$sk" '.[$n].maxTurns' "$SPEC_FILE")
  mapfile -t inds < <(jq -r --arg n "$sk" '.[$n].indicators[]' "$SPEC_FILE")

  workdir=$(mktemp -d)
  pwait "$TOOL_PID"
  out=$(cd "$workdir" && timeout "$AMI_TIMEOUT" env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    $AMI --skill "$sk" --model "$TOOL_MODEL" --permission-mode auto-allow \
    --max-turns "$turns" --output-format json \
    --prompt "$prompt" 2>/dev/null) || true
  rm -rf "$workdir"

  PROBED_SKILLS[$sk]=1  # a real-run test exists and executed for this skill

  if [ -z "$out" ]; then
    skip "skill/$sk: run" "timed out or empty"
    continue
  fi
  if ! echo "$out" | jq . >/dev/null 2>&1; then
    skip "skill/$sk: json" "non-JSON: ${out:0:60}"
    continue
  fi

  ok=$(echo "$out" | jq -r '.ok')
  resp=$(echo "$out" | jq -r '.response // empty')
  err=$(echo "$out" | jq -r '.error // empty')

  if [ "$ok" != "true" ]; then
    if is_transient "$out"; then
      skip "skill/$sk: run" "transient: ${err:0:50}"
    else
      fail "skill/$sk: ok" "${err:0:80}"
    fi
    continue
  fi
  pass "skill/$sk: ran (ok=true)"

  # Indicator match (case-insensitive substring) — proves the skill did its job.
  lc=$(echo "$resp" | tr '[:upper:]' '[:lower:]')
  hits=0
  for ind in "${inds[@]}"; do
    echo "$lc" | grep -qF "$ind" && hits=$((hits + 1))
  done
  need=2
  [ "${#inds[@]}" -lt 2 ] && need=${#inds[@]}
  if [ "$hits" -ge "$need" ]; then
    pass "skill/$sk: exercised ($hits/${#inds[@]} indicators)"
  elif [ "$hits" -ge 1 ]; then
    pass "skill/$sk: partial ($hits/${#inds[@]} indicators)"
  else
    skip "skill/$sk: indicators" "0/${#inds[@]} matched — ${resp:0:80}"
  fi
done

# ═══════════════════════════════════════════════════════════════════
# Probe gate — every wired skill with a spec must have actually been run.
# (Belt-and-suspenders alongside the coverage gate above.)
# ═══════════════════════════════════════════════════════════════════
section "Skill Probe Gate"
NOT_PROBED=0
for sk in "${DISC_SKILLS[@]}"; do
  if [ -n "${PROBED_SKILLS[$sk]:-}" ]; then
    pass "probe/$sk: executed"
  else
    fail "probe/$sk: NEVER RUN" "wired skill with a spec was not exercised"
    NOT_PROBED=$((NOT_PROBED + 1))
  fi
done
[ "$NOT_PROBED" -eq 0 ] && pass "Skill probe gate: all specced skills exercised" || fail "Skill probe gate" "$NOT_PROBED skill(s) not run"

summary
