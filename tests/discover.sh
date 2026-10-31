#!/bin/bash
set -euo pipefail

SCRIPT_DIR_DISCOVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR_DISCOVER/helpers.sh"

INTROSPECT_AVAILABLE=false
INTROSPECT_JSON=""
AMI_VERSION=""

DISC_PROVIDERS=()
DISC_COMMANDS=()
DISC_TOOLS=()
DISC_FLAGS=()
DISC_PERMISSION_MODES=()
DISC_THINKING_LEVELS=()
DISC_SKILLS=()
DISC_OUTPUT_FORMATS=()

AMI_BIN=$(command -v ${AMI%% *} 2>/dev/null || echo "")

if [ -n $AMI ]; then
  # Primary: --introspect returns the full manifest in one call
  _raw=$(timeout 10 $AMI --introspect 2>/dev/null || true)
  if echo "$_raw" | jq -e '.version' >/dev/null 2>&1; then
    INTROSPECT_AVAILABLE=true
    INTROSPECT_JSON="$_raw"
    AMI_VERSION=$(echo "$INTROSPECT_JSON" | jq -r '.version')
    mapfile -t DISC_PROVIDERS < <(echo "$INTROSPECT_JSON" | jq -r '.providers[].id')
    mapfile -t DISC_COMMANDS < <(echo "$INTROSPECT_JSON" | jq -r '.commands[].name')
    mapfile -t DISC_TOOLS < <(echo "$INTROSPECT_JSON" | jq -r '.tools[].name')
    mapfile -t DISC_FLAGS < <(echo "$INTROSPECT_JSON" | jq -r '.flags[].name' | sed 's/^/--/')
    mapfile -t DISC_PERMISSION_MODES < <(echo "$INTROSPECT_JSON" | jq -r '.permissionModes[]')
    mapfile -t DISC_THINKING_LEVELS < <(echo "$INTROSPECT_JSON" | jq -r '.thinkingLevels[]')
    mapfile -t DISC_SKILLS < <(echo "$INTROSPECT_JSON" | jq -r '.skills[]?.name // empty')
    mapfile -t DISC_OUTPUT_FORMATS < <(echo "$INTROSPECT_JSON" | jq -r '.outputFormats[]')
  fi

  # Fallback: --run-command queries individual slash commands (no API key needed)
  if [ "$INTROSPECT_AVAILABLE" = false ]; then
    _prov=$(timeout 10 $AMI --run-command "/providers" 2>/dev/null || true)
    if echo "$_prov" | jq -e '.data.providers' >/dev/null 2>&1; then
      INTROSPECT_AVAILABLE=true
      mapfile -t DISC_PROVIDERS < <(echo "$_prov" | jq -r '.data.providers[].id')
      _help=$(timeout 10 $AMI --run-command "/help" 2>/dev/null || true)
      if echo "$_help" | jq -e '.data.commands' >/dev/null 2>&1; then
        mapfile -t DISC_COMMANDS < <(echo "$_help" | jq -r '.data.commands[].name' | grep -oP '(?<=/)[\w-]+' | sort -u)
      fi
      _think=$(timeout 10 $AMI --run-command "/thinking" 2>/dev/null || true)
      if echo "$_think" | jq -e '.data.validLevels' >/dev/null 2>&1; then
        mapfile -t DISC_THINKING_LEVELS < <(echo "$_think" | jq -r '.data.validLevels[]')
      fi
      _skills=$(timeout 10 $AMI --run-command "/skills" 2>/dev/null || true)
      if echo "$_skills" | jq -e '.data.skills' >/dev/null 2>&1; then
        mapfile -t DISC_SKILLS < <(echo "$_skills" | jq -r '.data.skills[].name')
      fi
      _perms=$(timeout 10 $AMI --run-command "/permissions" 2>/dev/null || true)
      if echo "$_perms" | jq -e '.data.availableModes' >/dev/null 2>&1; then
        mapfile -t DISC_PERMISSION_MODES < <(echo "$_perms" | jq -r '.data.availableModes[]')
      fi
    fi
  fi
fi

