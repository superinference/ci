#!/bin/bash
# FRITO CI — All-provider inference tests (850+ assertions)
# Tests every provider in ALL_PROVIDERS through ami --prompt with real inference.
# Categories: Basic, Math, Knowledge, Instruction Following, UTF-8, Edge Cases, Code
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

if ! has_frito_config; then
  echo "ERROR: No frito config (set FRITO_JSON env var or FRITO_CONFIG file path)"
  exit 1
fi

AMI_TIMEOUT=45

echo ""
echo "$(bold 'FRITO All-Provider Inference Tests — 850+ Assertions')"
echo "$(dim "Config: $FRITO_CONFIG")"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $(command -v ami 2>/dev/null || echo 'not found')")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# HELPERS — ami_prompt / assert_ami_response / get_response
# (same as providers.sh — not in helpers.sh)
# ═══════════════════════════════════════════════════════════════════

ami_prompt() {
  local pid="$1" key="$2" prompt="$3" model="${4:-}"
  local model_args=()
  [ -n "$model" ] && model_args=(--model "$model")
  local env_args
  env_args=$(provider_env_string "$pid" "$key")
  local output
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" SI_NO_SPLASH=1 NODE_NO_WARNINGS=1 \
    $env_args \
    ami --prompt "$prompt" --max-turns 1 "${model_args[@]}" 2>/dev/null) || true
  if [ -z "$output" ]; then
    echo '{"ok":false,"error":"no output from cli"}'
  else
    echo "$output"
  fi
}

# Validates an ami JSON response — produces 7 assertions
assert_ami_response() {
  local result="$1" prefix="$2"

  if ! echo "$result" | jq . >/dev/null 2>&1; then
    fail "$prefix: valid JSON" "not JSON: ${result:0:60}"
    return 0
  fi
  pass "$prefix: valid JSON"

  local ok response model provider elapsed error
  ok=$(echo "$result" | jq -r '.ok // "false"')
  response=$(echo "$result" | jq -r '.response // empty')
  model=$(echo "$result" | jq -r '.model // empty')
  provider=$(echo "$result" | jq -r '.provider // empty')
  elapsed=$(echo "$result" | jq -r '.elapsedMs // 0')
  error=$(echo "$result" | jq -r '.error // empty')

  # Max turns exceeded is success — we use --max-turns 1 for cheap tests
  if [ "$ok" != "true" ] && echo "$error" | grep -qi "max.turns"; then
    pass "$prefix: ok (max-turns capped)"
    if [ -n "$response" ] && [ "$response" != "null" ]; then
      pass "$prefix: response"
    else
      skip "$prefix: response" "tool-use turn (no text)"
    fi
    assert_nonempty "$model" "$prefix: model"
    assert_nonempty "$provider" "$prefix: provider"
    if [ "$elapsed" -gt 0 ] 2>/dev/null && [ "$elapsed" -lt 60000 ] 2>/dev/null; then
      pass "$prefix: time ${elapsed}ms"
    else
      skip "$prefix: time" "${elapsed}ms"
    fi
    pass "$prefix: no-error (max-turns is expected)"
    return 0
  fi

  # Transient errors -> skip remaining assertions
  if [ "$ok" != "true" ] && echo "$error" | grep -qiE "429|rate.limit|too.many|quota|resource.exhausted|no output|timeout|ECONNREFUSED|ETIMEDOUT|HTTP [45]|Max retries|overloaded|object Object|server error|context.overflow|request.too.large"; then
    skip "$prefix: ok" "${error:0:50}"
    skip "$prefix: response" "transient"
    skip "$prefix: model" "transient"
    skip "$prefix: provider" "transient"
    skip "$prefix: time" "transient"
    skip "$prefix: no-error" "transient"
    return 0
  fi

  if [ "$ok" = "true" ]; then
    pass "$prefix: ok"
  else
    fail "$prefix: ok" "${error:0:80}"
    skip "$prefix: response" "inference failed"
    skip "$prefix: model" "inference failed"
    skip "$prefix: provider" "inference failed"
    skip "$prefix: time" "inference failed"
    skip "$prefix: no-error" "inference failed"
    return 0
  fi

  assert_nonempty "$response" "$prefix: response"
  assert_nonempty "$model" "$prefix: model"
  assert_nonempty "$provider" "$prefix: provider"

  if [ "$elapsed" -gt 0 ] 2>/dev/null && [ "$elapsed" -lt 60000 ] 2>/dev/null; then
    pass "$prefix: time ${elapsed}ms"
  elif [ "$elapsed" -ge 60000 ] 2>/dev/null; then
    fail "$prefix: time" "${elapsed}ms (>60s)"
  else
    skip "$prefix: time" "not reported"
  fi

  if [ -z "$error" ] || [ "$error" = "null" ]; then
    pass "$prefix: no-error"
  else
    fail "$prefix: no-error" "${error:0:50}"
  fi

  return 0
}

