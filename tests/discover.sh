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
DISC_PERSONAS=()
DISC_OUTPUT_FORMATS=()

AMI_BIN=$(command -v ami 2>/dev/null || echo "")

if [ -n "$AMI_BIN" ]; then
  # Primary: --introspect returns the full manifest in one call
  _raw=$(timeout 10 "$AMI_BIN" --introspect 2>/dev/null || true)
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
    mapfile -t DISC_PERSONAS < <(echo "$INTROSPECT_JSON" | jq -r '.personas[].name')
    mapfile -t DISC_OUTPUT_FORMATS < <(echo "$INTROSPECT_JSON" | jq -r '.outputFormats[]')
  fi

  # Fallback: --run-command queries individual slash commands (no API key needed)
  if [ "$INTROSPECT_AVAILABLE" = false ]; then
    _prov=$(timeout 10 "$AMI_BIN" --run-command "/providers" 2>/dev/null || true)
    if echo "$_prov" | jq -e '.data.providers' >/dev/null 2>&1; then
      INTROSPECT_AVAILABLE=true
      mapfile -t DISC_PROVIDERS < <(echo "$_prov" | jq -r '.data.providers[].id')
      _help=$(timeout 10 "$AMI_BIN" --run-command "/help" 2>/dev/null || true)
      if echo "$_help" | jq -e '.data.commands' >/dev/null 2>&1; then
        mapfile -t DISC_COMMANDS < <(echo "$_help" | jq -r '.data.commands[].name' | grep -oP '(?<=/)[\w-]+' | sort -u)
      fi
      _think=$(timeout 10 "$AMI_BIN" --run-command "/thinking" 2>/dev/null || true)
      if echo "$_think" | jq -e '.data.validLevels' >/dev/null 2>&1; then
        mapfile -t DISC_THINKING_LEVELS < <(echo "$_think" | jq -r '.data.validLevels[]')
      fi
      _persona=$(timeout 10 "$AMI_BIN" --run-command "/persona" 2>/dev/null || true)
      if echo "$_persona" | jq -e '.data.list' >/dev/null 2>&1; then
        mapfile -t DISC_PERSONAS < <(echo "$_persona" | jq -r '.data.list[].name')
      fi
      _perms=$(timeout 10 "$AMI_BIN" --run-command "/permissions" 2>/dev/null || true)
      if echo "$_perms" | jq -e '.data.availableModes' >/dev/null 2>&1; then
        mapfile -t DISC_PERMISSION_MODES < <(echo "$_perms" | jq -r '.data.availableModes[]')
      fi
    fi
  fi
fi

if [ "$INTROSPECT_AVAILABLE" = false ]; then
  if [ -n "$AMI_BIN" ]; then
    AMI_VERSION=$("$AMI_BIN" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
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
    persona plan profile provider provision providers quit recap resume review
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
    --help --version --introspect --persona
  )

  DISC_PERMISSION_MODES=(ask auto-allow deny-all)
  DISC_THINKING_LEVELS=(off low medium high max)
  DISC_PERSONAS=(code pentest sre research)
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
echo "  $(dim "personas:    ${#DISC_PERSONAS[@]}")"
echo "  $(dim "thinking:    ${#DISC_THINKING_LEVELS[@]}")"
echo "  $(dim "permissions: ${#DISC_PERMISSION_MODES[@]}")"
echo "  $(dim "formats:     ${#DISC_OUTPUT_FORMATS[@]}")"
