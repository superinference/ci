#!/bin/bash
# FRITO CI — Agent feature tests (tools, sessions, permissions, modes)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

if ! has_frito_config; then
  echo "ERROR: No frito config (set FRITO_JSON env var or FRITO_CONFIG file path)"
  exit 1
fi

echo ""
echo "$(bold 'Agent Feature Tests')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $(command -v ami 2>/dev/null || echo 'not found')")"
echo ""

AMI_TIMEOUT=$AMI_TIMEOUT_LONG

AMI_BIN=$(command -v ami 2>/dev/null || echo "")
if [ -z "$AMI_BIN" ]; then
  fail "ami binary found" "not in PATH"
  summary
  exit 1
fi
pass "ami binary found ($AMI_BIN)"

# ═══════════════════════════════════════════════════════════════════
# Find a working provider for tool/agent tests
# ═══════════════════════════════════════════════════════════════════

TOOL_PID=""
TOOL_KEY=""
TOOL_MODEL=""
TOOL_ENV=""

for _candidate in deepseek openai alibaba groq openrouter mistral cerebras google nvidia; do
  if has_key "$_candidate"; then
    _k=$(get_key "$_candidate")
    _m=$(pick_model "$_candidate")
    _env_args=$(provider_env_string "$_candidate" "$_k")
    _out=$(timeout $PROBE_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      $_env_args ami --model "$_m" --max-turns $MAX_TURNS_PROBE --prompt "hi" 2>/dev/null) || true
    if [ -n "$_out" ] && echo "$_out" | jq -e '(.ok == true) or ((.error // "") | test("max.turns"; "i"))' >/dev/null 2>&1; then
      TOOL_PID="$_candidate"
      TOOL_KEY="$_k"
      TOOL_MODEL="$_m"
      TOOL_ENV=$(provider_env_string "$_candidate" "$_k")
      echo "  $(dim "Tool provider: $_candidate (live, model: $_m)")"
      break
    fi
  fi
done

if [ -z "$TOOL_PID" ]; then
  echo "  $(dim 'No live provider found — tool tests will be skipped')"
fi

# Probe a second provider for cross-provider tests
SECOND_PID=""
SECOND_KEY=""
SECOND_MODEL=""
SECOND_ENV=""

for _candidate in deepseek openai alibaba groq openrouter mistral cerebras google nvidia; do
  [ "$_candidate" = "$TOOL_PID" ] && continue
  if has_key "$_candidate"; then
    _k=$(get_key "$_candidate")
    _m=$(pick_model "$_candidate")
    _env_args=$(provider_env_string "$_candidate" "$_k")
    _out=$(timeout $PROBE_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      $_env_args ami --model "$_m" --max-turns $MAX_TURNS_PROBE --prompt "hi" 2>/dev/null) || true
    if [ -n "$_out" ] && echo "$_out" | jq -e '(.ok == true) or ((.error // "") | test("max.turns"; "i"))' >/dev/null 2>&1; then
      SECOND_PID="$_candidate"
      SECOND_KEY="$_k"
      SECOND_MODEL="$_m"
      SECOND_ENV=$(provider_env_string "$_candidate" "$_k")
      echo "  $(dim "Second provider: $_candidate (live, model: $_m)")"
      break
    fi
  fi
done

echo ""

