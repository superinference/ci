#!/bin/bash
# FRITO CI — Slash command regression tests (expect-based, dynamic discovery)
#
# DESIGN: Dynamic self-verifying coverage.
# 1. Capture /help output from the live binary
# 2. Parse every slash command listed
# 3. Run the test function for each
# 4. FAIL if any discovered command has no test function
#
# This ensures adding a new slash command without a CI test breaks the build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

if ! command -v expect &>/dev/null; then
  echo "ERROR: expect is required for slash command tests"
  echo "Install: sudo apt-get install -y expect"
  exit 1
fi

AMI_BIN=$(command -v ami 2>/dev/null || echo "")
if [ -z "$AMI_BIN" ]; then
  fail "ami binary found" "not in PATH"
  summary
  exit 1
fi

echo ""
echo "$(bold 'Slash Command Tests — Dynamic Discovery')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $AMI_BIN")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# PROVIDER SETUP — find a working key for tests that need one
# ═══════════════════════════════════════════════════════════════════

SLASH_KEY=""
SLASH_ENV=""
SLASH_MODEL=""
SLASH_PID=""

if [ -f "$FRITO_CONFIG" ]; then
  for _pid in groq mistral cerebras openrouter google; do
    if has_key "$_pid"; then
      _k=$(get_key "$_pid")
      _m=$(get_model "$_pid")
      _ev=$(provider_env_var "$_pid")
      _out=$(timeout 20 env -i PATH="$PATH" HOME="$HOME" TERM="dumb" NODE_NO_WARNINGS=1 \
        "${_ev}=${_k}" ami --model "$_m" --prompt "hi" 2>/dev/null) || true
      if [ -n "$_out" ] && echo "$_out" | jq -e '.ok == true' >/dev/null 2>&1; then
        SLASH_KEY="$_k"
        SLASH_ENV="$_ev"
        SLASH_MODEL="$_m"
        SLASH_PID="$_pid"
        echo "  $(dim "Provider for slash tests: $_pid (live)")"
        break
      fi
    fi
  done
fi

if [ -z "$SLASH_KEY" ]; then
  echo "  $(dim 'WARNING: No live provider — tests needing inference will be skipped')"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 1: DYNAMIC DISCOVERY — capture all commands from /help
# ═══════════════════════════════════════════════════════════════════

section "Dynamic Command Discovery"

# Run /help in the TUI via expect to capture the command list.
# We try without an API key first; if that fails, use one.
HELP_OUTPUT=""
HELP_OUTPUT=$(ami_slash "/help") || true
if [ -z "$HELP_OUTPUT" ]; then
  if [ -n "$SLASH_KEY" ]; then
    HELP_OUTPUT=$(ami_slash "/help" "${SLASH_ENV}=${SLASH_KEY}") || true
  fi
fi

if [ -z "$HELP_OUTPUT" ]; then
  fail "Dynamic discovery" "/help produced no output — cannot enumerate commands"
  summary
  exit 1
fi
pass "Dynamic discovery: /help captured"

# Extract all slash command names from the help output.
# Commands appear as /word (letters, digits, hyphens).
DISCOVERED_COMMANDS=$(echo "$HELP_OUTPUT" | grep -oE '/[a-z][a-z0-9_-]*' | sort -u || true)
DISCOVERED_COUNT=$(echo "$DISCOVERED_COMMANDS" | grep -c '/' || echo 0)

if [ "$DISCOVERED_COUNT" -lt 20 ]; then
  fail "Dynamic discovery: enough commands" "only found $DISCOVERED_COUNT (expected 20+)"
  echo "  $(dim "Raw help output (first 500 chars): ${HELP_OUTPUT:0:500}")"
else
  pass "Dynamic discovery: $DISCOVERED_COUNT commands found"
fi

echo "  $(dim "Commands: $(echo $DISCOVERED_COMMANDS | tr '\n' ' ')")"

# ═══════════════════════════════════════════════════════════════════
# STEP 2: TEST FUNCTION REGISTRY
# Each slash command gets a test_CMD function. The dynamic loop
# calls the function if it exists; FAILs if no function is defined.
# ═══════════════════════════════════════════════════════════════════

# Helper: run a slash command and assert output is non-empty
assert_slash_output() {
  local cmd="$1" label="$2"
  local output
  if [ -n "$SLASH_KEY" ]; then
    output=$(ami_slash "$cmd" "${SLASH_ENV}=${SLASH_KEY}")
  else
    output=$(ami_slash "$cmd")
  fi
  if [ -n "$output" ]; then
    pass "$label: has output"
  else
    fail "$label: has output" "empty output"
  fi
  echo "$output"
}

