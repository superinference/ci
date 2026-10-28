#!/bin/bash
# FRITO CI — shared test helpers
# No source code from ami-ui/common/core — only curl + jq
set -euo pipefail

FRITO_CONFIG="${FRITO_CONFIG:-$HOME/.ami/frito.json}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

green()  { printf "\033[32m%s\033[0m" "$*"; }
red()    { printf "\033[31m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }
dim()    { printf "\033[2m%s\033[0m" "$*"; }
bold()   { printf "\033[1m%s\033[0m" "$*"; }

pass() {
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "  $(green PASS)  %s\n" "$1"
}

fail() {
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf "  $(red FAIL)  %s" "$1"
  [ -n "${2:-}" ] && printf " — $(dim '%s')" "$2"
  printf "\n"
}

skip() {
  TOTAL_COUNT=$((TOTAL_COUNT + 1))
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf "  $(yellow SKIP)  %s" "$1"
  [ -n "${2:-}" ] && printf " — $(dim '%s')" "$2"
  printf "\n"
}

summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  Total: %d  |  $(green 'Pass: %d')  |  $(red 'Fail: %d')  |  $(yellow 'Skip: %d')\n" \
    "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

section() {
  echo ""
  echo "$(bold "── $1 ──")"
}

# ─── Config helpers ───────────────────────────────────────────────

get_key() {
  local provider="$1"
  local idx="${2:-0}"
  jq -r ".providers.${provider}.keys[${idx}] // empty" "$FRITO_CONFIG" 2>/dev/null || true
}

get_model() {
  local provider="$1"
  jq -r ".providers.${provider}.model // empty" "$FRITO_CONFIG" 2>/dev/null || true
}

has_key() {
  local provider="$1"
  local key
  key=$(get_key "$provider")
  [ -n "$key" ] && [ "$key" != "null" ]
}

key_count() {
  local provider="$1"
  jq -r ".providers.${provider}.keys | length" "$FRITO_CONFIG" 2>/dev/null || echo "0"
}

# ─── API request helpers ─────────────────────────────────────────

# Build extra headers for providers that need them (e.g. OpenRouter)
_provider_headers() {
  local base_url="$1"
  if echo "$base_url" | grep -q "openrouter"; then
    echo '-H HTTP-Referer: https://www.superinference.org -H X-Title: FRITO-CI'
  fi
}

# OpenAI-compatible chat completion (non-streaming)
# Usage: openai_chat BASE_URL API_KEY MODEL PROMPT [EXTRA_JSON_FIELDS]
# Returns: response body on stdout, HTTP code on fd 3
openai_chat() {
  local base_url="$1" key="$2" model="$3" prompt="$4"
  local extra="${5:-}"
  local body
  body=$(cat <<ENDJSON
{
  "model": "$model",
  "messages": [{"role": "user", "content": "$prompt"}],
  "max_tokens": 256
  ${extra:+,$extra}
}
ENDJSON
)
  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi
  curl -sS --max-time 60 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    -d "$body" \
    "${base_url}/chat/completions" 2>/dev/null || echo "__HTTP_CODE__000"
}

# OpenAI-compatible chat with system message
openai_chat_system() {
  local base_url="$1" key="$2" model="$3" system="$4" user="$5"
  local extra="${6:-}"
  local body
  body=$(cat <<ENDJSON
{
  "model": "$model",
  "messages": [
    {"role": "system", "content": "$system"},
    {"role": "user", "content": "$user"}
  ],
  "max_tokens": 256
  ${extra:+,$extra}
}
ENDJSON
)
  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi
  curl -sS --max-time 60 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    -d "$body" \
    "${base_url}/chat/completions" 2>/dev/null || echo "__HTTP_CODE__000"
}

# OpenAI-compatible multi-turn chat
openai_chat_multi() {
  local base_url="$1" key="$2" model="$3"
  shift 3
  local messages="$1"
  local body
  body=$(cat <<ENDJSON
{
  "model": "$model",
  "messages": $messages,
  "max_tokens": 256
}
ENDJSON
)
  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi
  curl -sS --max-time 60 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    -d "$body" \
    "${base_url}/chat/completions" 2>/dev/null || echo "__HTTP_CODE__000"
}

# OpenAI-compatible streaming chat
openai_chat_stream() {
  local base_url="$1" key="$2" model="$3" prompt="$4"
  local extra="${5:-}"
  local body
  body=$(cat <<ENDJSON
{
  "model": "$model",
  "messages": [{"role": "user", "content": "$prompt"}],
  "max_tokens": 256,
  "stream": true
  ${extra:+,$extra}
}
ENDJSON
)
  local extra_headers=()
  if echo "$base_url" | grep -q "openrouter"; then
    extra_headers+=(-H "HTTP-Referer: https://www.superinference.org" -H "X-Title: FRITO-CI")
  fi
  curl -sS --max-time 60 \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    "${extra_headers[@]}" \
    -d "$body" \
    "${base_url}/chat/completions" 2>/dev/null || true
}

# OpenAI-compatible list models
openai_models() {
  local base_url="$1" key="$2"
  curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Authorization: Bearer $key" \
    "${base_url}/models" 2>/dev/null || echo "__HTTP_CODE__000"
}

# Google Generative AI chat (non-streaming)
google_chat() {
  local key="$1" model="$2" prompt="$3"
  local extra="${4:-}"
  local body
  body=$(cat <<ENDJSON
{
  "contents": [{"parts": [{"text": "$prompt"}]}]
  ${extra:+,$extra}
}
ENDJSON
)
  curl -sS --max-time 60 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}" \
    2>/dev/null || echo "__HTTP_CODE__000"
}

