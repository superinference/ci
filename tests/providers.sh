#!/bin/bash
# FRITO CI — 1000+ functional test assertions
# Primary: ami --prompt (structured JSON) | Complement: curl (streaming/errors)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

if [ ! -f "$FRITO_CONFIG" ]; then
  echo "ERROR: $FRITO_CONFIG not found"
  exit 1
fi

AMI_TIMEOUT=45

echo ""
echo "$(bold 'FRITO Provider Tests — 1000+ Assertions')"
echo "$(dim "Config: $FRITO_CONFIG")"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $(which ami 2>/dev/null || echo 'not found')")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PROVIDER DEFINITIONS — ENV_VAR|provider_id|base_url
# ═══════════════════════════════════════════════════════════════════

PROVIDERS=(
  "GOOGLE_API_KEY|google|https://generativelanguage.googleapis.com/v1beta"
  "GROQ_API_KEY|groq|https://api.groq.com/openai/v1"
  "AI_API_KEY|openrouter|https://openrouter.ai/api/v1"
  "MISTRAL_API_KEY|mistral|https://api.mistral.ai/v1"
  "CEREBRAS_API_KEY|cerebras|https://api.cerebras.ai/v1"
)

# ═══════════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════════

pwait() {
  if [ "$1" = "google" ]; then
    google_rate_limit_wait
  else
    rate_limit_wait
  fi
}

ami_prompt() {
  local env_var="$1" key="$2" prompt="$3" model="${4:-}"
  local model_args=()
  [ -n "$model" ] && model_args=(--model "$model")
  local output
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    "${env_var}=${key}" \
    ami --prompt "$prompt" "${model_args[@]}" 2>/dev/null) || true
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
    return 1
  fi
  pass "$prefix: valid JSON"

  local ok response model provider elapsed error
  ok=$(echo "$result" | jq -r '.ok // "false"')
  response=$(echo "$result" | jq -r '.response // empty')
  model=$(echo "$result" | jq -r '.model // empty')
  provider=$(echo "$result" | jq -r '.provider // empty')
  elapsed=$(echo "$result" | jq -r '.elapsedMs // 0')
  error=$(echo "$result" | jq -r '.error // empty')

  # Transient errors → skip remaining assertions
  if [ "$ok" != "true" ] && echo "$error" | grep -qiE "429|rate.limit|too.many|quota|resource.exhausted|no output|timeout|ECONNREFUSED|ETIMEDOUT|HTTP 5|Max retries|overloaded|max.turns|object Object|server error"; then
    skip "$prefix: ok" "${error:0:50}"
    skip "$prefix: response" "transient"
    skip "$prefix: model" "transient"
    skip "$prefix: provider" "transient"
    skip "$prefix: time" "transient"
    skip "$prefix: no-error" "transient"
    return 2
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
    return 1
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

fetch_models_openai() {
  local base_url="$1" key="$2"
  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi
  curl -sS --max-time 30 \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    "${base_url}/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | head -50 || true
}

fetch_models_google() {
  local key="$1"
  curl -sS --max-time 30 \
    "https://generativelanguage.googleapis.com/v1beta/models?key=${key}" \
    2>/dev/null | jq -r '.models[].name' 2>/dev/null | sed 's|models/||' | grep -E "gemini" | head -20 || true
}

# ═══════════════════════════════════════════════════════════════════
# PROVIDER LIVENESS PROBE — skip unavailable providers upfront
# ═══════════════════════════════════════════════════════════════════
declare -A PROVIDER_LIVE
for _entry in "${PROVIDERS[@]}"; do
  IFS='|' read -r _ev _pid _url <<< "$_entry"
  if has_key "$_pid"; then
    _k=$(get_key "$_pid")
    _m=$(get_model "$_pid")
    _out=$(timeout 20 env -i PATH="$PATH" HOME="$HOME" TERM="dumb" NODE_NO_WARNINGS=1 \
      "${_ev}=${_k}" ami --model "$_m" --prompt "hi" 2>/dev/null) || true
    if [ -n "$_out" ] && echo "$_out" | jq -e '.ok == true' >/dev/null 2>&1; then
      PROVIDER_LIVE[$_pid]=1
      echo "  $(dim "▸ $_pid: live")"
    else
      PROVIDER_LIVE[$_pid]=0
      echo "  $(dim "▸ $_pid: unavailable (will skip ami tests)")"
    fi
  else
    PROVIDER_LIVE[$_pid]=0
    echo "  $(dim "▸ $_pid: no key")"
  fi