if [ "$INTROSPECT_AVAILABLE" = false ]; then
  if [ -n $AMI ]; then
    AMI_VERSION=$($AMI --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
  fi

  DISC_PROVIDERS=(
    google groq openrouter mistral cerebras
    openai anthropic xai deepseek togetherai
    cohere fireworks perplexity deepinfra
    alibaba luma huggingface nvidia
  )

  DISC_COMMANDS=(
    add-dir admission agents analytics architect background clear commit compact
    config context cost diff doctor exit export fast foreground frito goal help
    hooks index keybindings loop mcp memory mode model output-style permissions
    plan profile provider provision providers quit recap resume review
    rewind safe-mode search serve session sessions skill skillbook skills status
    superinference symbols tasks theme thinking undo update usage
  )

  DISC_TOOLS=(
    bash file_read file_edit grep glob list_dir web_fetch web_search
    notebook_edit search_symbols task tool_search AskUserQuestion git_commit
    task_tracker plan_mode task_complete task_output task_kill task_list skill
    cron_create cron_delete cron_list schedule_wakeup enter_worktree
    exit_worktree send_message sleep workflow brief team_create team_delete
    todo_write config structured_output diagnostics find_references
    agentic_fetch scout EndConversation
  )

  DISC_FLAGS=(
    --base-url --api-key --model --provider --permission-mode --prompt --resume
    --config --max-turns --scrollback-lines --thinking --extra-body
    --output-format --input-format --session-id --allow --deny --yolo
    --context-file --image --output-schema --stdin --quiet --max-steps
    --token-budget --fallback-model --plan-mode --run-command --completions
    --help --version --introspect --skill
  )

  DISC_PERMISSION_MODES=(ask auto-allow deny-all)
  DISC_THINKING_LEVELS=(off low medium high max)
  # Static fallback: the wired native skills (bundled in the skills/ library).
  # The introspect path above supersedes this when the binary supports it.
  DISC_SKILLS=(
    pentest sre research swebench
    code-review explain refactor test-gen coding-discipline
    adversarial-verifier code-graph adversarial-review
    feature-completeness-assessment performance-audit planning task-orchestration
    review-changes-workflow understand-codebase-workflow design-exploration-workflow
    research-synthesis-workflow migration-workflow
  )
  DISC_OUTPUT_FORMATS=(json jsonl text)
fi

disc_provider_env() {
  local pid="$1"
  if [ "$INTROSPECT_AVAILABLE" = true ]; then
    echo "$INTROSPECT_JSON" | jq -r --arg pid "$pid" '.providers[] | select(.id == $pid) | .envVars[0]'
  else
    provider_env_var "$pid"
  fi
}

disc_provider_models() {
  local pid="$1"
  if [ "$INTROSPECT_AVAILABLE" = true ]; then
    echo "$INTROSPECT_JSON" | jq -r --arg pid "$pid" '.providers[] | select(.id == $pid) | .models[]'
  else
    echo ""
  fi
}

disc_provider_native() {
  local pid="$1"
  if [ "$INTROSPECT_AVAILABLE" = true ]; then
    echo "$INTROSPECT_JSON" | jq -r --arg pid "$pid" '.providers[] | select(.id == $pid) | .nativeSdk'
  else
    case "$pid" in
      google|anthropic|openai|deepseek|groq|mistral|xai|cohere) echo "true" ;;
      fireworks|togetherai|alibaba|deepinfra|cerebras|huggingface) echo "true" ;;
      *) echo "false" ;;
    esac
  fi
}

# Safety net: a binary whose --introspect manifest predates the skills field
# (or omits it) leaves DISC_SKILLS empty. Fall back to the known wired skills so
# the skills suite can still enforce its coverage gate.
if [ "${#DISC_SKILLS[@]}" -eq 0 ]; then
  DISC_SKILLS=(
    pentest sre research swebench
    code-review explain refactor test-gen coding-discipline
    adversarial-verifier code-graph adversarial-review
    feature-completeness-assessment performance-audit planning task-orchestration
    review-changes-workflow understand-codebase-workflow design-exploration-workflow
    research-synthesis-workflow migration-workflow
  )
fi

echo ""
echo "$(bold '── Discovery ──')"
if [ "$INTROSPECT_AVAILABLE" = true ]; then
  echo "  $(green 'introspect') available — dynamic discovery from binary"
else
  echo "  $(yellow 'introspect') unavailable — using static fallback lists"
fi
echo "  $(dim "version:     $AMI_VERSION")"
echo "  $(dim "providers:   ${#DISC_PROVIDERS[@]}")"
echo "  $(dim "commands:    ${#DISC_COMMANDS[@]}")"
echo "  $(dim "tools:       ${#DISC_TOOLS[@]}")"
echo "  $(dim "flags:       ${#DISC_FLAGS[@]}")"
echo "  $(dim "skills:      ${#DISC_SKILLS[@]}")"
echo "  $(dim "thinking:    ${#DISC_THINKING_LEVELS[@]}")"
echo "  $(dim "permissions: ${#DISC_PERMISSION_MODES[@]}")"
echo "  $(dim "formats:     ${#DISC_OUTPUT_FORMATS[@]}")"