# Google Generative AI with system instruction
google_chat_system() {
  local key="$1" model="$2" system="$3" user="$4"
  local body
  body=$(cat <<ENDJSON
{
  "system_instruction": {"parts": [{"text": "$system"}]},
  "contents": [{"parts": [{"text": "$user"}]}]
}
ENDJSON
)
  curl -sS --max-time 60 \
    -w "\n__HTTP_CODE__%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}" \
    2>/dev/null || echo "__HTTP_CODE__000"
}

# Google streaming
google_chat_stream() {
  local key="$1" model="$2" prompt="$3"
  local body
  body=$(cat <<ENDJSON
{
  "contents": [{"parts": [{"text": "$prompt"}]}]
}
ENDJSON
)
  curl -sS --max-time 60 \
    -H "Content-Type: application/json" \
    -d "$body" \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:streamGenerateContent?alt=sse&key=${key}" \
    2>/dev/null || true
}

# Google list models
google_models() {
  local key="$1"
  curl -sS --max-time 30 \
    -w "\n__HTTP_CODE__%{http_code}" \
    "https://generativelanguage.googleapis.com/v1beta/models?key=${key}" \
    2>/dev/null || echo "__HTTP_CODE__000"
}

# ─── Response parsing helpers ────────────────────────────────────

extract_http_code() {
  echo "$1" | grep -o '__HTTP_CODE__[0-9]*' | tail -1 | sed 's/__HTTP_CODE__//'
}

extract_body() {
  echo "$1" | sed 's/__HTTP_CODE__[0-9]*$//'
}

# ─── Assertion helpers ───────────────────────────────────────────

assert_http_ok() {
  local code="$1" name="$2"
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    fail "$name" "connection failed (HTTP 000)"
  elif [ "$code" -ge 200 ] && [ "$code" -lt 300 ]; then
    pass "$name"
  elif [ "$code" = "429" ] || [ "$code" = "402" ]; then
    skip "$name" "rate limited/billing ($code)"
  else
    fail "$name" "HTTP $code"
  fi
}

assert_http_error() {
  local code="$1" expected="$2" name="$3"
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    fail "$name" "connection failed"
  elif [ "$code" = "$expected" ]; then
    pass "$name"
  elif [ "$code" -ge 400 ]; then
    pass "$name"  # any 4xx is acceptable for error tests
  else
    fail "$name" "expected error, got HTTP $code"
  fi
}

assert_contains() {
  local body="$1" substr="$2" name="$3"
  if echo "$body" | grep -qi "$substr"; then
    pass "$name"
  else
    fail "$name" "response does not contain '$substr'"
  fi
}

assert_not_contains() {
  local body="$1" substr="$2" name="$3"
  if echo "$body" | grep -qi "$substr"; then
    fail "$name" "response contains '$substr' (should not)"
  else
    pass "$name"
  fi
}

assert_json_field() {
  local body="$1" jq_path="$2" name="$3"
  local val
  val=$(echo "$body" | jq -r "$jq_path" 2>/dev/null || echo "")
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    pass "$name"
  else
    fail "$name" "missing JSON field: $jq_path"
  fi
}

assert_json_number_gt() {
  local body="$1" jq_path="$2" min="$3" name="$4"
  local val
  val=$(echo "$body" | jq -r "$jq_path" 2>/dev/null || echo "0")
  if [ -n "$val" ] && [ "$val" != "null" ] && [ "$val" -gt "$min" ] 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "$jq_path = $val (expected > $min)"
  fi
}

assert_nonempty() {
  local val="$1" name="$2"
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    pass "$name"
  else
    fail "$name" "empty or null"
  fi
}

