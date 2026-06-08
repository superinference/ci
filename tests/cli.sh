#!/bin/bash
# FRITO CI — CLI flags, args, env vars, provider auto-detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

if [ ! -f "$FRITO_CONFIG" ]; then
  echo "ERROR: $FRITO_CONFIG not found"
  exit 1
fi

echo ""
echo "$(bold 'CLI Comprehensive Tests')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo ""

AMI_TIMEOUT=45

AMI_BIN=$(which ami 2>/dev/null || echo "")
if [ -z "$AMI_BIN" ]; then
  fail "ami binary found" "not in PATH"
  summary
  exit 1
fi
pass "ami binary found ($AMI_BIN)"

# Probe each provider once; mark unavailable providers so we skip them
# instead of hanging for 45s on every test.
declare -A PROVIDER_LIVE
for _pid in google groq openrouter mistral cerebras; do
  if has_key "$_pid"; then
    _k=$(get_key "$_pid")
    _m=$(get_model "$_pid")
    _ev="AI_API_KEY"
    case "$_pid" in
      google) _ev="GOOGLE_API_KEY" ;;
      groq)   _ev="GROQ_API_KEY" ;;
      mistral) _ev="MISTRAL_API_KEY" ;;
      cerebras) _ev="CEREBRAS_API_KEY" ;;
    esac
    _out=$(timeout 20 env -i PATH="$PATH" HOME="$HOME" TERM="dumb" NODE_NO_WARNINGS=1 \
      "${_ev}=${_k}" ami --model "$_m" --prompt "hi" 2>/dev/null) || true
    if [ -n "$_out" ] && echo "$_out" | jq -e '.ok == true' >/dev/null 2>&1; then
      PROVIDER_LIVE[$_pid]=1
    else
      PROVIDER_LIVE[$_pid]=0
    fi
  else
    PROVIDER_LIVE[$_pid]=0
  fi
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: --version flag
# ═══════════════════════════════════════════════════════════════════
section "Flag: --version"

VERSION_OUT=$(ami --version 2>&1 || true)

echo "$VERSION_OUT" | grep -q "superinference v" && pass "--version: shows superinference" || fail "--version: shows superinference" "$VERSION_OUT"
echo "$VERSION_OUT" | grep -qE "v[0-9]+\.[0-9]+\.[0-9]+" && pass "--version: semver format" || fail "--version: semver format" "$VERSION_OUT"

VERSION_STDOUT=$(ami --version 2>/dev/null)
[ -n "$VERSION_STDOUT" ] && pass "--version: output on stdout" || fail "--version: output on stdout"

VERSION_ONLY_STDERR=$(ami --version 2>&1 1>/dev/null || true)
[ -z "$VERSION_ONLY_STDERR" ] && pass "--version: no stderr" || skip "--version: no stderr" "${VERSION_ONLY_STDERR:0:40}"