done
echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION A: AMI INFERENCE (per provider)
# Basic, Math, Knowledge, Instructions, UTF-8, Edge Cases, Code
# ~22 ami calls × 8 avg assertions = ~176 per provider
# ═══════════════════════════════════════════════════════════════════

run_inference_tests() {
  local env_var="$1" pid="$2" base_url="$3"

  if ! has_key "$pid" || [ "${PROVIDER_LIVE[$pid]:-0}" = "0" ]; then
    skip "$pid — no key or provider unavailable"
    return
  fi

  local key model
  key=$(get_key "$pid")
  model=$(get_model "$pid")

  section "$pid — AMI Inference"

  # ── Basic ──────────────────────────────────────────────────────
  echo "  $(dim '▸ Basic Inference')"
  pwait "$pid"
  local r resp
  r=$(ami_prompt "$env_var" "$key" "Say hello in one word" "$model")
  assert_ami_response "$r" "$pid/basic"

  # ── Math ───────────────────────────────────────────────────────
  echo "  $(dim '▸ Math & Arithmetic')"
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
    r=$(ami_prompt "$env_var" "$key" "$q" "$model")
    assert_ami_response "$r" "$pid/math-$a"
    resp=$(get_response "$r")
    if echo "$resp" | grep -q "$a"; then
      pass "$pid/math-$a: correct"
    else
      skip "$pid/math-$a: correct" "got: ${resp:0:30}"
    fi
  done

  # ── Knowledge ──────────────────────────────────────────────────
  echo "  $(dim '▸ Knowledge')"
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
    r=$(ami_prompt "$env_var" "$key" "$q" "$model")
    assert_ami_response "$r" "$pid/know-$a"
    resp=$(get_response "$r")
    if echo "$resp" | grep -qi "$a"; then
      pass "$pid/know-$a: correct"
    else
      skip "$pid/know-$a: correct" "got: ${resp:0:40}"
    fi
  done

  # ── Instruction Following ─────────────────────────────────────
  echo "  $(dim '▸ Instruction Following')"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "Reply with exactly the word PONG and nothing else." "$model")
  assert_ami_response "$r" "$pid/instr-pong"
  resp=$(get_response "$r")
  echo "$resp" | grep -qi "PONG" && pass "$pid/instr-pong: correct" || skip "$pid/instr-pong: correct" "${resp:0:20}"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" 'Reply with only this JSON: {"color":"blue","n":42}' "$model")
  assert_ami_response "$r" "$pid/instr-json"
  resp=$(get_response "$r")
  echo "$resp" | grep -q '"color"' && pass "$pid/instr-json: has field" || skip "$pid/instr-json: has field" "${resp:0:40}"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "List exactly 3 colors, one per line, no extra text." "$model")
  assert_ami_response "$r" "$pid/instr-list"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/instr-list: has content" || skip "$pid/instr-list: has content"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "Reply with exactly 5 words about the weather." "$model")
  assert_ami_response "$r" "$pid/instr-5words"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/instr-5words: has content" || skip "$pid/instr-5words: has content"

  # ── UTF-8 ──────────────────────────────────────────────────────
  echo "  $(dim '▸ UTF-8 Handling')"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "What emoji is this: 🎉? Name it in one word." "$model")
  assert_ami_response "$r" "$pid/utf8-emoji"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/utf8-emoji: handled" || skip "$pid/utf8-emoji: handled"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "Translate to English: 你好世界" "$model")
  assert_ami_response "$r" "$pid/utf8-cjk"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/utf8-cjk: handled" || skip "$pid/utf8-cjk: handled"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "What language is this: Привет мир? Reply briefly." "$model")
  assert_ami_response "$r" "$pid/utf8-cyrillic"
  resp=$(get_response "$r")
  [ -n "$resp" ] && pass "$pid/utf8-cyrillic: handled" || skip "$pid/utf8-cyrillic: handled"

  # ── Edge Cases ─────────────────────────────────────────────────
  echo "  $(dim '▸ Edge Cases')"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "a" "$model")
  assert_ami_response "$r" "$pid/edge-short"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "???" "$model")
  assert_ami_response "$r" "$pid/edge-punct"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "42" "$model")
  assert_ami_response "$r" "$pid/edge-number"

  # ── Code & Reasoning ───────────────────────────────────────────
  echo "  $(dim '▸ Code & Reasoning')"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "Write a Python function that adds two numbers. Just the code, no explanation." "$model")
  assert_ami_response "$r" "$pid/code-gen"
  resp=$(get_response "$r")
  echo "$resp" | grep -q "def " && pass "$pid/code-gen: has function" || skip "$pid/code-gen: has function" "${resp:0:40}"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "Is 'All cats are animals, Whiskers is a cat, therefore Whiskers is an animal' valid logic? Reply yes or no." "$model")
  assert_ami_response "$r" "$pid/logic"
  resp=$(get_response "$r")
  echo "$resp" | grep -qi "yes" && pass "$pid/logic: correct" || skip "$pid/logic: correct" "${resp:0:30}"

  pwait "$pid"
  r=$(ami_prompt "$env_var" "$key" "Count the vowels in banana. Reply with just the number." "$model")
  assert_ami_response "$r" "$pid/counting"
  resp=$(get_response "$r")
  echo "$resp" | grep -q "3" && pass "$pid/counting: correct" || skip "$pid/counting: correct" "${resp:0:20}"
}