assert_valid_json() {
  local body="$1" name="$2"
  if echo "$body" | jq . >/dev/null 2>&1; then
    pass "$name"
  else
    fail "$name" "invalid JSON"
  fi
}

# ─── Rate limiting ───────────────────────────────────────────────

LAST_REQUEST_TIME=0
MIN_REQUEST_INTERVAL=3
GOOGLE_REQUEST_INTERVAL=5
LAST_GOOGLE_TIME=0

rate_limit_wait() {
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - LAST_REQUEST_TIME))
  if [ "$elapsed" -lt "$MIN_REQUEST_INTERVAL" ]; then
    sleep $((MIN_REQUEST_INTERVAL - elapsed))
  fi
  LAST_REQUEST_TIME=$(date +%s)
}

google_rate_limit_wait() {
  local now elapsed
  now=$(date +%s)
  elapsed=$((now - LAST_GOOGLE_TIME))
  if [ "$elapsed" -lt "$GOOGLE_REQUEST_INTERVAL" ]; then
    sleep $((GOOGLE_REQUEST_INTERVAL - elapsed))
  fi
  LAST_GOOGLE_TIME=$(date +%s)
  LAST_REQUEST_TIME=$LAST_GOOGLE_TIME
}

pwait() {
  if [ "$1" = "google" ]; then
    google_rate_limit_wait
  else
    rate_limit_wait
  fi
}

# ─── ANSI / expect helpers ──────────────────────────────────────

strip_ansi() {
  sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b(B//g; s/\x1b\]0;[^\x07]*\x07//g; s/\r//g' \
    | tr -s '\n'
}

# Run a single slash command in the interactive TUI via expect.
# Usage: ami_slash "/help" [ENV_VAR=value ...]
# Returns: ANSI-stripped output from the TUI session.
ami_slash() {
  local cmd="$1"; shift
  local env_exports=""
  for pair in "$@"; do
    env_exports="$env_exports $pair"
  done
  timeout 45 expect -c "
    set timeout 30
    log_user 1
    spawn env -i PATH=$::env(PATH) HOME=$::env(HOME) TERM=dumb NODE_NO_WARNINGS=1 $env_exports ami
    sleep 3
    send \"$cmd\r\"
    sleep 3
    send \"/quit\r\"
    expect eof
  " 2>&1 | strip_ansi || true
}

# Run multiple slash commands in sequence.
# Usage: ami_slash_multi "ENV_VAR=val ..." -- "/cmd1" "/cmd2" ...
ami_slash_multi() {
  local env_exports=""
  local commands=()
  local sep=false
  for arg in "$@"; do
    if [ "$arg" = "--" ]; then sep=true; continue; fi
    if $sep; then commands+=("$arg"); else env_exports="$env_exports $arg"; fi
  done
  local send_script=""
  for cmd in "${commands[@]}"; do
    send_script="${send_script}
    send \"$cmd\r\"
    sleep 3"
  done
  timeout 90 expect -c "
    set timeout 60
    log_user 1
    spawn env -i PATH=$::env(PATH) HOME=$::env(HOME) TERM=dumb NODE_NO_WARNINGS=1 $env_exports ami
    sleep 3
    $send_script
    send \"/quit\r\"
    expect eof
  " 2>&1 | strip_ansi || true
}

# Provider env-var mapping — canonical name for each provider's API key.
provider_env_var() {
  case "$1" in
    google)     echo "GOOGLE_API_KEY" ;;
    groq)       echo "GROQ_API_KEY" ;;
    openrouter) echo "AI_API_KEY" ;;
    mistral)    echo "MISTRAL_API_KEY" ;;
    cerebras)   echo "CEREBRAS_API_KEY" ;;
    openai)     echo "OPENAI_API_KEY" ;;
    anthropic)  echo "ANTHROPIC_API_KEY" ;;
    xai)        echo "XAI_API_KEY" ;;
    deepseek)   echo "DEEPSEEK_API_KEY" ;;
    togetherai) echo "TOGETHER_AI_API_KEY" ;;
    cohere)     echo "COHERE_API_KEY" ;;
    fireworks)  echo "FIREWORKS_API_KEY" ;;
    perplexity) echo "PERPLEXITY_API_KEY" ;;
    deepinfra)  echo "DEEPINFRA_API_KEY" ;;
    alibaba)    echo "ALIBABA_API_KEY" ;;
    luma)       echo "LUMA_API_KEY" ;;
    huggingface) echo "HF_TOKEN" ;;
    *)          echo "AI_API_KEY" ;;
  esac
}

# All known providers (for dynamic enumeration).
ALL_PROVIDERS=(
  google groq openrouter mistral cerebras
  openai anthropic xai deepseek togetherai
  cohere fireworks perplexity deepinfra
  alibaba luma huggingface
)