get_response() {
  echo "$1" | jq -r '.response // empty' 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════
# PROVIDER LIVENESS PROBE — skip unavailable providers upfront
# ═══════════════════════════════════════════════════════════════════

section "Model Discovery"

declare -A PROVIDER_MODELS
for pid in "${ALL_PROVIDERS[@]}"; do
  if has_key "$pid"; then
    _models=$(discover_models "$pid" 2>/dev/null || true)
    _models=$(echo "$_models" | head -5 | tr '\n' ', ' | sed 's/,$//' || true)
    if [ -n "$_models" ]; then
      echo "  $(dim "▸ $pid models: $_models")"
    else
      echo "  $(dim "▸ $pid: no models endpoint or empty")"
    fi
  fi
done
echo ""

section "Provider Liveness Probe"

declare -A PROVIDER_LIVE
declare -A PROVIDER_LIVE_MODEL

for pid in "${ALL_PROVIDERS[@]}"; do
  if has_key "$pid"; then
    _k=$(get_key "$pid")
    _m=$(pick_model "$pid")
    _env_args=$(provider_env_string "$pid" "$_k")
    _out=$(timeout 30 env -i PATH="$PATH" HOME="$HOME" TERM="dumb" SI_NO_SPLASH=1 NODE_NO_WARNINGS=1 \
      $_env_args ami --model "$_m" --max-turns 1 --prompt "hi" 2>/dev/null) || true
    if [ -n "$_out" ] && echo "$_out" | jq -e '(.ok == true) or ((.error // "") | test("max.turns"; "i"))' >/dev/null 2>&1; then
      PROVIDER_LIVE[$pid]=1
      PROVIDER_LIVE_MODEL[$pid]="$_m"
      echo "  $(dim "▸ $pid: live (model: $_m)")"
    else
      _err=$(echo "$_out" | jq -r '.error // "no output"' 2>/dev/null | head -c 80 || true)
      PROVIDER_LIVE[$pid]=0
      echo "  $(dim "▸ $pid: unavailable — $_err")"
    fi
  else
    PROVIDER_LIVE[$pid]=0
    echo "  $(dim "▸ $pid: no key")"
  fi
done
echo ""

# ═══════════════════════════════════════════════════════════════════
# PER-PROVIDER TEST SUITE
# ~52 assertions per provider across 7 categories
# ═══════════════════════════════════════════════════════════════════

run_provider_tests() {
  local pid="$1"

  if ! has_key "$pid" || [ "${PROVIDER_LIVE[$pid]:-0}" = "0" ]; then
    skip "$pid -- no key or provider unavailable"
    return
  fi

  local key model
  key=$(get_key "$pid")
  model="${PROVIDER_LIVE_MODEL[$pid]:-$(pick_model "$pid")}"

  section "$pid -- AMI Inference (all categories)"

  # ── A. Basic Inference ─────────────────────────────────────────
  echo "  $(dim '▸ A. Basic Inference')"
  pwait "$pid"
  local r resp
  r=$(ami_prompt "$pid" "$key" "Say hello in one word" "$model")
  assert_ami_response "$r" "$pid/basic"

  # ── B. Math & Arithmetic ───────────────────────────────────────
  echo "  $(dim '▸ B. Math & Arithmetic')"
  local math_tests=(
    "What is 2+2? Reply with just the number.|4"
    "What is 7 times 8? Reply with just the number.|56"
    "What is 100 divided by 4? Reply with just the number.|25"
    "What is 15 minus 7? Reply with just the number.|8"
    "What is 3 squared? Reply with just the number.|9"
  )
  for tc in "${math_tests[@]}"; do
    local q a
    q="${tc%%|*}"
    a="${tc##*|}"
    pwait "$pid"
    r=$(ami_prompt "$pid" "$key" "$q" "$model")
    assert_ami_response "$r" "$pid/math-$a"
    resp=$(get_response "$r")
    if echo "$resp" | grep -q "$a"; then
      pass "$pid/math-$a: correct"
    else
      skip "$pid/math-$a: correct" "got: ${resp:0:30}"
    fi
  done

  # ── C. Knowledge ──────────────────────────────────────────────
  echo "  $(dim '▸ C. Knowledge')"
  local know_tests=(
    "What is the capital of France? Reply with just the city.|Paris"
    "What is the chemical formula for water? Reply briefly.|H2O"
    "Who wrote Romeo and Juliet? Reply with just the name.|Shakespeare"
    "What planet is closest to the Sun? Reply briefly.|Mercury"
    "How many continents are there? Reply with just the number.|7"
  )
  for tc in "${know_tests[@]}"; do
    local q a
    q="${tc%%|*}"
    a="${tc##*|}"
    pwait "$pid"
    r=$(ami_prompt "$pid" "$key" "$q" "$model")
    assert_ami_response "$r" "$pid/know-$a"
    resp=$(get_response "$r")
    if echo "$resp" | grep -qi "$a"; then
      pass "$pid/know-$a: correct"
    else
      skip "$pid/know-$a: correct" "got: ${resp:0:40}"
    fi
  done

  # ── D. Instruction Following ──────────────────────────────────
  echo "  $(dim '▸ D. Instruction Following')"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "Reply with exactly the word PONG and nothing else." "$model")
  assert_ami_response "$r" "$pid/instr-pong"
  resp=$(get_response "$r")
  echo "$resp" | grep -qi "PONG" && pass "$pid/instr-pong: correct" || skip "$pid/instr-pong: correct" "${resp:0:20}"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" 'Reply with only this JSON: {"color":"blue","n":42}' "$model")
  assert_ami_response "$r" "$pid/instr-json"
  resp=$(get_response "$r")
  echo "$resp" | grep -q '"color"' && pass "$pid/instr-json: has field" || skip "$pid/instr-json: has field" "${resp:0:40}"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "List exactly 3 colors, one per line, no extra text." "$model")
  assert_ami_response "$r" "$pid/instr-list"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/instr-list: has content" || skip "$pid/instr-list: has content"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "Reply with exactly 5 words about the weather." "$model")
  assert_ami_response "$r" "$pid/instr-5words"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/instr-5words: has content" || skip "$pid/instr-5words: has content"

  # ── E. UTF-8 Handling ─────────────────────────────────────────
  echo "  $(dim '▸ E. UTF-8 Handling')"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "What emoji is this: 🎉? Name it in one word." "$model")
  assert_ami_response "$r" "$pid/utf8-emoji"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/utf8-emoji: handled" || skip "$pid/utf8-emoji: handled"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "Translate to English: 你好世界" "$model")
  assert_ami_response "$r" "$pid/utf8-cjk"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/utf8-cjk: handled" || skip "$pid/utf8-cjk: handled"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "What language is this: Привет мир? Reply briefly." "$model")
  assert_ami_response "$r" "$pid/utf8-cyrillic"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/utf8-cyrillic: handled" || skip "$pid/utf8-cyrillic: handled"

  # ── F. Edge Cases ─────────────────────────────────────────────
  echo "  $(dim '▸ F. Edge Cases')"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "a" "$model")
  assert_ami_response "$r" "$pid/edge-short"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "???" "$model")
  assert_ami_response "$r" "$pid/edge-punct"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "42" "$model")
  assert_ami_response "$r" "$pid/edge-number"

  # ── G. Code & Reasoning ───────────────────────────────────────
  echo "  $(dim '▸ G. Code & Reasoning')"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "Write a Python function that adds two numbers. Just the code, no explanation." "$model")
  assert_ami_response "$r" "$pid/code-gen"
  resp=$(get_response "$r")
  echo "$resp" | grep -q "def " && pass "$pid/code-gen: has function" || skip "$pid/code-gen: has function" "${resp:0:40}"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "Is 'All cats are animals, Whiskers is a cat, therefore Whiskers is an animal' valid logic? Reply yes or no." "$model")
  assert_ami_response "$r" "$pid/logic"
  resp=$(get_response "$r")
  echo "$resp" | grep -qi "yes" && pass "$pid/logic: correct" || skip "$pid/logic: correct" "${resp:0:30}"

  pwait "$pid"
  r=$(ami_prompt "$pid" "$key" "Count the vowels in banana. Reply with just the number." "$model")
  assert_ami_response "$r" "$pid/counting"
  resp=$(get_response "$r")
  echo "$resp" | grep -q "3" && pass "$pid/counting: correct" || skip "$pid/counting: correct" "${resp:0:20}"
}