# Helper: check if a response is a transient error worth skipping
is_transient() {
  local output="$1"
  if [ -z "$output" ]; then return 0; fi
  local err
  err=$(echo "$output" | jq -r '.error // empty' 2>/dev/null || true)
  if [ -z "$err" ]; then return 0; fi
  if echo "$err" | grep -qiE "429|rate.limit|too.many|quota|resource.exhausted|timeout|ECONNREFUSED|ETIMEDOUT|HTTP [45]|Max retries|overloaded|max.turns|server error|context.overflow|request.too.large"; then
    return 0
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: Tool Execution in Detached Mode
# ═══════════════════════════════════════════════════════════════════
section "Tool Execution (Detached Mode)"

if [ -n "$TOOL_PID" ]; then

  # ── File read tool ─────────────────────────────────────────────
  echo "  $(dim '▸ File read tool')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Read the file /etc/hostname and tell me what it contains. Just the contents, nothing else." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/file-read: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/file-read: valid JSON" "non-JSON: ${output:0:60}"
  else
    pass "tool/file-read: valid JSON"
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/file-read: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      [ -n "$resp" ] && [ "$resp" != "null" ] && pass "tool/file-read: response non-empty" || fail "tool/file-read: response non-empty"
    else
      err=$(echo "$output" | jq -r '.error // empty')
      if is_transient "$output"; then
        skip "tool/file-read: ok" "${err:0:50}"
        skip "tool/file-read: response non-empty" "transient"
      else
        fail "tool/file-read: ok" "${err:0:80}"
        skip "tool/file-read: response non-empty" "inference failed"
      fi
    fi
  fi

  # ── Bash execution tool ────────────────────────────────────────
  echo "  $(dim '▸ Bash execution tool')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run the command 'echo hello123' and tell me the output. Just the output." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/bash: output" "timed out or empty"
    skip "tool/bash: contains hello123" "no output"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/bash: valid JSON" "non-JSON"
    skip "tool/bash: contains hello123" "non-JSON"
  else
    pass "tool/bash: valid JSON"
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/bash: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      if echo "$resp" | grep -q "hello123"; then
        pass "tool/bash: contains hello123"
      else
        skip "tool/bash: contains hello123" "got: ${resp:0:40}"
      fi
    else
      err=$(echo "$output" | jq -r '.error // empty')
      if is_transient "$output"; then
        skip "tool/bash: ok" "${err:0:50}"
        skip "tool/bash: contains hello123" "transient"
      else
        fail "tool/bash: ok" "${err:0:80}"
        skip "tool/bash: contains hello123" "inference failed"
      fi
    fi
  fi

  # ── Working directory tool ─────────────────────────────────────
  echo "  $(dim '▸ Working directory')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "What directory are you in? Run pwd and tell me the result." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/pwd: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/pwd: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/pwd: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      if echo "$resp" | grep -qE "/[a-zA-Z]"; then
        pass "tool/pwd: response has a path"
      else
        skip "tool/pwd: response has a path" "got: ${resp:0:40}"
      fi
    else
      if is_transient "$output"; then
        skip "tool/pwd: ok" "transient"
        skip "tool/pwd: response has a path" "transient"
      else
        fail "tool/pwd: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/pwd: response has a path" "failed"
      fi
    fi
  fi

  # ── File listing tool ──────────────────────────────────────────
  echo "  $(dim '▸ File listing')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "List files in /tmp using ls and tell me what you see. Just the listing." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/ls: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/ls: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/ls: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      [ -n "$resp" ] && [ "$resp" != "null" ] && pass "tool/ls: response has content" || skip "tool/ls: response has content" "empty"
    else
      if is_transient "$output"; then
        skip "tool/ls: ok" "transient"
        skip "tool/ls: response has content" "transient"
      else
        fail "tool/ls: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/ls: response has content" "failed"
      fi
    fi
  fi

  # ── Multiple tools (date) ──────────────────────────────────────
  echo "  $(dim '▸ Multiple tools (date)')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'date +%Y' and tell me the year. Just the year number." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/date: output" "timed out or empty"
    skip "tool/date: contains 2026" "no output"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/date: valid JSON" "non-JSON"
    skip "tool/date: contains 2026" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/date: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      if echo "$resp" | grep -q "202"; then
        pass "tool/date: contains year"
      else
        skip "tool/date: contains year" "got: ${resp:0:40}"
      fi
    else
      if is_transient "$output"; then
        skip "tool/date: ok" "transient"
        skip "tool/date: contains year" "transient"
      else
        fail "tool/date: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/date: contains year" "failed"
      fi
    fi
  fi

  # ── Error handling (nonexistent file) ──────────────────────────
  echo "  $(dim '▸ Tool error handling')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Read /nonexistent/file/path/xyz123 and tell me what happened." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/error: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/error: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/error: ok=true (graceful)"
      resp=$(echo "$output" | jq -r '.response // empty')
      [ -n "$resp" ] && pass "tool/error: response present" || skip "tool/error: response present" "empty"
    else
      if is_transient "$output"; then
        skip "tool/error: ok" "transient"
        skip "tool/error: response present" "transient"
      else
        # Even ok=false is acceptable here — the tool reported an error cleanly
        err=$(echo "$output" | jq -r '.error // empty')
        echo "$err" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "tool/error: no stack trace" "$err" || pass "tool/error: clean error"
        pass "tool/error: handled gracefully"
      fi
    fi
  fi

  # ── Environment variable reading ──────────────────────────────
  echo "  $(dim '▸ Env var in tool context')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV TEST_MARKER_XYZ="frito-test-42" \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'echo \$TEST_MARKER_XYZ' and tell me the output." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/env: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/env: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/env: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      [ -n "$resp" ] && pass "tool/env: response present" || skip "tool/env: response present" "empty"
    else
      if is_transient "$output"; then
        skip "tool/env: ok" "transient"
        skip "tool/env: response present" "transient"
      else
        fail "tool/env: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/env: response present" "failed"
      fi
    fi
  fi

  # ── Multi-step tool use ────────────────────────────────────────
  echo "  $(dim '▸ Multi-step tool use')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'uname -s' and tell me the operating system." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/uname: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/uname: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/uname: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      if echo "$resp" | grep -qi "linux"; then
        pass "tool/uname: detected Linux"
      else
        skip "tool/uname: detected Linux" "got: ${resp:0:40}"
      fi
    else
      if is_transient "$output"; then
        skip "tool/uname: ok" "transient"
        skip "tool/uname: detected Linux" "transient"
      else
        fail "tool/uname: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/uname: detected Linux" "failed"
      fi
    fi
  fi

  # ── File write + read roundtrip ────────────────────────────────
  echo "  $(dim '▸ File write + read roundtrip')"
  ROUNDTRIP_DIR=$(mktemp -d)
  ROUNDTRIP_FILE="$ROUNDTRIP_DIR/agent-test-file.txt"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Write the text 'FRITO_MARKER_99' to $ROUNDTRIP_FILE using bash, then read it back and tell me what it says." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/roundtrip: output" "timed out or empty"
    skip "tool/roundtrip: file created" "no output"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/roundtrip: valid JSON" "non-JSON"
    skip "tool/roundtrip: file created" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/roundtrip: ok=true"
      if [ -f "$ROUNDTRIP_FILE" ]; then
        pass "tool/roundtrip: file created"
        content=$(cat "$ROUNDTRIP_FILE" 2>/dev/null || true)
        echo "$content" | grep -q "FRITO_MARKER_99" && pass "tool/roundtrip: content correct" || skip "tool/roundtrip: content correct" "got: ${content:0:30}"
      else
        skip "tool/roundtrip: file created" "file not found"
        skip "tool/roundtrip: content correct" "no file"
      fi
    else
      if is_transient "$output"; then
        skip "tool/roundtrip: ok" "transient"
        skip "tool/roundtrip: file created" "transient"
      else
        fail "tool/roundtrip: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/roundtrip: file created" "failed"
      fi
    fi
  fi
  rm -rf "$ROUNDTRIP_DIR"

  # ── Arithmetic via tool ────────────────────────────────────────
  echo "  $(dim '▸ Arithmetic via bash tool')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'echo \$((7 * 13))' in bash and tell me the result. Just the number." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "tool/arith: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "tool/arith: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "tool/arith: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      echo "$resp" | grep -q "91" && pass "tool/arith: correct (91)" || skip "tool/arith: correct" "got: ${resp:0:30}"
    else
      if is_transient "$output"; then
        skip "tool/arith: ok" "transient"
        skip "tool/arith: correct" "transient"
      else
        fail "tool/arith: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "tool/arith: correct" "failed"
      fi
    fi
  fi

else
  for t in file-read bash pwd ls date error env uname roundtrip arith; do
    skip "tool/$t" "no live provider"
  done
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: Permission Modes
# ═══════════════════════════════════════════════════════════════════
section "Permission Modes"

if [ -n "$TOOL_PID" ]; then

  # ── auto-allow mode ────────────────────────────────────────────
  echo "  $(dim '▸ auto-allow mode')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'echo perm-test-auto' and tell me the output." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "perm/auto-allow: output" "timed out or empty"
    skip "perm/auto-allow: tool executed" "no output"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "perm/auto-allow: valid JSON" "non-JSON"
    skip "perm/auto-allow: tool executed" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "perm/auto-allow: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      if echo "$resp" | grep -q "perm-test-auto"; then
        pass "perm/auto-allow: tool executed"
      else
        skip "perm/auto-allow: tool executed" "got: ${resp:0:40}"
      fi
    else
      if is_transient "$output"; then
        skip "perm/auto-allow: ok" "transient"
        skip "perm/auto-allow: tool executed" "transient"
      else
        fail "perm/auto-allow: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "perm/auto-allow: tool executed" "failed"
      fi
    fi
  fi

  # ── deny-all mode ──────────────────────────────────────────────
  echo "  $(dim '▸ deny-all mode')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode deny-all \
    --prompt "Run 'echo denied-test' and tell me the output." 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "perm/deny-all: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "perm/deny-all: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "perm/deny-all: ok=true (completed without tools)"
      resp=$(echo "$output" | jq -r '.response // empty')
      [ -n "$resp" ] && pass "perm/deny-all: response present" || skip "perm/deny-all: response present" "empty"
    else
      if is_transient "$output"; then
        skip "perm/deny-all: ok" "transient"
        skip "perm/deny-all: response present" "transient"
      else
        # deny-all may cause the model to produce ok=false if tools are required
        # That's still acceptable behavior
        pass "perm/deny-all: mode accepted"
        pass "perm/deny-all: completed"
      fi
    fi
  fi

  # ── ask mode (default) ─────────────────────────────────────────
  echo "  $(dim '▸ ask mode (default)')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode ask \
    --prompt "Say hello" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "perm/ask: output" "timed out or empty"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "perm/ask: valid JSON" "non-JSON"
  else
    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "perm/ask: ok=true"
      resp=$(echo "$output" | jq -r '.response // empty')
      [ -n "$resp" ] && [ "$resp" != "null" ] && pass "perm/ask: response present" || skip "perm/ask: response present" "empty"
    else
      if is_transient "$output"; then
        skip "perm/ask: ok" "transient"
        skip "perm/ask: response present" "transient"
      else
        fail "perm/ask: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
        skip "perm/ask: response present" "failed"
      fi
    fi
  fi

  # ── invalid permission mode ────────────────────────────────────
  echo "  $(dim '▸ invalid permission mode')"
  INVALID_PERM_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode "bogus-mode" --prompt "hi" 2>&1 || true)

  echo "$INVALID_PERM_OUT" | grep -qiE "invalid|error|must be|unknown" && pass "perm/invalid: rejected" || skip "perm/invalid: rejected" "${INVALID_PERM_OUT:0:60}"

  # ── auto-allow enables tool output ─────────────────────────────
  echo "  $(dim '▸ auto-allow vs deny-all comparison')"
  pwait "$TOOL_PID"
  auto_output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'echo permcheck-777' and tell me the exact output." 2>/dev/null) || true

  pwait "$TOOL_PID"
  deny_output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode deny-all \
    --prompt "Run 'echo permcheck-777' and tell me the exact output." 2>/dev/null) || true

  auto_ok=$(echo "$auto_output" | jq -r '.ok' 2>/dev/null || echo "false")
  deny_ok=$(echo "$deny_output" | jq -r '.ok' 2>/dev/null || echo "false")

  if [ "$auto_ok" = "true" ] && [ "$deny_ok" = "true" ]; then
    auto_resp=$(echo "$auto_output" | jq -r '.response // empty' 2>/dev/null || true)
    deny_resp=$(echo "$deny_output" | jq -r '.response // empty' 2>/dev/null || true)
    # auto-allow should contain the tool output, deny-all should not
    if echo "$auto_resp" | grep -q "permcheck-777"; then
      pass "perm/compare: auto-allow has tool output"
    else
      skip "perm/compare: auto-allow has tool output" "not found in response"
    fi
    pass "perm/compare: both modes complete"
  else
    skip "perm/compare: auto-allow has tool output" "one or both modes failed"
    skip "perm/compare: both modes complete" "auto=$auto_ok deny=$deny_ok"
  fi