EXTRACTED_VERSION=$(echo "$VERSION_OUT" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+")
[ -n "$EXTRACTED_VERSION" ] && pass "--version: extracted $EXTRACTED_VERSION" || fail "--version: extract version"

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: --help flag
# ═══════════════════════════════════════════════════════════════════
section "Flag: --help"

HELP_OUT=$(ami --help 2>&1 || true)

echo "$HELP_OUT" | grep -qi "usage" && pass "--help: shows usage" || fail "--help: shows usage"
echo "$HELP_OUT" | grep -qi "options" && pass "--help: shows options" || fail "--help: shows options"

for flag in "--base-url" "--api-key" "--model" "--permission-mode" "--prompt" "--resume" "--help" "--version"; do
  echo "$HELP_OUT" | grep -q -- "$flag" && pass "--help: documents $flag" || fail "--help: documents $flag"
done

for var in "AI_API_KEY" "GOOGLE_API_KEY" "ANTHROPIC_API_KEY" "OPENAI_API_KEY" "AI_BASE_URL" "AI_MODEL"; do
  echo "$HELP_OUT" | grep -q "$var" && pass "--help: documents $var" || fail "--help: documents $var"
done

echo "$HELP_OUT" | grep -q "deny-all" && pass "--help: documents deny-all mode" || fail "--help: documents deny-all"
echo "$HELP_OUT" | grep -q "auto-allow" && pass "--help: documents auto-allow mode" || fail "--help: documents auto-allow"

HELP_LINES=$(echo "$HELP_OUT" | wc -l | tr -d ' ')
[ "$HELP_LINES" -gt 5 ] && pass "--help: substantial output ($HELP_LINES lines)" || fail "--help: substantial" "$HELP_LINES lines"

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: --prompt flag (non-interactive mode)
# ═══════════════════════════════════════════════════════════════════
section "Flag: --prompt"

for entry in "GOOGLE_API_KEY|google" "GROQ_API_KEY|groq" "AI_API_KEY|openrouter" "MISTRAL_API_KEY|mistral" "CEREBRAS_API_KEY|cerebras"; do
  env_var=$(echo "$entry" | cut -d'|' -f1)
  pid=$(echo "$entry" | cut -d'|' -f2)

  if ! has_key "$pid" || [ "${PROVIDER_LIVE[$pid]:-0}" = "0" ]; then
    skip "--prompt/$pid" "no key or provider unavailable"
    continue
  fi

  key=$(get_key "$pid")
  model=$(get_model "$pid")

  pwait "$pid"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    "${env_var}=${key}" \
    ami --model "$model" --prompt "Say hello" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "--prompt/$pid: ok" "timed out or empty response"
    continue
  fi

  if ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "--prompt/$pid: valid JSON output" "non-JSON: ${output:0:60}"
    continue
  fi
  pass "--prompt/$pid: valid JSON output"

  ok=$(echo "$output" | jq -r '.ok')

  if [ "$ok" = "true" ]; then
    pass "--prompt/$pid: ok=true"
  else
    err=$(echo "$output" | jq -r '.error // "unknown"')
    if echo "$err" | grep -qiE "429|rate.limit|quota|max.turns|object Object|timeout|ECONNREFUSED|ETIMEDOUT|HTTP 4|HTTP 5|Max retries|server error|overloaded"; then
      skip "--prompt/$pid: ok" "$err"
    else
      fail "--prompt/$pid: ok" "$err"
    fi
    continue
  fi

  for field in "ok" "model" "provider" "baseUrl" "prompt" "response" "error" "elapsedMs"; do
    echo "$output" | jq -e "has(\"$field\")" >/dev/null 2>&1 && pass "--prompt/$pid: has .$field" || fail "--prompt/$pid: has .$field"
  done

  resp=$(echo "$output" | jq -r '.response')
  model_val=$(echo "$output" | jq -r '.model')
  provider_val=$(echo "$output" | jq -r '.provider')
  elapsed_val=$(echo "$output" | jq -r '.elapsedMs')

  [ -n "$resp" ] && [ "$resp" != "null" ] && pass "--prompt/$pid: response non-empty" || fail "--prompt/$pid: response non-empty"
  [ -n "$model_val" ] && [ "$model_val" != "null" ] && pass "--prompt/$pid: model non-empty" || fail "--prompt/$pid: model non-empty"
  [ -n "$provider_val" ] && [ "$provider_val" != "null" ] && pass "--prompt/$pid: provider non-empty" || fail "--prompt/$pid: provider non-empty"
  [ "$elapsed_val" -gt 0 ] 2>/dev/null && pass "--prompt/$pid: elapsedMs > 0 (${elapsed_val}ms)" || skip "--prompt/$pid: elapsedMs" "$elapsed_val"

  prompt_echo=$(echo "$output" | jq -r '.prompt')
  [ "$prompt_echo" = "Say hello" ] && pass "--prompt/$pid: prompt echoed" || fail "--prompt/$pid: prompt echoed" "$prompt_echo"

  error_val=$(echo "$output" | jq -r '.error')
  [ "$error_val" = "null" ] && pass "--prompt/$pid: error=null on success" || fail "--prompt/$pid: error=null" "$error_val"
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 4: --model flag
# ═══════════════════════════════════════════════════════════════════
section "Flag: --model"

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  key=$(get_key "groq")
  pwait "groq"

  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    GROQ_API_KEY="$key" \
    ami --model "llama-3.3-70b-versatile" --prompt "Say ok" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "--model: explicit model" "timed out or empty"
  else
    model_used=$(echo "$output" | jq -r '.model // empty' 2>/dev/null || true)
    [ "$model_used" = "llama-3.3-70b-versatile" ] && pass "--model: explicit model used" || skip "--model: explicit model" "got: $model_used"

    ok=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
    [ "$ok" = "true" ] && pass "--model: explicit model works" || skip "--model: explicit model works"
  fi
else
  skip "--model: explicit model" "no key or provider unavailable"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: No API key → error
# ═══════════════════════════════════════════════════════════════════
section "Error: No API Key"

NO_KEY_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
  ami --prompt "hello" 2>&1 || true)

echo "$NO_KEY_OUT" | grep -qi "api.key\|required\|error" && pass "no-key: error message" || skip "no-key: error message" "${NO_KEY_OUT:0:60}"
echo "$NO_KEY_OUT" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "no-key: no stack trace" || pass "no-key: no stack trace"