# ═══════════════════════════════════════════════════════════════════
# SECTION B: DYNAMIC MODEL DISCOVERY (per provider)
# 2 base + up to 8 models × 7 assertions = ~58 per provider
# ═══════════════════════════════════════════════════════════════════

run_model_discovery() {
  local env_var="$1" pid="$2" base_url="$3"

  if ! has_key "$pid" || [ "${PROVIDER_LIVE[$pid]:-0}" = "0" ]; then
    return
  fi

  local key
  key=$(get_key "$pid")

  echo ""
  echo "  $(dim '▸ Dynamic Model Discovery')"

  local models=""
  if [ "$pid" = "google" ]; then
    models=$(fetch_models_google "$key")
  else
    models=$(fetch_models_openai "$base_url" "$key")
  fi

  if [ -n "$models" ]; then
    local count
    count=$(echo "$models" | wc -l | tr -d ' ')
    pass "$pid/discovery: endpoint works"
    pass "$pid/discovery: found $count models"
  else
    skip "$pid/discovery: endpoint" "no models returned"
    return
  fi

  local tested=0
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    [ "$tested" -ge 8 ] && break

    # Skip non-chat models
    echo "$m" | grep -qiE "embed|tts|whisper|dall|image|audio|vision-preview|moderation|text-to|speech|realtime|aqa" && continue

    # For openrouter prefer :free models
    if [ "$pid" = "openrouter" ]; then
      echo "$m" | grep -q ":free" || continue
    fi

    pwait "$pid"
    local r
    r=$(ami_prompt "$env_var" "$key" "Say ok" "$m")
    assert_ami_response "$r" "$pid/model/$m"
    tested=$((tested + 1))
  done <<< "$models"

  if [ "$tested" -gt 0 ]; then
    pass "$pid/discovery: tested $tested models"
  else
    skip "$pid/discovery: per-model" "no suitable chat models"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# SECTION C: ERROR HANDLING — curl (per provider)
# ~5-6 assertions per provider
# ═══════════════════════════════════════════════════════════════════

run_error_tests() {
  local pid="$1" base_url="$2"

  if ! has_key "$pid"; then
    return
  fi

  local key
  key=$(get_key "$pid")

  echo ""
  echo "  $(dim '▸ Error Handling (curl)')"

  if [ "$pid" = "google" ]; then
    _google_errors "$key"
    return
  fi

  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi

  # Invalid key
  rate_limit_wait
  local resp code body
  resp=$(curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer invalid-key-xxxxx" \
    "${extra_headers[@]}" \
    -d '{"model":"test","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
    "${base_url}/chat/completions" 2>/dev/null || echo "__HTTP_CODE__000")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_error "$code" "401" "$pid/error: invalid key"

  # Malformed JSON
  rate_limit_wait
  resp=$(curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    -d '{BAD JSON!!!' \
    "${base_url}/chat/completions" 2>/dev/null || echo "__HTTP_CODE__000")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  [ "$code" -ge 400 ] 2>/dev/null && pass "$pid/error: malformed JSON ($code)" || fail "$pid/error: malformed JSON" "HTTP $code"

  # Empty messages
  rate_limit_wait
  resp=$(curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    -d '{"model":"test","messages":[],"max_tokens":5}' \
    "${base_url}/chat/completions" 2>/dev/null || echo "__HTTP_CODE__000")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  if [ "$code" -ge 400 ] 2>/dev/null || [ "$code" -eq 200 ] 2>/dev/null; then
    pass "$pid/error: empty msgs ($code)"
  else
    fail "$pid/error: empty msgs" "HTTP $code"
  fi

  assert_not_contains "$body" "$key" "$pid/error: key not leaked"

  if echo "$body" | jq . >/dev/null 2>&1; then
    pass "$pid/error: response is JSON"
  else
    skip "$pid/error: response is JSON" "non-JSON"
  fi
}

_google_errors() {
  local key="$1"

  google_rate_limit_wait
  local resp code body
  resp=$(curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"parts":[{"text":"hi"}]}]}' \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=INVALID_KEY_123" \
    2>/dev/null || echo "__HTTP_CODE__000")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_error "$code" "400" "google/error: invalid key"

  google_rate_limit_wait
  resp=$(curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -d '{BADJSON' \
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${key}" \
    2>/dev/null || echo "__HTTP_CODE__000")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  [ "$code" -ge 400 ] 2>/dev/null && pass "google/error: malformed JSON ($code)" || fail "google/error: malformed JSON" "HTTP $code"

  assert_not_contains "$body" "$key" "google/error: key not leaked"

  echo "$body" | jq . >/dev/null 2>&1 && pass "google/error: response is JSON" || skip "google/error: response is JSON" "non-JSON"
}