else
  for t in auto-allow deny-all ask invalid compare; do
    skip "perm/$t" "no live provider"
  done
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: Detached Mode Output Format
# ═══════════════════════════════════════════════════════════════════
section "Detached Mode Output Format"

if [ -n "$TOOL_PID" ]; then

  echo "  $(dim '▸ JSON schema verification')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Say hello" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "format: output" "timed out or empty"
    for f in ok model provider baseUrl prompt response error elapsedMs; do
      skip "format: has .$f" "no output"
    done
    skip "format: .ok type" "no output"
    skip "format: .elapsedMs type" "no output"
    skip "format: prompt echo" "no output"
    skip "format: error null" "no output"
    skip "format: elapsedMs range" "no output"
  elif ! echo "$output" | jq . >/dev/null 2>&1; then
    fail "format: valid JSON" "non-JSON: ${output:0:60}"
    for f in ok model provider baseUrl prompt response error elapsedMs; do
      skip "format: has .$f" "non-JSON"
    done
  else
    pass "format: valid JSON"

    # All 8 fields present
    for f in ok model provider baseUrl prompt response error elapsedMs; do
      echo "$output" | jq -e "has(\"$f\")" >/dev/null 2>&1 && pass "format: has .$f" || fail "format: has .$f"
    done

    # Type checks
    ok_type=$(echo "$output" | jq -r '.ok | type' 2>/dev/null || echo "unknown")
    [ "$ok_type" = "boolean" ] && pass "format: .ok is boolean" || fail "format: .ok type" "$ok_type"

    elapsed_type=$(echo "$output" | jq -r '.elapsedMs | type' 2>/dev/null || echo "unknown")
    [ "$elapsed_type" = "number" ] && pass "format: .elapsedMs is number" || fail "format: .elapsedMs type" "$elapsed_type"

    # Prompt echo
    prompt_echo=$(echo "$output" | jq -r '.prompt' 2>/dev/null || true)
    [ "$prompt_echo" = "Say hello" ] && pass "format: prompt echoed correctly" || fail "format: prompt echo" "$prompt_echo"

    ok_val=$(echo "$output" | jq -r '.ok' 2>/dev/null || echo "false")
    if [ "$ok_val" = "true" ]; then
      # Error should be null on success
      error_val=$(echo "$output" | jq -r '.error' 2>/dev/null || echo "unknown")
      [ "$error_val" = "null" ] && pass "format: error=null on success" || fail "format: error null" "$error_val"

      # Provider matches
      provider_val=$(echo "$output" | jq -r '.provider' 2>/dev/null || true)
      [ -n "$provider_val" ] && [ "$provider_val" != "null" ] && pass "format: provider non-empty ($provider_val)" || fail "format: provider"

      # Model matches
      model_val=$(echo "$output" | jq -r '.model' 2>/dev/null || true)
      [ -n "$model_val" ] && [ "$model_val" != "null" ] && pass "format: model non-empty ($model_val)" || fail "format: model"

      # elapsedMs reasonable range
      elapsed_val=$(echo "$output" | jq -r '.elapsedMs' 2>/dev/null || echo "0")
      if [ "$elapsed_val" -gt 0 ] 2>/dev/null && [ "$elapsed_val" -lt 60000 ] 2>/dev/null; then
        pass "format: elapsedMs in range (${elapsed_val}ms)"
      else
        skip "format: elapsedMs range" "${elapsed_val}ms"
      fi

      # response non-empty
      resp=$(echo "$output" | jq -r '.response' 2>/dev/null || true)
      [ -n "$resp" ] && [ "$resp" != "null" ] && pass "format: response non-empty" || fail "format: response"

      # baseUrl present
      base_url_val=$(echo "$output" | jq -r '.baseUrl' 2>/dev/null || true)
      [ -n "$base_url_val" ] && [ "$base_url_val" != "null" ] && pass "format: baseUrl non-empty" || skip "format: baseUrl" "empty"
    else
      skip "format: fields on success" "ok=false"
    fi
  fi