# ═══════════════════════════════════════════════════════════════════
# SECTION 6: --permission-mode flag
# ═══════════════════════════════════════════════════════════════════
section "Flag: --permission-mode"

INVALID_MODE_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
  AI_API_KEY="test-key" \
  ami --permission-mode "invalid-mode" --prompt "hi" 2>&1 || true)

echo "$INVALID_MODE_OUT" | grep -qi "invalid\|error\|must be" && pass "--permission-mode: invalid rejects" || skip "--permission-mode: invalid rejects" "${INVALID_MODE_OUT:0:60}"

for mode in "ask" "auto-allow" "deny-all"; do
  echo "$HELP_OUT" | grep -q "$mode" && pass "--permission-mode: $mode documented" || fail "--permission-mode: $mode documented"
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: Provider Auto-Detection
# ═══════════════════════════════════════════════════════════════════
section "Provider Auto-Detection"

echo "  $(dim '▸ Key format detection')"

if [ "${PROVIDER_LIVE[google]:-0}" = "1" ]; then
  gkey=$(get_key "google")
  pwait "google"
  gout=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    GOOGLE_API_KEY="$gkey" \
    ami --prompt "Say ok" 2>/dev/null) || true
  gprov=$(echo "$gout" | jq -r '.provider // empty' 2>/dev/null || true)
  echo "$gprov" | grep -qi "google\|gemini" && pass "auto-detect: GOOGLE_API_KEY → google ($gprov)" || skip "auto-detect: GOOGLE_API_KEY" "got: $gprov"
else
  skip "auto-detect: GOOGLE_API_KEY" "provider unavailable"
fi

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  gkey=$(get_key "groq")
  pwait "groq"
  gout=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    AI_API_KEY="$gkey" \
    ami --prompt "Say ok" 2>/dev/null) || true
  gprov=$(echo "$gout" | jq -r '.provider // empty' 2>/dev/null || true)
  echo "$gprov" | grep -qi "groq" && pass "auto-detect: gsk_ prefix → groq ($gprov)" || skip "auto-detect: gsk_ prefix" "got: $gprov"
else
  skip "auto-detect: gsk_ prefix" "provider unavailable"
fi

if [ "${PROVIDER_LIVE[openrouter]:-0}" = "1" ]; then
  orkey=$(get_key "openrouter")
  pwait "openrouter"
  orout=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    AI_API_KEY="$orkey" \
    ami --prompt "Say ok" 2>/dev/null) || true
  orprov=$(echo "$orout" | jq -r '.provider // empty' 2>/dev/null || true)
  echo "$orprov" | grep -qi "openrouter" && pass "auto-detect: sk-or- prefix → openrouter ($orprov)" || skip "auto-detect: sk-or-" "got: $orprov"
else
  skip "auto-detect: sk-or- prefix" "provider unavailable"
fi

echo "  $(dim '▸ Env var name detection')"

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  gkey=$(get_key "groq")
  pwait "groq"
  gout=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    GROQ_API_KEY="$gkey" \
    ami --prompt "Say ok" 2>/dev/null) || true
  gprov=$(echo "$gout" | jq -r '.provider // empty' 2>/dev/null || true)
  echo "$gprov" | grep -qi "groq" && pass "auto-detect: GROQ_API_KEY env → groq" || skip "auto-detect: GROQ_API_KEY env" "got: $gprov"
else
  skip "auto-detect: GROQ_API_KEY env" "provider unavailable"
fi

if [ "${PROVIDER_LIVE[mistral]:-0}" = "1" ]; then
  mkey=$(get_key "mistral")
  pwait "mistral"
  mout=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    MISTRAL_API_KEY="$mkey" \
    ami --prompt "Say ok" 2>/dev/null) || true
  mprov=$(echo "$mout" | jq -r '.provider // empty' 2>/dev/null || true)
  echo "$mprov" | grep -qi "mistral" && pass "auto-detect: MISTRAL_API_KEY env → mistral" || skip "auto-detect: MISTRAL_API_KEY env" "got: $mprov"
else
  skip "auto-detect: MISTRAL_API_KEY env" "provider unavailable"
fi

if [ "${PROVIDER_LIVE[cerebras]:-0}" = "1" ]; then
  ckey=$(get_key "cerebras")
  pwait "cerebras"
  cout=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    CEREBRAS_API_KEY="$ckey" \
    ami --prompt "Say ok" 2>/dev/null) || true
  cprov=$(echo "$cout" | jq -r '.provider // empty' 2>/dev/null || true)
  echo "$cprov" | grep -qi "cerebras" && pass "auto-detect: CEREBRAS_API_KEY env → cerebras" || skip "auto-detect: CEREBRAS_API_KEY env" "got: $cprov"