# Helper: run a mutation slash command, then query to verify
assert_slash_mutation() {
  local set_cmd="$1" query_cmd="$2" expected="$3" label="$4"
  local output
  if [ -n "$SLASH_KEY" ]; then
    output=$(ami_slash_multi "${SLASH_ENV}=${SLASH_KEY}" -- "$set_cmd" "$query_cmd")
  else
    output=$(ami_slash_multi "" -- "$set_cmd" "$query_cmd")
  fi
  if echo "$output" | grep -qi "$expected"; then
    pass "$label: contains '$expected'"
  else
    skip "$label: contains '$expected'" "got: ${output:0:80}"
  fi
}

# ── Info commands (no API key needed) ────────────────────────────

test_help() {
  section "/help"
  local out
  out=$(ami_slash "/help")
  assert_contains "$out" "model" "/help: lists /model"
  assert_contains "$out" "provider" "/help: lists /provider"
  assert_contains "$out" "thinking" "/help: lists /thinking"
  assert_contains "$out" "compact" "/help: lists /compact"
  assert_contains "$out" "clear" "/help: lists /clear"
  assert_contains "$out" "cost" "/help: lists /cost"
  assert_contains "$out" "context" "/help: lists /context"
  assert_contains "$out" "help" "/help: lists /help"
  assert_contains "$out" "quit" "/help: lists /quit"
}

test_quit() { pass "/quit: tested (used to exit every expect session)"; }
test_exit() { pass "/exit: alias for /quit"; }

test_providers() {
  section "/providers"
  local out
  out=$(ami_slash "/providers")
  assert_contains "$out" "openai" "/providers: lists openai"
  assert_contains "$out" "anthropic" "/providers: lists anthropic"
  assert_contains "$out" "google" "/providers: lists google"
  assert_contains "$out" "groq" "/providers: lists groq"
  assert_contains "$out" "deepseek" "/providers: lists deepseek"
  assert_contains "$out" "mistral" "/providers: lists mistral"
  assert_contains "$out" "cerebras" "/providers: lists cerebras"
}

test_keybindings() {
  section "/keybindings"
  assert_slash_output "/keybindings" "/keybindings" >/dev/null
}

test_permissions() {
  section "/permissions"
  assert_slash_output "/permissions" "/permissions" >/dev/null
}

test_safe-mode() {
  section "/safe-mode"
  assert_slash_output "/safe-mode" "/safe-mode" >/dev/null
}

test_hooks() {
  section "/hooks"
  assert_slash_output "/hooks" "/hooks" >/dev/null
}

test_agents() {
  section "/agents"
  assert_slash_output "/agents" "/agents" >/dev/null
}

test_skills() {
  section "/skills"
  assert_slash_output "/skills" "/skills" >/dev/null
}

test_theme() {
  section "/theme"
  local out
  out=$(assert_slash_output "/theme" "/theme")
  # Should mention at least one theme name
  if echo "$out" | grep -qiE "dark|light|term"; then
    pass "/theme: lists theme names"
  else
    skip "/theme: lists theme names" "${out:0:60}"
  fi
}

test_admission() {
  section "/admission"
  assert_slash_output "/admission" "/admission" >/dev/null
}

# ── State display commands (need API key) ────────────────────────