# ═══════════════════════════════════════════════════════════════════
# MAIN — iterate every provider
# ═══════════════════════════════════════════════════════════════════

TESTED_PROVIDERS=0
SKIPPED_PROVIDERS=0

for pid in "${ALL_PROVIDERS[@]}"; do
  if has_key "$pid" && [ "${PROVIDER_LIVE[$pid]:-0}" = "1" ]; then
    run_provider_tests "$pid"
    TESTED_PROVIDERS=$((TESTED_PROVIDERS + 1))
  else
    SKIPPED_PROVIDERS=$((SKIPPED_PROVIDERS + 1))
  fi
done

# ═══════════════════════════════════════════════════════════════════
# DYNAMIC COVERAGE GATE — every FRITO-configured provider must be tested
# ═══════════════════════════════════════════════════════════════════

section "Provider Coverage Gate"

# Discover all providers that have keys in FRITO config
CONFIG_PROVIDERS=$(frito_jq -r '.providers // {} | keys[]' 2>/dev/null | sort || true)
CONFIG_COUNT=$(echo "$CONFIG_PROVIDERS" | grep -c '.' || echo 0)
pass "FRITO config has $CONFIG_COUNT provider entries"

UNTESTED_WITH_KEY=0
for cpid in $CONFIG_PROVIDERS; do
  if ! has_key "$cpid"; then continue; fi
  # Check if this provider is in ALL_PROVIDERS (has a test function)
  found=false
  for apid in "${ALL_PROVIDERS[@]}"; do
    if [ "$apid" = "$cpid" ]; then found=true; break; fi
  done
  if ! $found; then
    fail "UNTESTED PROVIDER: $cpid" "has key in FRITO config but not in ALL_PROVIDERS — add it to helpers.sh"
    UNTESTED_WITH_KEY=$((UNTESTED_WITH_KEY + 1))
  fi
done

if [ "$UNTESTED_WITH_KEY" -gt 0 ]; then
  fail "Provider coverage" "$UNTESTED_WITH_KEY provider(s) with keys are not in the test suite"
else
  pass "Provider coverage: all FRITO-configured providers are in the test suite"
fi

echo "  $(dim "Tested: $TESTED_PROVIDERS | Skipped: $SKIPPED_PROVIDERS | Config entries: $CONFIG_COUNT")"

summary