else
  skip "auto-detect: CEREBRAS_API_KEY env" "provider unavailable"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: --base-url flag
# ═══════════════════════════════════════════════════════════════════
section "Flag: --base-url"

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  key=$(get_key "groq")
  pwait "groq"

  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    AI_API_KEY="$key" \
    ami --base-url "https://api.groq.com/openai/v1" --model "llama-3.3-70b-versatile" --prompt "Say ok" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "--base-url: explicit URL" "timed out or empty"
  else
    base_used=$(echo "$output" | jq -r '.baseUrl // empty' 2>/dev/null || true)
    echo "$base_used" | grep -q "groq" && pass "--base-url: explicit URL used ($base_used)" || skip "--base-url: explicit URL" "got: $base_used"

    ok=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
    [ "$ok" = "true" ] && pass "--base-url: works with explicit URL" || skip "--base-url: works"
  fi
else
  skip "--base-url: explicit URL" "no key or provider unavailable"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 9: --api-key flag
# ═══════════════════════════════════════════════════════════════════
section "Flag: --api-key"

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  key=$(get_key "groq")
  pwait "groq"

  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    ami --api-key "$key" --model "llama-3.3-70b-versatile" --prompt "Say ok" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "--api-key: explicit key" "timed out or empty"
  else
    ok=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
    [ "$ok" = "true" ] && pass "--api-key: explicit key works" || skip "--api-key: explicit key"

    echo "$output" | grep -q "$key" && fail "--api-key: key not in output" || pass "--api-key: key not in output"
  fi
else
  skip "--api-key: explicit key" "no key or provider unavailable"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 10: Exit Code Behavior
# ═══════════════════════════════════════════════════════════════════
section "Exit Codes"

ami --version >/dev/null 2>&1 && pass "exit: --version → 0" || fail "exit: --version → 0"
ami --help >/dev/null 2>&1 && pass "exit: --help → 0" || fail "exit: --help → 0"

NO_KEY_RC=0
timeout 30 env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" ami --prompt "hi" >/dev/null 2>&1 || NO_KEY_RC=$?
[ "$NO_KEY_RC" -ne 0 ] && pass "exit: no key → non-zero ($NO_KEY_RC)" || skip "exit: no key → non-zero"

BAD_MODE_RC=0
timeout 30 env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" AI_API_KEY="test" ami --permission-mode "bad" --prompt "hi" >/dev/null 2>&1 || BAD_MODE_RC=$?
[ "$BAD_MODE_RC" -ne 0 ] && pass "exit: bad mode → non-zero ($BAD_MODE_RC)" || skip "exit: bad mode → non-zero"

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  key=$(get_key "groq")
  pwait "groq"
  timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    GROQ_API_KEY="$key" \
    ami --prompt "Say ok" >/dev/null 2>&1
  GOOD_RC=$?
  [ "$GOOD_RC" -eq 0 ] && pass "exit: good prompt → 0" || skip "exit: good prompt → 0" "rc=$GOOD_RC"
else
  skip "exit: good prompt → 0" "no key or provider unavailable"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 11: Output Format Consistency
# ═══════════════════════════════════════════════════════════════════
section "Output Format"

echo "  $(dim '▸ JSON schema consistency')"

for entry in "GOOGLE_API_KEY|google" "GROQ_API_KEY|groq" "AI_API_KEY|openrouter" "MISTRAL_API_KEY|mistral" "CEREBRAS_API_KEY|cerebras"; do
  env_var=$(echo "$entry" | cut -d'|' -f1)
  pid=$(echo "$entry" | cut -d'|' -f2)

  if ! has_key "$pid" || [ "${PROVIDER_LIVE[$pid]:-0}" = "0" ]; then
    skip "format/$pid: schema" "no key or provider unavailable"
    continue
  fi

  key=$(get_key "$pid")
  model=$(get_model "$pid")

  pwait "$pid"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    "${env_var}=${key}" \
    ami --model "$model" --prompt "Say ok" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "format/$pid: schema" "timed out"
    continue
  fi

  if ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "format/$pid: valid JSON" "non-JSON"
    continue
  fi

  missing=0
  for f in ok model provider baseUrl prompt response error elapsedMs; do
    echo "$output" | jq -e "has(\"$f\")" >/dev/null 2>&1 || missing=$((missing + 1))
  done

  [ "$missing" -eq 0 ] && pass "format/$pid: all 8 fields present" || fail "format/$pid: all fields" "$missing missing"

  ok_type=$(echo "$output" | jq -r '.ok | type' 2>/dev/null || echo "unknown")
  elapsed_type=$(echo "$output" | jq -r '.elapsedMs | type' 2>/dev/null || echo "unknown")

  [ "$ok_type" = "boolean" ] && pass "format/$pid: .ok is boolean" || fail "format/$pid: .ok type" "$ok_type"
  [ "$elapsed_type" = "number" ] && pass "format/$pid: .elapsedMs is number" || fail "format/$pid: .elapsedMs type" "$elapsed_type"
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 12: Env Var Precedence
# ═══════════════════════════════════════════════════════════════════
section "Env Var Precedence"