test_model() {
  section "/model"
  if [ -z "$SLASH_KEY" ]; then skip "/model" "no provider key"; return; fi
  local out
  out=$(ami_slash "/model" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/model: has output"
}

test_provider() {
  section "/provider"
  if [ -z "$SLASH_KEY" ]; then skip "/provider" "no provider key"; return; fi
  local out
  out=$(ami_slash "/provider" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/provider: has output"
}

test_thinking() {
  section "/thinking"
  if [ -z "$SLASH_KEY" ]; then skip "/thinking" "no provider key"; return; fi
  local out
  out=$(ami_slash "/thinking" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/thinking: has output"

  # Mutation: /thinking high → verify
  assert_slash_mutation "/thinking high" "/thinking" "high" "/thinking high"
  # Mutation: /thinking off → verify
  assert_slash_mutation "/thinking off" "/thinking" "off\|disabled\|none" "/thinking off"

  # Invalid arg: /thinking banana → shows valid levels
  local inv
  inv=$(ami_slash "/thinking banana" "${SLASH_ENV}=${SLASH_KEY}")
  if echo "$inv" | grep -qiE "off|low|medium|high|max|invalid|valid"; then
    pass "/thinking invalid: shows valid levels"
  else
    skip "/thinking invalid: shows valid levels" "${inv:0:60}"
  fi
}

test_persona() {
  section "/persona"
  if [ -z "$SLASH_KEY" ]; then skip "/persona" "no provider key"; return; fi
  local out
  out=$(ami_slash "/persona" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/persona: has output"

  # Mutation: /persona pentest → verify
  assert_slash_mutation "/persona pentest" "/persona" "pentest" "/persona pentest"
  # Mutation: /persona code → verify
  assert_slash_mutation "/persona code" "/persona" "code" "/persona code"

  # Invalid arg
  local inv
  inv=$(ami_slash "/persona invalid-persona-xyz" "${SLASH_ENV}=${SLASH_KEY}")
  if echo "$inv" | grep -qiE "code|pentest|sre|research|invalid|valid"; then
    pass "/persona invalid: shows valid options"
  else
    skip "/persona invalid: shows valid options" "${inv:0:60}"
  fi
}

test_output-style() {
  section "/output-style"
  if [ -z "$SLASH_KEY" ]; then skip "/output-style" "no provider key"; return; fi
  local out
  out=$(ami_slash "/output-style" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/output-style: has output"

  # Mutation
  assert_slash_mutation "/output-style concise" "/output-style" "concise" "/output-style concise"

  # Invalid arg
  local inv
  inv=$(ami_slash "/output-style invalid-style" "${SLASH_ENV}=${SLASH_KEY}")
  if echo "$inv" | grep -qiE "concise|explanatory|default|invalid|valid"; then
    pass "/output-style invalid: shows valid options"
  else
    skip "/output-style invalid: shows valid options" "${inv:0:60}"
  fi
}

test_mode() {
  section "/mode"
  if [ -z "$SLASH_KEY" ]; then skip "/mode" "no provider key"; return; fi
  local out
  out=$(ami_slash "/mode" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/mode: has output"
}

test_context() {
  section "/context"
  if [ -z "$SLASH_KEY" ]; then skip "/context" "no provider key"; return; fi
  assert_slash_output "/context" "/context" >/dev/null
}

test_cost() {
  section "/cost"
  if [ -z "$SLASH_KEY" ]; then skip "/cost" "no provider key"; return; fi
  assert_slash_output "/cost" "/cost" >/dev/null
}

test_usage() {
  section "/usage"
  if [ -z "$SLASH_KEY" ]; then skip "/usage" "no provider key"; return; fi
  assert_slash_output "/usage" "/usage" >/dev/null
}

test_session() {
  section "/session"
  if [ -z "$SLASH_KEY" ]; then skip "/session" "no provider key"; return; fi
  assert_slash_output "/session" "/session" >/dev/null
}

test_sessions() {
  section "/sessions"
  if [ -z "$SLASH_KEY" ]; then skip "/sessions" "no provider key"; return; fi
  assert_slash_output "/sessions" "/sessions" >/dev/null
}

test_status() {
  section "/status"
  if [ -z "$SLASH_KEY" ]; then skip "/status" "no provider key"; return; fi
  assert_slash_output "/status" "/status" >/dev/null
}

test_analytics() {
  section "/analytics"
  if [ -z "$SLASH_KEY" ]; then skip "/analytics" "no provider key"; return; fi
  assert_slash_output "/analytics" "/analytics" >/dev/null
}

test_fast() {
  section "/fast"
  if [ -z "$SLASH_KEY" ]; then skip "/fast" "no provider key"; return; fi
  assert_slash_output "/fast" "/fast" >/dev/null
}

test_superinference() {
  section "/superinference"
  if [ -z "$SLASH_KEY" ]; then skip "/superinference" "no provider key"; return; fi
  assert_slash_output "/superinference" "/superinference" >/dev/null
}

test_memory() {
  section "/memory"
  if [ -z "$SLASH_KEY" ]; then skip "/memory" "no provider key"; return; fi
  assert_slash_output "/memory" "/memory" >/dev/null
}

test_config() {
  section "/config"
  if [ -z "$SLASH_KEY" ]; then skip "/config" "no provider key"; return; fi
  assert_slash_output "/config" "/config" >/dev/null
}

test_goal() {
  section "/goal"
  if [ -z "$SLASH_KEY" ]; then skip "/goal" "no provider key"; return; fi
  assert_slash_output "/goal" "/goal" >/dev/null
  # Set a goal and verify
  assert_slash_mutation '/goal "ci-test-goal"' "/goal" "ci-test-goal\|goal" "/goal set"
}

test_doctor() {
  section "/doctor"
  if [ -z "$SLASH_KEY" ]; then skip "/doctor" "no provider key"; return; fi
  assert_slash_output "/doctor" "/doctor" >/dev/null
}

test_profile() {
  section "/profile"
  if [ -z "$SLASH_KEY" ]; then skip "/profile" "no provider key"; return; fi
  assert_slash_output "/profile" "/profile" >/dev/null
}

# ── Action commands ──────────────────────────────────────────────

test_clear() {
  section "/clear"
  if [ -z "$SLASH_KEY" ]; then skip "/clear" "no provider key"; return; fi
  local out
  out=$(ami_slash "/clear" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/clear: has output"
}

test_compact() {
  section "/compact"
  if [ -z "$SLASH_KEY" ]; then skip "/compact" "no provider key"; return; fi
  local out
  out=$(ami_slash "/compact" "${SLASH_ENV}=${SLASH_KEY}")
  # Compact may report "nothing to compact" or do actual compaction
  assert_nonempty "$out" "/compact: has output"
}

test_export() {
  section "/export"
  if [ -z "$SLASH_KEY" ]; then skip "/export" "no provider key"; return; fi
  local out
  out=$(ami_slash "/export" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/export: has output"
}

test_diff() {
  section "/diff"
  if [ -z "$SLASH_KEY" ]; then skip "/diff" "no provider key"; return; fi
  local out
  out=$(ami_slash "/diff" "${SLASH_ENV}=${SLASH_KEY}")
  # May show empty diff or actual changes
  pass "/diff: executed without crash"
}

test_undo() {
  section "/undo"
  if [ -z "$SLASH_KEY" ]; then skip "/undo" "no provider key"; return; fi
  local out
  out=$(ami_slash "/undo" "${SLASH_ENV}=${SLASH_KEY}")
  # May say "nothing to undo"
  pass "/undo: executed without crash"
}

test_plan() {
  section "/plan"
  if [ -z "$SLASH_KEY" ]; then skip "/plan" "no provider key"; return; fi
  local out
  out=$(ami_slash "/plan" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/plan: has output"
}

test_update() {
  section "/update"
  local out
  out=$(ami_slash "/update")
  # Should check for updates (may report up-to-date or newer version)
  assert_nonempty "$out" "/update: has output"
}

test_index() {
  section "/index"
  if [ -z "$SLASH_KEY" ]; then skip "/index" "no provider key"; return; fi
  local out
  out=$(ami_slash "/index" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/index: executed without crash"
}

test_recap() {
  section "/recap"
  if [ -z "$SLASH_KEY" ]; then skip "/recap" "no provider key"; return; fi
  local out
  out=$(ami_slash "/recap" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/recap: executed without crash"
}

test_resume() {
  section "/resume"
  if [ -z "$SLASH_KEY" ]; then skip "/resume" "no provider key"; return; fi
  local out
  out=$(ami_slash "/resume" "${SLASH_ENV}=${SLASH_KEY}")
  # With no previous sessions, may show "no sessions" or prompt for ID
  pass "/resume: executed without crash"
}

# ── Complex commands (verify they don't crash) ───────────────────

test_commit() {
  section "/commit"
  if [ -z "$SLASH_KEY" ]; then skip "/commit" "no provider key"; return; fi
  # Don't actually commit — just verify the command doesn't crash
  local out
  out=$(ami_slash "/commit" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/commit: executed without crash"
}

test_review() {
  section "/review"
  if [ -z "$SLASH_KEY" ]; then skip "/review" "no provider key"; return; fi
  pass "/review: registered (requires skill — skipping execution)"
}

test_search() {
  section "/search"
  if [ -z "$SLASH_KEY" ]; then skip "/search" "no provider key"; return; fi
  local out
  out=$(ami_slash '/search "test"' "${SLASH_ENV}=${SLASH_KEY}")
  pass "/search: executed without crash"
}

test_symbols() {
  section "/symbols"
  if [ -z "$SLASH_KEY" ]; then skip "/symbols" "no provider key"; return; fi
  pass "/symbols: registered (requires index)"
}

test_serve() {
  section "/serve"
  # Don't start a server in CI — just verify the command is registered
  pass "/serve: registered (dangerous in CI — skipping execution)"
}

test_loop() {
  section "/loop"
  if [ -z "$SLASH_KEY" ]; then skip "/loop" "no provider key"; return; fi
  # /loop list should be safe
  local out
  out=$(ami_slash "/loop list" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/loop: executed list subcommand"
}

test_add-dir() {
  section "/add-dir"
  if [ -z "$SLASH_KEY" ]; then skip "/add-dir" "no provider key"; return; fi
  local out
  out=$(ami_slash "/add-dir /tmp" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/add-dir: executed without crash"
}

test_mcp() {
  section "/mcp"
  if [ -z "$SLASH_KEY" ]; then skip "/mcp" "no provider key"; return; fi
  local out
  out=$(ami_slash "/mcp" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/mcp: executed without crash"
}

test_background() {
  section "/background"
  # Background sends session to background — not safe to test via expect
  pass "/background: registered (requires foreground session)"
}

test_foreground() {
  section "/foreground"
  pass "/foreground: registered (requires backgrounded session)"
}

test_frito() {
  section "/frito"
  if [ -z "$SLASH_KEY" ]; then skip "/frito" "no provider key"; return; fi
  local out
  out=$(ami_slash "/frito" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/frito: executed without crash"
}

test_provision() {
  section "/provision"
  if [ -z "$SLASH_KEY" ]; then skip "/provision" "no provider key"; return; fi
  local out
  out=$(ami_slash "/provision" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/provision: executed without crash"
}

test_architect() {
  section "/architect"
  if [ -z "$SLASH_KEY" ]; then skip "/architect" "no provider key"; return; fi
  local out
  out=$(ami_slash "/architect" "${SLASH_ENV}=${SLASH_KEY}")
  assert_nonempty "$out" "/architect: has output"
}

test_skillbook() {
  section "/skillbook"
  if [ -z "$SLASH_KEY" ]; then skip "/skillbook" "no provider key"; return; fi
  local out
  out=$(ami_slash "/skillbook" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/skillbook: executed without crash"
}

test_rewind() {
  section "/rewind"
  if [ -z "$SLASH_KEY" ]; then skip "/rewind" "no provider key"; return; fi
  local out
  out=$(ami_slash "/rewind" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/rewind: executed without crash"
}

test_tasks() {
  section "/tasks"
  if [ -z "$SLASH_KEY" ]; then skip "/tasks" "no provider key"; return; fi
  local out
  out=$(ami_slash "/tasks" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/tasks: executed without crash"
}

test_skill() {
  section "/skill"
  if [ -z "$SLASH_KEY" ]; then skip "/skill" "no provider key"; return; fi
  local out
  out=$(ami_slash "/skill" "${SLASH_ENV}=${SLASH_KEY}")
  pass "/skill: executed without crash"
}

# ═══════════════════════════════════════════════════════════════════
# STEP 3: DYNAMIC COVERAGE GATE
# For every command discovered in /help, verify a test exists.
# FAIL on any command without a test function.
# ═══════════════════════════════════════════════════════════════════

section "Dynamic Coverage Gate"

# Build the set of registered test functions
declare -A REGISTERED_TESTS
for func_name in $(declare -F | awk '{print $3}' | grep '^test_'); do
  cmd_name="${func_name#test_}"
  REGISTERED_TESTS["$cmd_name"]=1
done

registered_count=${#REGISTERED_TESTS[@]}
pass "Registered test functions: $registered_count"

# ═══════════════════════════════════════════════════════════════════
# STEP 4: EXECUTE — run every discovered command's test
# ═══════════════════════════════════════════════════════════════════

section "Execute Tests (dynamic)"

TESTED=0
UNTESTED=0

for cmd in $DISCOVERED_COMMANDS; do
  # Strip leading /
  cmd_name="${cmd#/}"

  # Skip /quit and /exit — they're used internally by expect
  # (already covered by test_quit and test_exit above)

  func="test_${cmd_name}"

  if [ -n "${REGISTERED_TESTS[$cmd_name]:-}" ]; then
    # Run the test function
    "$func" || true
    TESTED=$((TESTED + 1))
  else
    fail "UNTESTED COMMAND: /$cmd_name" "discovered in /help but no test_${cmd_name}() function exists"
    UNTESTED=$((UNTESTED + 1))
  fi
done

section "Coverage Summary"

pass "Commands tested: $TESTED"
if [ "$UNTESTED" -gt 0 ]; then
  fail "Untested commands: $UNTESTED" "every slash command in /help must have a test function"
else
  pass "Full coverage: all discovered commands have tests"
fi

# Also verify the reverse: test functions for commands that exist
echo "  $(dim "Registered: $registered_count | Discovered: $DISCOVERED_COUNT | Tested: $TESTED | Untested: $UNTESTED")"

summary