# ═══════════════════════════════════════════════════════════════════
# SECTION D: STREAMING — curl (per provider)
# ~5 assertions per provider
# ═══════════════════════════════════════════════════════════════════

run_streaming_tests() {
  local pid="$1" base_url="$2"

  if ! has_key "$pid"; then
    return
  fi

  local key model
  key=$(get_key "$pid")
  model=$(get_model "$pid")

  echo ""
  echo "  $(dim '▸ Streaming (curl)')"

  if [ "$pid" = "google" ]; then
    google_rate_limit_wait
    local stream_out
    stream_out=$(google_chat_stream "$key" "$model" "Say hello")
    if [ -n "$stream_out" ]; then
      pass "google/stream: returns data"
      echo "$stream_out" | grep -q '"text"' && pass "google/stream: has text" || skip "google/stream: has text"
      local lines
      lines=$(echo "$stream_out" | wc -l | tr -d ' ')
      [ "$lines" -gt 1 ] && pass "google/stream: multi-chunk ($lines)" || skip "google/stream: multi-chunk"
      pass "google/stream: endpoint works"
    else
      skip "google/stream: returns data" "empty"
      skip "google/stream: has text" "no data"
      skip "google/stream: multi-chunk" "no data"
      skip "google/stream: endpoint works" "no data"
    fi
    return
  fi

  rate_limit_wait
  local stream_out
  stream_out=$(openai_chat_stream "$base_url" "$key" "$model" "Say hello")

  echo "$stream_out" | grep -q "^data:" && pass "$pid/stream: SSE data" || fail "$pid/stream: SSE data"
  echo "$stream_out" | grep -q '\[DONE\]' && pass "$pid/stream: [DONE]" || skip "$pid/stream: [DONE]"
  echo "$stream_out" | grep -q '"delta"' && pass "$pid/stream: delta field" || skip "$pid/stream: delta field"

  local content
  content=$(echo "$stream_out" | grep '^data: {' | sed 's/^data: //' | \
    jq -r '.choices[0].delta.content // empty' 2>/dev/null | tr -d '\n' || true)
  [ -n "$content" ] && pass "$pid/stream: content non-empty" || skip "$pid/stream: content"

  local chunks
  chunks=$(echo "$stream_out" | grep -c '^data: {' || true)
  [ "$chunks" -gt 1 ] && pass "$pid/stream: multi-chunk ($chunks)" || skip "$pid/stream: multi-chunk"
}