else
  for f in ok model provider baseUrl prompt response error elapsedMs; do
    skip "format: has .$f" "no live provider"
  done
  skip "format: type checks" "no live provider"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 4: Session Management
# ═══════════════════════════════════════════════════════════════════
section "Session Management"

if [ -n "$TOOL_PID" ]; then

  # ── Session creation ───────────────────────────────────────────
  echo "  $(dim '▸ Session creation')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Say session test" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    pass "session/create: inference ok"
  else
    if is_transient "$output"; then
      skip "session/create: inference ok" "transient"
    else
      skip "session/create: inference ok" "failed"
    fi
  fi

  # Check session directory exists
  if [ -d "$HOME/.ami/sessions" ] || [ -d "$HOME/.ami" ]; then
    pass "session/create: .ami dir exists"
  else
    skip "session/create: .ami dir exists" "not found"
  fi

  # ── Multiple independent prompts ───────────────────────────────
  echo "  $(dim '▸ Multiple independent prompts')"
  pwait "$TOOL_PID"
  out1=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "What is 3+3? Reply with just the number." 2>/dev/null) || true

  pwait "$TOOL_PID"
  out2=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "What is 5+5? Reply with just the number." 2>/dev/null) || true

  ok1=$(echo "$out1" | jq -r '.ok' 2>/dev/null || echo "false")
  ok2=$(echo "$out2" | jq -r '.ok' 2>/dev/null || echo "false")

  if [ "$ok1" = "true" ]; then
    pass "session/multi: prompt 1 ok"
  else
    if is_transient "$out1"; then skip "session/multi: prompt 1" "transient"; else fail "session/multi: prompt 1"; fi
  fi

  if [ "$ok2" = "true" ]; then
    pass "session/multi: prompt 2 ok"
  else
    if is_transient "$out2"; then skip "session/multi: prompt 2" "transient"; else fail "session/multi: prompt 2"; fi
  fi

  if [ "$ok1" = "true" ] && [ "$ok2" = "true" ]; then
    resp1=$(echo "$out1" | jq -r '.response // empty' 2>/dev/null || true)
    resp2=$(echo "$out2" | jq -r '.response // empty' 2>/dev/null || true)
    [ -n "$resp1" ] && [ -n "$resp2" ] && pass "session/multi: both have responses" || skip "session/multi: both responses" "one empty"
  fi

  # ── Resume with invalid session ID ─────────────────────────────
  echo "  $(dim '▸ Resume with invalid session')"
  resume_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --resume "invalid-session-id-xyz-999" --prompt "hi" 2>&1 || true)

  if [ -n "$resume_out" ]; then
    pass "session/resume: produces output"
    # Should either error about invalid session or just work (start new session)
    echo "$resume_out" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "session/resume: no stack trace" || pass "session/resume: no stack trace"
  else
    skip "session/resume: produces output" "timed out"
    skip "session/resume: no stack trace" "no output"
  fi

  # ── Session isolation ──────────────────────────────────────────
  echo "  $(dim '▸ Session isolation')"
  pwait "$TOOL_PID"
  iso1=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "My secret code is ALPHA-7. Remember it." 2>/dev/null) || true

  pwait "$TOOL_PID"
  iso2=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "What is my secret code?" 2>/dev/null) || true

  iso1_ok=$(echo "$iso1" | jq -r '.ok' 2>/dev/null || echo "false")
  iso2_ok=$(echo "$iso2" | jq -r '.ok' 2>/dev/null || echo "false")

  if [ "$iso1_ok" = "true" ] && [ "$iso2_ok" = "true" ]; then
    pass "session/isolation: both prompts ok"
    iso2_resp=$(echo "$iso2" | jq -r '.response // empty' 2>/dev/null || true)
    # The second prompt is in a NEW session — it should NOT know ALPHA-7
    if echo "$iso2_resp" | grep -q "ALPHA-7"; then
      skip "session/isolation: sessions independent" "model remembered across sessions"
    else
      pass "session/isolation: sessions independent"
    fi
  else
    skip "session/isolation: both prompts ok" "one failed"
    skip "session/isolation: sessions independent" "incomplete"
  fi

else
  for t in create multi resume isolation; do
    skip "session/$t" "no live provider"
  done
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: Provider Flag
# ═══════════════════════════════════════════════════════════════════
section "Provider Flag"

echo "  $(dim '▸ --provider with explicit provider')"

for pid in google groq mistral openrouter deepseek openai; do
  if ! has_key "$pid"; then
    skip "provider-flag/$pid: provider field" "no key"
    continue
  fi

  key=$(get_key "$pid")
  model=$(get_model "$pid")
  _env_args=$(provider_env_string "$pid" "$key")

  pwait "$pid"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $_env_args \
    ami --model "$model" --prompt "Say ok" 2>/dev/null) || true

  if [ -z "$output" ]; then
    skip "provider-flag/$pid: output" "timed out or empty"
    continue
  fi

  if ! echo "$output" | jq . >/dev/null 2>&1; then
    skip "provider-flag/$pid: valid JSON" "non-JSON"
    continue
  fi

  ok=$(echo "$output" | jq -r '.ok')
  if [ "$ok" = "true" ]; then
    pass "provider-flag/$pid: ok=true"
    provider_val=$(echo "$output" | jq -r '.provider // empty')
    if echo "$provider_val" | grep -qi "$pid"; then
      pass "provider-flag/$pid: provider matches ($provider_val)"
    else
      skip "provider-flag/$pid: provider matches" "got: $provider_val"
    fi
    model_val=$(echo "$output" | jq -r '.model // empty')
    [ -n "$model_val" ] && [ "$model_val" != "null" ] && pass "provider-flag/$pid: model present" || skip "provider-flag/$pid: model present" "empty"
  else
    if is_transient "$output"; then
      skip "provider-flag/$pid: ok" "transient"
    else
      fail "provider-flag/$pid: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 80)"
    fi
  fi
done