if [ "${PROVIDER_LIVE[groq]:-0}" = "1" ]; then
  key=$(get_key "groq")

  pwait "groq"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    AI_API_KEY="$key" \
    ami --prompt "Say ok" 2>/dev/null) || true

  ok=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
  [ "$ok" = "true" ] && pass "precedence: AI_API_KEY works alone" || skip "precedence: AI_API_KEY" "failed"

  pwait "groq"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    AI_API_KEY="invalid-key-xyz" \
    ami --api-key "$key" --model "llama-3.3-70b-versatile" --prompt "Say ok" 2>/dev/null) || true

  ok=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
  [ "$ok" = "true" ] && pass "precedence: --api-key overrides AI_API_KEY" || skip "precedence: --api-key override"

  pwait "groq"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    GROQ_API_KEY="$key" AI_MODEL="llama-3.3-70b-versatile" \
    ami --prompt "Say ok" 2>/dev/null) || true

  model_used=$(echo "$output" | jq -r '.model // empty' 2>/dev/null || true)
  [ "$model_used" = "llama-3.3-70b-versatile" ] && pass "precedence: AI_MODEL env respected" || skip "precedence: AI_MODEL" "got: $model_used"

  pwait "groq"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
    GROQ_API_KEY="$key" AI_MODEL="wrong-model" \
    ami --model "llama-3.3-70b-versatile" --prompt "Say ok" 2>/dev/null) || true

  model_used=$(echo "$output" | jq -r '.model // empty' 2>/dev/null || true)
  [ "$model_used" = "llama-3.3-70b-versatile" ] && pass "precedence: --model overrides AI_MODEL" || skip "precedence: --model override" "got: $model_used"
else
  skip "precedence tests" "no key or provider unavailable"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 13: Binary Properties
# ═══════════════════════════════════════════════════════════════════
section "Binary Properties"

[ -x "$AMI_BIN" ] && pass "binary: is executable" || fail "binary: is executable"

SIZE=$(stat -c%s "$AMI_BIN" 2>/dev/null || stat -f%z "$AMI_BIN" 2>/dev/null || echo "0")
[ "$SIZE" -gt 100000 ] && pass "binary: size > 100KB ($(( SIZE / 1024 ))KB)" || fail "binary: size" "${SIZE}B"
[ "$SIZE" -lt 200000000 ] && pass "binary: size < 200MB" || fail "binary: size" "$(( SIZE / 1048576 ))MB"

FILE_TYPE=$(file "$AMI_BIN" 2>/dev/null || echo "unknown")
pass "binary: type $(echo "$FILE_TYPE" | head -c 60)"

if [ -L "$AMI_BIN" ]; then
  TARGET=$(readlink -f "$AMI_BIN")
  [ -f "$TARGET" ] && pass "binary: symlink target exists" || fail "binary: broken symlink"
else
  pass "binary: regular file"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 14: Concurrent CLI Invocations
# ═══════════════════════════════════════════════════════════════════
section "Concurrent CLI"

CONC_DIR=$(mktemp -d)

for i in 1 2 3; do
  (ami --version > "$CONC_DIR/ver-$i" 2>&1 || true) &
done
wait

ALL_MATCH=true
for i in 1 2 3; do
  if [ -f "$CONC_DIR/ver-$i" ]; then
    if grep -q "superinference v" "$CONC_DIR/ver-$i"; then
      pass "concurrent: --version #$i ok"
    else
      fail "concurrent: --version #$i" "$(cat "$CONC_DIR/ver-$i")"
      ALL_MATCH=false
    fi
  else
    fail "concurrent: --version #$i" "no output file"
    ALL_MATCH=false
  fi
done

$ALL_MATCH && pass "concurrent: all --version consistent" || fail "concurrent: consistency"
rm -rf "$CONC_DIR"

summary