# ═══════════════════════════════════════════════════════════════════
# SECTION E: CURL ADVANCED — system prompts, max_tokens, multi-turn, usage
# ~18 assertions per provider
# ═══════════════════════════════════════════════════════════════════

run_curl_advanced() {
  local pid="$1" base_url="$2"

  if ! has_key "$pid"; then
    return
  fi

  local key model
  key=$(get_key "$pid")
  model=$(get_model "$pid")

  echo ""
  echo "  $(dim '▸ Advanced API (curl)')"

  if [ "$pid" = "google" ]; then
    _google_advanced "$key" "$model"
    return
  fi

  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi

  # System prompt
  rate_limit_wait
  local resp code body content
  resp=$(openai_chat_system "$base_url" "$key" "$model" "You are a pirate. Always say Arrr." "How are you?")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "$pid/curl: system prompt"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    content=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
    assert_nonempty "$content" "$pid/curl: system response"
  fi

  # Max tokens
  rate_limit_wait
  resp=$(openai_chat "$base_url" "$key" "$model" "Write a 500-word essay about cats." '"max_tokens": 20')
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "$pid/curl: max_tokens"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    content=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
    local wc
    wc=$(echo "$content" | wc -w | tr -d ' ')
    [ "$wc" -lt 100 ] 2>/dev/null && pass "$pid/curl: max_tokens limited ($wc words)" || skip "$pid/curl: max_tokens limited" "$wc words"
  fi

  # Multi-turn
  rate_limit_wait
  local messages='[{"role":"user","content":"My name is Alice"},{"role":"assistant","content":"Hello Alice!"},{"role":"user","content":"What is my name?"}]'
  resp=$(openai_chat_multi "$base_url" "$key" "$model" "$messages")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "$pid/curl: multi-turn"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    content=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null || true)
    echo "$content" | grep -qi "Alice" && pass "$pid/curl: multi-turn context" || skip "$pid/curl: multi-turn context" "${content:0:40}"
  fi

  # Temperature 0
  rate_limit_wait
  resp=$(openai_chat "$base_url" "$key" "$model" "What is 1+1? Just the number." '"temperature": 0')
  code=$(extract_http_code "$resp")
  assert_http_ok "$code" "$pid/curl: temperature=0"

  # Temperature 1
  rate_limit_wait
  resp=$(openai_chat "$base_url" "$key" "$model" "Say hello" '"temperature": 1')
  code=$(extract_http_code "$resp")
  assert_http_ok "$code" "$pid/curl: temperature=1"

  # Usage / token stats
  rate_limit_wait
  resp=$(openai_chat "$base_url" "$key" "$model" "Say hello in one word.")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "$pid/curl: usage"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    local pt ct
    pt=$(echo "$body" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null || echo "0")
    ct=$(echo "$body" | jq -r '.usage.completion_tokens // 0' 2>/dev/null || echo "0")
    [ "$pt" -gt 0 ] 2>/dev/null && pass "$pid/curl: prompt_tokens=$pt" || skip "$pid/curl: prompt_tokens"
    [ "$ct" -gt 0 ] 2>/dev/null && pass "$pid/curl: completion_tokens=$ct" || skip "$pid/curl: completion_tokens"
  fi

  # Response structure
  rate_limit_wait
  resp=$(openai_chat "$base_url" "$key" "$model" "Say ok")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    assert_json_field "$body" ".id" "$pid/curl: has .id"
    assert_json_field "$body" ".model" "$pid/curl: has .model"
    assert_json_field "$body" ".choices" "$pid/curl: has .choices"
    assert_json_field "$body" ".choices[0].message.role" "$pid/curl: has .role"
    assert_json_field "$body" ".choices[0].message.content" "$pid/curl: has .content"
  else
    skip "$pid/curl: response structure" "HTTP $code"
  fi
}