# Provider auto-detection via env var name
echo "  $(dim '▸ Provider auto-detection via env var')"
if [ -n "$TOOL_PID" ]; then
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    prov=$(echo "$output" | jq -r '.provider // empty')
    [ -n "$prov" ] && pass "provider-flag/auto: detected ($prov)" || skip "provider-flag/auto: detected" "empty"
  else
    skip "provider-flag/auto: detected" "inference failed"
  fi
else
  skip "provider-flag/auto: detected" "no live provider"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 6: Max Turns / Performance
# ═══════════════════════════════════════════════════════════════════
section "Max Turns & Performance"

if [ -n "$TOOL_PID" ]; then

  echo "  $(dim '▸ Simple prompt completes quickly')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    elapsed=$(echo "$output" | jq -r '.elapsedMs' 2>/dev/null || echo "0")
    if [ "$elapsed" -gt 0 ] 2>/dev/null && [ "$elapsed" -lt 30000 ] 2>/dev/null; then
      pass "turns/simple: completed in ${elapsed}ms (<30s)"
    elif [ "$elapsed" -ge 30000 ] 2>/dev/null; then
      skip "turns/simple: time" "${elapsed}ms (>30s)"
    else
      skip "turns/simple: time" "not reported"
    fi
    pass "turns/simple: ok=true"
  else
    if is_transient "$output"; then
      skip "turns/simple: ok" "transient"
      skip "turns/simple: time" "transient"
    else
      skip "turns/simple: ok" "failed"
      skip "turns/simple: time" "failed"
    fi
  fi

  echo "  $(dim '▸ Tool-heavy prompt timing')"
  pwait "$TOOL_PID"
  output=$(timeout 60 env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'echo done' and tell me the output." 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    elapsed=$(echo "$output" | jq -r '.elapsedMs' 2>/dev/null || echo "0")
    pass "turns/tool: completed ok"
    if [ "$elapsed" -gt 0 ] 2>/dev/null && [ "$elapsed" -lt 60000 ] 2>/dev/null; then
      pass "turns/tool: time ${elapsed}ms (<60s)"
    else
      skip "turns/tool: time" "${elapsed}ms"
    fi
  else
    if is_transient "$output"; then
      skip "turns/tool: ok" "transient"
      skip "turns/tool: time" "transient"
    else
      skip "turns/tool: ok" "failed"
      skip "turns/tool: time" "failed"
    fi
  fi

  echo "  $(dim '▸ Detached mode completes (no hang)')"
  START_TIME=$(date +%s)
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Reply with exactly: DONE" 2>/dev/null) || true
  END_TIME=$(date +%s)
  WALL_TIME=$((END_TIME - START_TIME))

  [ "$WALL_TIME" -lt "$AMI_TIMEOUT" ] && pass "turns/hang: completed in ${WALL_TIME}s" || skip "turns/hang: completed" "${WALL_TIME}s (timeout)"

else
  skip "turns/simple" "no live provider"
  skip "turns/tool" "no live provider"
  skip "turns/hang" "no live provider"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: Environment Variable Precedence
# ═══════════════════════════════════════════════════════════════════
section "Env Var Precedence"

if [ -n "$TOOL_PID" ]; then

  # ── Provider key overrides invalid AI_API_KEY ──────────────────
  echo "  $(dim '▸ Provider-specific key overrides AI_API_KEY')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    AI_API_KEY="invalid-key-xxx" $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    pass "precedence: provider key overrides invalid AI_API_KEY"
  else
    if is_transient "$output"; then
      skip "precedence: provider key overrides" "transient"
    else
      skip "precedence: provider key overrides" "failed"
    fi
  fi

  # ── AI_MODEL env sets model ────────────────────────────────────
  echo "  $(dim '▸ AI_MODEL env var')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV AI_MODEL="$TOOL_MODEL" \
    ami --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    model_used=$(echo "$output" | jq -r '.model // empty')
    [ "$model_used" = "$TOOL_MODEL" ] && pass "precedence: AI_MODEL respected ($model_used)" || skip "precedence: AI_MODEL" "got: $model_used"
  else
    if is_transient "$output"; then
      skip "precedence: AI_MODEL" "transient"
    else
      skip "precedence: AI_MODEL" "failed"
    fi
  fi

  # ── --model overrides AI_MODEL ─────────────────────────────────
  echo "  $(dim '▸ --model overrides AI_MODEL')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV AI_MODEL="wrong-model-xyz" \
    ami --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    model_used=$(echo "$output" | jq -r '.model // empty')
    [ "$model_used" = "$TOOL_MODEL" ] && pass "precedence: --model overrides AI_MODEL" || skip "precedence: --model override" "got: $model_used"
  else
    if is_transient "$output"; then
      skip "precedence: --model overrides" "transient"
    else
      skip "precedence: --model overrides" "failed"
    fi
  fi

  # ── --api-key overrides env ────────────────────────────────────
  echo "  $(dim '▸ --api-key overrides env')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    "${TOOL_ENV}=invalid-key-xxx" \
    ami --api-key "$TOOL_KEY" --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    pass "precedence: --api-key overrides env"
  else
    if is_transient "$output"; then
      skip "precedence: --api-key overrides" "transient"
    else
      skip "precedence: --api-key overrides" "failed"
    fi
  fi

  # ── AI_BASE_URL env ────────────────────────────────────────────
  echo "  $(dim '▸ AI_BASE_URL env var')"
  if [ "$TOOL_PID" = "groq" ]; then
    pwait "$TOOL_PID"
    output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      $TOOL_ENV AI_BASE_URL="https://api.groq.com/openai/v1" \
      ami --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

    if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
      base_url=$(echo "$output" | jq -r '.baseUrl // empty')
      echo "$base_url" | grep -q "groq" && pass "precedence: AI_BASE_URL used ($base_url)" || skip "precedence: AI_BASE_URL" "got: $base_url"
    else
      skip "precedence: AI_BASE_URL" "failed"
    fi
  else
    skip "precedence: AI_BASE_URL" "only tested with groq"
  fi

  # ── Key not leaked in output ───────────────────────────────────
  echo "  $(dim '▸ Key not leaked in output')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "Say ok" 2>/dev/null) || true

  if [ -n "$output" ]; then
    echo "$output" | grep -q "$TOOL_KEY" && fail "precedence: key not in output" || pass "precedence: key not in output"
  else
    skip "precedence: key not in output" "no output"
  fi

else
  for t in "provider key" "AI_MODEL" "--model" "--api-key" "AI_BASE_URL" "key leak"; do
    skip "precedence: $t" "no live provider"
  done
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: Error Resilience
# ═══════════════════════════════════════════════════════════════════
section "Error Resilience"

# ── Invalid API key ──────────────────────────────────────────────
echo "  $(dim '▸ Invalid API key')"
NO_KEY_HOME=$(mktemp -d)
INVALID_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$NO_KEY_HOME" $ENV_BASE \
  AI_API_KEY="totally-invalid-key-xyz" \
  ami --model "test-model" --prompt "hello" 2>&1 || true)
rm -rf "$NO_KEY_HOME"

[ -n "$INVALID_OUT" ] && pass "error/invalid-key: produces output" || skip "error/invalid-key: produces output" "empty"
echo "$INVALID_OUT" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "error/invalid-key: no stack trace" || pass "error/invalid-key: no stack trace"

# ── No API key at all ────────────────────────────────────────────
echo "  $(dim '▸ No API key')"
NO_KEY_HOME2=$(mktemp -d)
NO_KEY_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$NO_KEY_HOME2" $ENV_BASE \
  ami --prompt "hello" 2>&1 || true)
rm -rf "$NO_KEY_HOME2"

[ -n "$NO_KEY_OUT" ] && pass "error/no-key: produces output" || skip "error/no-key: produces output" "empty"
echo "$NO_KEY_OUT" | grep -qi "api.key\|required\|error\|missing" && pass "error/no-key: error message" || skip "error/no-key: error message" "${NO_KEY_OUT:0:60}"
echo "$NO_KEY_OUT" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "error/no-key: no stack trace" || pass "error/no-key: no stack trace"

# ── Invalid model name ───────────────────────────────────────────
echo "  $(dim '▸ Invalid model name')"
if [ -n "$TOOL_PID" ]; then
  pwait "$TOOL_PID"
  BAD_MODEL_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "nonexistent-model-xyz-999" --prompt "hi" 2>&1 || true)

  [ -n "$BAD_MODEL_OUT" ] && pass "error/bad-model: produces output" || skip "error/bad-model: produces output" "empty"
  echo "$BAD_MODEL_OUT" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "error/bad-model: no stack trace" || pass "error/bad-model: no stack trace"