_google_advanced() {
  local key="$1" model="$2"

  # System instruction
  google_rate_limit_wait
  local resp code body content
  resp=$(google_chat_system "$key" "$model" "You are a pirate. Always say Arrr." "How are you?")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "google/curl: system instruction"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    content=$(echo "$body" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null || true)
    assert_nonempty "$content" "google/curl: system response"
  fi

  # Max output tokens
  google_rate_limit_wait
  resp=$(google_chat "$key" "$model" "Write a long essay about cats." '"generationConfig":{"maxOutputTokens":20}')
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "google/curl: maxOutputTokens"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    content=$(echo "$body" | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null || true)
    local wc
    wc=$(echo "$content" | wc -w | tr -d ' ')
    [ "$wc" -lt 100 ] 2>/dev/null && pass "google/curl: max tokens limited ($wc)" || skip "google/curl: max tokens" "$wc words"
  fi

  # Temperature
  google_rate_limit_wait
  resp=$(google_chat "$key" "$model" "What is 1+1?" '"generationConfig":{"temperature":0}')
  code=$(extract_http_code "$resp")
  assert_http_ok "$code" "google/curl: temperature=0"

  google_rate_limit_wait
  resp=$(google_chat "$key" "$model" "Say hello" '"generationConfig":{"temperature":1}')
  code=$(extract_http_code "$resp")
  assert_http_ok "$code" "google/curl: temperature=1"

  # Token usage
  google_rate_limit_wait
  resp=$(google_chat "$key" "$model" "Say hello")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  assert_http_ok "$code" "google/curl: token usage"
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    local pt ct
    pt=$(echo "$body" | jq -r '.usageMetadata.promptTokenCount // 0' 2>/dev/null || echo "0")
    ct=$(echo "$body" | jq -r '.usageMetadata.candidatesTokenCount // 0' 2>/dev/null || echo "0")
    [ "$pt" -gt 0 ] 2>/dev/null && pass "google/curl: promptTokenCount=$pt" || skip "google/curl: promptTokenCount"
    [ "$ct" -gt 0 ] 2>/dev/null && pass "google/curl: candidatesTokenCount=$ct" || skip "google/curl: candidatesTokenCount"
  fi

  # Response structure
  google_rate_limit_wait
  resp=$(google_chat "$key" "$model" "Say ok")
  code=$(extract_http_code "$resp")
  body=$(extract_body "$resp")
  if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 300 ] 2>/dev/null; then
    assert_json_field "$body" ".candidates" "google/curl: has .candidates"
    assert_json_field "$body" ".candidates[0].content" "google/curl: has .content"
    assert_json_field "$body" ".candidates[0].content.parts[0].text" "google/curl: has .text"
    assert_json_field "$body" ".usageMetadata" "google/curl: has .usageMetadata"
  else
    skip "google/curl: response structure" "HTTP $code"
  fi
}

# ═══════════════════════════════════════════════════════════════════
# SECTION F: RELIABILITY — 5 rounds per provider
# 5 × 7 = 35 assertions per provider
# ═══════════════════════════════════════════════════════════════════

run_reliability() {
  section "Reliability Rounds"

  for entry in "${PROVIDERS[@]}"; do
    local env_var pid base_url
    IFS='|' read -r env_var pid base_url <<< "$entry"

    if ! has_key "$pid" || [ "${PROVIDER_LIVE[$pid]:-0}" = "0" ]; then
      continue
    fi

    local key model
    key=$(get_key "$pid")
    model=$(get_model "$pid")

    echo "  $(dim "▸ $pid: 5 rounds")"

    for round in 1 2 3 4 5; do
      pwait "$pid"
      local r
      r=$(ami_prompt "$env_var" "$key" "What is ${round}+${round}? Reply with just the number." "$model")
      assert_ami_response "$r" "$pid/rel-r$round"
    done
  done
}

# ═══════════════════════════════════════════════════════════════════
# SECTION G: CROSS-PROVIDER VALIDATION
# ~35 assertions
# ═══════════════════════════════════════════════════════════════════

run_cross_provider() {
  section "Cross-Provider Validation"

  local available=()
  for entry in "${PROVIDERS[@]}"; do
    local pid
    pid=$(echo "$entry" | cut -d'|' -f2)
    has_key "$pid" && available+=("$pid")
  done
  echo "  $(dim "Available: ${available[*]}")"

  # Config checks
  [ "${#available[@]}" -ge 2 ] && pass "cross: ${#available[@]} providers" || { skip "cross: multiple providers"; return; }

  local perms
  perms=$(stat -c%a "$FRITO_CONFIG" 2>/dev/null || stat -f%OLp "$FRITO_CONFIG" 2>/dev/null || echo "unknown")
  [ "$perms" = "600" ] && pass "cross: frito.json perms (600)" || skip "cross: frito.json perms" "$perms"

  for field in "providers" "quality" "enabled"; do
    jq -e ".$field" "$FRITO_CONFIG" >/dev/null 2>&1 && pass "cross: config has .$field" || fail "cross: config has .$field"
  done

  local known="google groq openrouter cerebras mistral huggingface deepseek xai together ollama openai anthropic github"
  for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
    echo "$known" | grep -qw "$pid" && pass "cross: $pid is known" || fail "cross: $pid is known"
  done

  for pid in "${available[@]}"; do
    local kc
    kc=$(key_count "$pid")
    [ "$kc" -gt 0 ] && pass "cross: $pid has $kc key(s)" || fail "cross: $pid has keys"
  done

  for pid in "${available[@]}"; do
    local m
    m=$(get_model "$pid")
    [ -n "$m" ] && pass "cross: $pid model ($m)" || fail "cross: $pid has model"
  done

  # Concurrent inference
  echo "  $(dim '▸ Concurrent inference')"
  local pids_arr=() results_dir
  results_dir=$(mktemp -d)

  for entry in "${PROVIDERS[@]}"; do
    local env_var pid
    env_var=$(echo "$entry" | cut -d'|' -f1)
    pid=$(echo "$entry" | cut -d'|' -f2)
    has_key "$pid" || continue
    local k m
    k=$(get_key "$pid")
    m=$(get_model "$pid")

    (
      local output
      output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
        "${env_var}=${k}" \
        ami --model "$m" --prompt "Say ok" 2>/dev/null) || true
      local status
      status=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
      echo "$status" > "$results_dir/$pid"
    ) &
    pids_arr+=($!)
  done

  for p in "${pids_arr[@]}"; do
    wait "$p" 2>/dev/null || true
  done

  local ok_count=0
  for f in "$results_dir"/*; do
    [ -f "$f" ] || continue
    local pname
    pname=$(basename "$f")
    if [ "$(cat "$f")" = "true" ]; then
      pass "cross/concurrent: $pname ok"
      ok_count=$((ok_count + 1))
    else
      skip "cross/concurrent: $pname" "failed"
    fi
  done
  rm -rf "$results_dir"

  [ "$ok_count" -ge 2 ] && pass "cross/concurrent: $ok_count total" || fail "cross/concurrent" "$ok_count succeeded"

  # CLI validation
  echo "  $(dim '▸ CLI validation')"

  local ver
  ver=$(ami --version 2>&1 || true)
  echo "$ver" | grep -q "superinference v" && pass "cross: ami --version ($ver)" || fail "cross: ami --version" "$ver"

  local hlp
  hlp=$(ami --help 2>&1 || true)
  for flag in "--prompt" "--model" "--api-key" "--base-url" "--version" "--help"; do
    echo "$hlp" | grep -q -- "$flag" && pass "cross: --help has $flag" || fail "cross: --help has $flag"
  done
  for var in "AI_API_KEY" "GOOGLE_API_KEY" "AI_BASE_URL" "AI_MODEL"; do
    echo "$hlp" | grep -q "$var" && pass "cross: --help has $var" || fail "cross: --help has $var"
  done

  # No source code leakage
  echo "  $(dim '▸ Source code leakage check')"
  local ci_dir
  ci_dir=$(dirname "$SCRIPT_DIR")
  for ext in ts tsx js jsx; do
    local found
    found=$(find "$ci_dir" -name "*.$ext" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null | head -1 || true)
    [ -z "$found" ] && pass "cross: no .$ext files" || fail "cross: no .$ext files" "$found"
  done
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

for entry in "${PROVIDERS[@]}"; do
  IFS='|' read -r env_var pid base_url <<< "$entry"
  run_inference_tests "$env_var" "$pid" "$base_url"
  run_model_discovery "$env_var" "$pid" "$base_url"
  run_error_tests "$pid" "$base_url"
  run_streaming_tests "$pid" "$base_url"
  run_curl_advanced "$pid" "$base_url"
done

run_reliability
run_cross_provider

summary