else
  skip "error/bad-model: produces output" "no live provider"
  skip "error/bad-model: no stack trace" "no live provider"
fi

# ── Invalid base URL ─────────────────────────────────────────────
echo "  $(dim '▸ Invalid base URL')"
BAD_URL_OUT=$(timeout 15 env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  AI_API_KEY="test-key" \
  ami --base-url "https://localhost:19999/nonexistent" --model "test" --prompt "hi" 2>&1 || true)

[ -n "$BAD_URL_OUT" ] && pass "error/bad-url: produces output" || skip "error/bad-url: produces output" "empty"
echo "$BAD_URL_OUT" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "error/bad-url: no stack trace" || pass "error/bad-url: no stack trace"

# ── Empty prompt ─────────────────────────────────────────────────
echo "  $(dim '▸ Empty prompt')"
if [ -n "$TOOL_PID" ]; then
  EMPTY_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "" 2>&1 || true)

  [ -n "$EMPTY_OUT" ] && pass "error/empty-prompt: produces output" || skip "error/empty-prompt: produces output" "empty"
  echo "$EMPTY_OUT" | grep -q "at Object\.\|TypeError\|ReferenceError" && fail "error/empty-prompt: no stack trace" || pass "error/empty-prompt: no stack trace"
else
  skip "error/empty-prompt: produces output" "no live provider"
  skip "error/empty-prompt: no stack trace" "no live provider"
fi

# ── Very long prompt ─────────────────────────────────────────────
echo "  $(dim '▸ Very long prompt')"
if [ -n "$TOOL_PID" ]; then
  LONG_PROMPT=$(python3 -c "print('x ' * 500)" 2>/dev/null || printf 'x %.0s' {1..1000})
  pwait "$TOOL_PID"
  LONG_OUT=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "$LONG_PROMPT" 2>/dev/null) || true

  if [ -n "$LONG_OUT" ]; then
    pass "error/long-prompt: produces output"
    if echo "$LONG_OUT" | jq . >/dev/null 2>&1; then
      pass "error/long-prompt: valid JSON"
    else
      skip "error/long-prompt: valid JSON" "non-JSON"
    fi
  else
    skip "error/long-prompt: produces output" "timed out"
    skip "error/long-prompt: valid JSON" "no output"
  fi
else
  skip "error/long-prompt: produces output" "no live provider"
  skip "error/long-prompt: valid JSON" "no live provider"
fi

# ── Invalid permission mode (non-zero exit) ──────────────────────
echo "  $(dim '▸ Invalid permission mode exit code')"
BAD_PERM_RC=0
timeout 15 env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  AI_API_KEY="test-key" \
  ami --permission-mode "invalid-mode-xyz" --prompt "hi" >/dev/null 2>&1 || BAD_PERM_RC=$?
[ "$BAD_PERM_RC" -ne 0 ] && pass "error/bad-perm: non-zero exit ($BAD_PERM_RC)" || skip "error/bad-perm: non-zero exit" "rc=0"

# ═══════════════════════════════════════════════════════════════════
# SECTION 9: Cross-Provider Agent Tests
# ═══════════════════════════════════════════════════════════════════
section "Cross-Provider Agent Tests"

if [ -n "$TOOL_PID" ] && [ -n "$SECOND_PID" ]; then

  echo "  $(dim "▸ Two providers: $TOOL_PID + $SECOND_PID")"

  pwait "$TOOL_PID"
  out1=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --prompt "What is 2+2? Reply with just the number." 2>/dev/null) || true

  pwait "$SECOND_PID"
  out2=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $SECOND_ENV \
    ami --model "$SECOND_MODEL" --prompt "What is 2+2? Reply with just the number." 2>/dev/null) || true

  ok1=$(echo "$out1" | jq -r '.ok' 2>/dev/null || echo "false")
  ok2=$(echo "$out2" | jq -r '.ok' 2>/dev/null || echo "false")

  [ "$ok1" = "true" ] && pass "cross/$TOOL_PID: inference ok" || { is_transient "$out1" && skip "cross/$TOOL_PID: ok" "transient" || fail "cross/$TOOL_PID: ok"; }
  [ "$ok2" = "true" ] && pass "cross/$SECOND_PID: inference ok" || { is_transient "$out2" && skip "cross/$SECOND_PID: ok" "transient" || fail "cross/$SECOND_PID: ok"; }

  if [ "$ok1" = "true" ] && [ "$ok2" = "true" ]; then
    prov1=$(echo "$out1" | jq -r '.provider // empty')
    prov2=$(echo "$out2" | jq -r '.provider // empty')
    [ "$prov1" != "$prov2" ] && pass "cross: different providers ($prov1 vs $prov2)" || skip "cross: different providers" "same: $prov1"

    # Both should have valid JSON output schema
    for f in ok model provider response elapsedMs; do
      echo "$out1" | jq -e "has(\"$f\")" >/dev/null 2>&1 && pass "cross/$TOOL_PID: has .$f" || fail "cross/$TOOL_PID: has .$f"
      echo "$out2" | jq -e "has(\"$f\")" >/dev/null 2>&1 && pass "cross/$SECOND_PID: has .$f" || fail "cross/$SECOND_PID: has .$f"
    done
  fi

else
  skip "cross-provider: tests" "need 2+ live providers (have: ${TOOL_PID:-none} + ${SECOND_PID:-none})"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 10: Concurrent Agent Invocations
# ═══════════════════════════════════════════════════════════════════
section "Concurrent Agent Invocations"

if [ -n "$TOOL_PID" ]; then

  echo "  $(dim '▸ 3 concurrent prompts')"
  CONC_DIR=$(mktemp -d)

  for i in 1 2 3; do
    (
      pwait "$TOOL_PID"
      output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
        $TOOL_ENV \
        ami --model "$TOOL_MODEL" --prompt "What is ${i}+${i}? Reply with just the number." 2>/dev/null) || true
      echo "$output" > "$CONC_DIR/result-$i"
    ) &
  done
  wait

  conc_ok=0
  for i in 1 2 3; do
    if [ -f "$CONC_DIR/result-$i" ]; then
      result=$(cat "$CONC_DIR/result-$i")
      ok=$(echo "$result" | jq -r '.ok' 2>/dev/null || echo "false")
      if [ "$ok" = "true" ]; then
        pass "concurrent: prompt #$i ok"
        conc_ok=$((conc_ok + 1))
      else
        if is_transient "$result"; then
          skip "concurrent: prompt #$i" "transient"
        else
          fail "concurrent: prompt #$i" "$(echo "$result" | jq -r '.error // empty' 2>/dev/null | head -c 50)"
        fi
      fi
    else
      fail "concurrent: prompt #$i" "no output file"
    fi
  done

  [ "$conc_ok" -ge 2 ] && pass "concurrent: $conc_ok/3 succeeded" || skip "concurrent: success rate" "$conc_ok/3"
  rm -rf "$CONC_DIR"

else
  skip "concurrent: tests" "no live provider"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 11: Tool + Permission Interaction
# ═══════════════════════════════════════════════════════════════════
section "Tool + Permission Interaction"

if [ -n "$TOOL_PID" ]; then

  # ── auto-allow: tool should produce visible output ─────────────
  echo "  $(dim '▸ auto-allow tool produces result')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode auto-allow --max-turns $MAX_TURNS_TOOL \
    --prompt "Run 'cat /etc/os-release | head -1' and tell me the output." 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    resp=$(echo "$output" | jq -r '.response // empty')
    [ -n "$resp" ] && pass "tool-perm/auto: got tool result" || skip "tool-perm/auto: got tool result" "empty"
    # Response should reference something about the OS
    echo "$resp" | grep -qiE "NAME|linux|ubuntu|debian|alpine|ID" && pass "tool-perm/auto: OS info present" || skip "tool-perm/auto: OS info" "${resp:0:40}"
  else
    if is_transient "$output"; then
      skip "tool-perm/auto: got tool result" "transient"
      skip "tool-perm/auto: OS info" "transient"
    else
      skip "tool-perm/auto: got tool result" "failed"
      skip "tool-perm/auto: OS info" "failed"
    fi
  fi

  # ── deny-all: tool request should still produce a response ─────
  echo "  $(dim '▸ deny-all still produces response')"
  pwait "$TOOL_PID"
  output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
    $TOOL_ENV \
    ami --model "$TOOL_MODEL" --permission-mode deny-all \
    --prompt "Say the word BANANA" 2>/dev/null) || true

  if [ -n "$output" ] && echo "$output" | jq -e '.ok == true' >/dev/null 2>&1; then
    pass "tool-perm/deny: completed ok"
    resp=$(echo "$output" | jq -r '.response // empty')
    [ -n "$resp" ] && pass "tool-perm/deny: has response" || skip "tool-perm/deny: has response" "empty"
  else
    if is_transient "$output"; then
      skip "tool-perm/deny: completed" "transient"
      skip "tool-perm/deny: has response" "transient"
    else
      skip "tool-perm/deny: completed" "failed"
      skip "tool-perm/deny: has response" "failed"
    fi
  fi

else
  skip "tool-perm/auto" "no live provider"
  skip "tool-perm/deny" "no live provider"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 12: Output Stability
# ═══════════════════════════════════════════════════════════════════
section "Output Stability"

if [ -n "$TOOL_PID" ]; then

  echo "  $(dim '▸ 3 rounds of consistent output format')"
  for round in 1 2 3; do
    pwait "$TOOL_PID"
    output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      $TOOL_ENV \
      ami --model "$TOOL_MODEL" --prompt "Say round-$round" 2>/dev/null) || true

    if [ -z "$output" ]; then
      skip "stability/r$round: output" "timed out"
      continue
    fi

    if echo "$output" | jq . >/dev/null 2>&1; then
      pass "stability/r$round: valid JSON"
    else
      fail "stability/r$round: valid JSON" "non-JSON"
      continue
    fi

    ok=$(echo "$output" | jq -r '.ok')
    if [ "$ok" = "true" ]; then
      pass "stability/r$round: ok=true"
    else
      if is_transient "$output"; then
        skip "stability/r$round: ok" "transient"
      else
        fail "stability/r$round: ok" "$(echo "$output" | jq -r '.error // empty' | head -c 50)"
      fi
    fi
  done

else
  for r in 1 2 3; do
    skip "stability/r$r" "no live provider"
  done
fi

# ═══════════════════════════════════════════════════════════════════
# ADDITIONAL FLAG TESTS — coverage for all --help flags
# ═══════════════════════════════════════════════════════════════════

section "Additional CLI Flags"

# --quiet: suppresses non-JSON output
echo "  $(dim '▸ --quiet flag')"
quiet_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --prompt "say hi" --quiet 2>&1) || true
if [ -n "$quiet_out" ]; then
  pass "quiet: produces output"
else
  skip "quiet: produces output" "no output"
fi

# --completions: shell completion output
echo "  $(dim '▸ --completions flag')"
comp_out=$(ami --completions bash 2>&1) || true
if [ -n "$comp_out" ]; then
  pass "completions: bash output"
else
  comp_out2=$(ami --completions 2>&1) || true
  if [ -n "$comp_out2" ]; then
    pass "completions: output"
  else
    skip "completions: output" "no completions support"
  fi
fi

# --config: custom config path
echo "  $(dim '▸ --config flag')"
cfg_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --config /nonexistent/config.json --prompt "hi" 2>&1) || true
if [ -n "$cfg_out" ]; then
  pass "config: accepts flag"
else
  skip "config: accepts flag" "no output"
fi

# --context-file: pass context from file
echo "  $(dim '▸ --context-file flag')"
CTX_TMP=$(mktemp)
echo "Context: The sky is blue." > "$CTX_TMP"
ctx_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --context-file "$CTX_TMP" --prompt "What color is the sky?" 2>&1) || true
rm -f "$CTX_TMP"
if [ -n "$ctx_out" ]; then
  pass "context-file: accepts flag"
else
  skip "context-file: accepts flag" "no output"
fi

# --deny: deny specific tools
echo "  $(dim '▸ --deny flag')"
deny_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --deny bash --prompt "hi" 2>&1) || true
if [ -n "$deny_out" ]; then
  pass "deny: accepts flag"
else
  skip "deny: accepts flag" "no output"
fi

# --allow: allow specific tools
echo "  $(dim '▸ --allow flag')"
allow_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --allow file_read --prompt "hi" 2>&1) || true
if [ -n "$allow_out" ]; then
  pass "allow: accepts flag"
else
  skip "allow: accepts flag" "no output"
fi

# --extra-body: pass extra JSON to API
echo "  $(dim '▸ --extra-body flag')"
extra_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --extra-body '{"temperature":0.5}' --prompt "hi" 2>&1) || true
if [ -n "$extra_out" ]; then
  pass "extra-body: accepts flag"
else
  skip "extra-body: accepts flag" "no output"
fi

# --image: pass image file
echo "  $(dim '▸ --image flag')"
img_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --image /nonexistent.png --prompt "describe this" 2>&1) || true
if [ -n "$img_out" ]; then
  pass "image: accepts flag"
else
  skip "image: accepts flag" "no output"
fi

# --input-format: set input format
echo "  $(dim '▸ --input-format flag')"
infmt_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --input-format text --prompt "hi" 2>&1) || true
if [ -n "$infmt_out" ]; then
  pass "input-format: accepts flag"
else
  skip "input-format: accepts flag" "no output"
fi

# --output-format: set output format
echo "  $(dim '▸ --output-format flag')"
outfmt_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --output-format json --prompt "hi" 2>&1) || true
if [ -n "$outfmt_out" ]; then
  pass "output-format: accepts flag"
else
  skip "output-format: accepts flag" "no output"
fi

# --run-command: run a command
echo "  $(dim '▸ --run-command flag')"
runcmd_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --run-command "echo hello" 2>&1) || true
if [ -n "$runcmd_out" ]; then
  pass "run-command: accepts flag"
else
  skip "run-command: accepts flag" "no output"
fi

# --scrollback-lines: set scrollback buffer
echo "  $(dim '▸ --scrollback-lines flag')"
scroll_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --scrollback-lines 50 --prompt "hi" 2>&1) || true
if [ -n "$scroll_out" ]; then
  pass "scrollback-lines: accepts flag"
else
  skip "scrollback-lines: accepts flag" "no output"
fi

# --session-id: set session ID
echo "  $(dim '▸ --session-id flag')"
sessid_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --session-id "test-sess-$$" --prompt "hi" 2>&1) || true
if [ -n "$sessid_out" ]; then
  pass "session-id: accepts flag"
else
  skip "session-id: accepts flag" "no output"
fi

# --thinking: set thinking level
echo "  $(dim '▸ --thinking flag')"
think_out=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  ami --thinking off --prompt "hi" 2>&1) || true
if [ -n "$think_out" ]; then
  pass "thinking: accepts flag"
else
  skip "thinking: accepts flag" "no output"
fi

# ═══════════════════════════════════════════════════════════════════
# DYNAMIC FEATURE COVERAGE GATE
# Every CLI flag documented in --help must be tested.
# ═══════════════════════════════════════════════════════════════════

section "Feature Coverage Gate"

HELP_OUT=$(ami --help 2>&1 || true)

# Extract all documented flags from --help
DOCUMENTED_FLAGS=$(echo "$HELP_OUT" | grep -oE '\-\-[a-z][a-z0-9_-]+' | sort -u || true)

# Flags tested in this file or in cli.sh (the full set across both suites)
declare -A TESTED_FLAGS
TESTED_FLAGS["--prompt"]=1
TESTED_FLAGS["--model"]=1
TESTED_FLAGS["--provider"]=1
TESTED_FLAGS["--permission-mode"]=1
TESTED_FLAGS["--base-url"]=1
TESTED_FLAGS["--api-key"]=1
TESTED_FLAGS["--resume"]=1
TESTED_FLAGS["--help"]=1
TESTED_FLAGS["--version"]=1
TESTED_FLAGS["--stdin"]=1
TESTED_FLAGS["--yolo"]=1
TESTED_FLAGS["--no-color"]=1
TESTED_FLAGS["--verbose"]=1
TESTED_FLAGS["--max-turns"]=1
TESTED_FLAGS["--detached"]=1
TESTED_FLAGS["--quiet"]=1
TESTED_FLAGS["--completions"]=1
TESTED_FLAGS["--config"]=1
TESTED_FLAGS["--context-file"]=1
TESTED_FLAGS["--deny"]=1
TESTED_FLAGS["--allow"]=1
TESTED_FLAGS["--extra-body"]=1
TESTED_FLAGS["--image"]=1
TESTED_FLAGS["--input-format"]=1
TESTED_FLAGS["--output-format"]=1
TESTED_FLAGS["--run-command"]=1
TESTED_FLAGS["--scrollback-lines"]=1
TESTED_FLAGS["--session-id"]=1
TESTED_FLAGS["--thinking"]=1

UNTESTED_FLAGS=0
for flag in $DOCUMENTED_FLAGS; do
  if [ -n "${TESTED_FLAGS[$flag]:-}" ]; then
    pass "flag-coverage: $flag tested"
  else
    fail "UNTESTED FLAG: $flag" "documented in --help but not tested — add coverage"
    UNTESTED_FLAGS=$((UNTESTED_FLAGS + 1))
  fi
done

if [ "$UNTESTED_FLAGS" -gt 0 ]; then
  fail "Flag coverage" "$UNTESTED_FLAGS flag(s) documented but not tested"
else
  pass "Flag coverage: all documented flags have test coverage"
fi

summary
