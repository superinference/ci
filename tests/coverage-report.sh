#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

if [ -f "$SCRIPT_DIR/discover.sh" ]; then
  source "$SCRIPT_DIR/discover.sh"
fi

if [ -z "${DISC_PROVIDERS+x}" ]; then
  DISC_PROVIDERS=("${ALL_PROVIDERS[@]}")
fi

if [ -z "${DISC_COMMANDS+x}" ]; then
  DISC_COMMANDS=(
    add-dir admission agents analytics architect background clear commit
    compact config context cost diff doctor exit export fast foreground
    frito goal help hooks index keybindings loop mcp memory mode model
    output-style permissions persona plan profile provider provision providers quit
    recap resume review rewind safe-mode search serve session sessions
    skill skillbook skills status superinference symbols tasks theme
    thinking undo update usage
  )
fi

if [ -z "${DISC_TOOLS+x}" ]; then
  DISC_TOOLS=(
    bash file_read file_edit grep glob list_dir web_fetch web_search
    notebook_edit search_symbols task tool_search AskUserQuestion git_commit
    task_tracker plan_mode task_complete task_output task_kill task_list skill
    cron_create cron_delete cron_list schedule_wakeup enter_worktree
    exit_worktree send_message sleep workflow brief team_create team_delete
    todo_write config structured_output diagnostics find_references
    agentic_fetch scout EndConversation
  )
fi

if [ -z "${DISC_FLAGS+x}" ]; then
  DISC_FLAGS=(
    --allow --api-key --base-url --completions --config --context-file
    --deny --detached --extra-body --help --image --input-format
    --max-turns --model --no-color --output-format --permission-mode
    --prompt --quiet --resume --run-command --scrollback-lines
    --session-id --stdin --thinking --verbose --version --yolo
  )
fi

echo ""
echo "$(bold 'Feature Coverage Report')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo ""

TOTAL_ITEMS=0
COVERED_ITEMS=0

section "Providers"

PROV_TOTAL=${#DISC_PROVIDERS[@]}
PROV_KEYED=0

for pid in "${DISC_PROVIDERS[@]}"; do
  if has_key "$pid"; then
    printf "  $(green '●')  %s $(dim '(key available)')\n" "$pid"
    PROV_KEYED=$((PROV_KEYED + 1))
  else
    printf "  $(yellow '○')  %s $(dim '(no key)')\n" "$pid"
  fi
done

TOTAL_ITEMS=$((TOTAL_ITEMS + PROV_TOTAL))
COVERED_ITEMS=$((COVERED_ITEMS + PROV_KEYED))

echo ""
printf "  $(bold 'Providers: %d / %d')\n" "$PROV_KEYED" "$PROV_TOTAL"

section "Slash Commands"

CMD_TOTAL=${#DISC_COMMANDS[@]}
CMD_TESTED=0

for cmd in "${DISC_COMMANDS[@]}"; do
  func_name="test_${cmd}"
  if grep -q "^${func_name}()" "$SCRIPT_DIR/slash-commands.sh" 2>/dev/null; then
    printf "  $(green '●')  /%s\n" "$cmd"
    CMD_TESTED=$((CMD_TESTED + 1))
  else
    printf "  $(yellow '○')  /%s $(dim '(no test function)')\n" "$cmd"
  fi
done

TOTAL_ITEMS=$((TOTAL_ITEMS + CMD_TOTAL))
COVERED_ITEMS=$((COVERED_ITEMS + CMD_TESTED))

echo ""
printf "  $(bold 'Commands: %d / %d')\n" "$CMD_TESTED" "$CMD_TOTAL"

section "Personas"

PERSONA_TOTAL=${#DISC_PERSONAS[@]}
PERSONA_TESTED=0

for persona in "${DISC_PERSONAS[@]}"; do
  found=false
  if grep -q "persona $persona" "$SCRIPT_DIR/slash-commands.sh" 2>/dev/null; then
    found=true
  fi
  if $found; then
    printf "  $(green '●')  %s\n" "$persona"
    PERSONA_TESTED=$((PERSONA_TESTED + 1))
  else
    printf "  $(yellow '○')  %s $(dim '(no test)')\n" "$persona"
  fi
done

TOTAL_ITEMS=$((TOTAL_ITEMS + PERSONA_TOTAL))
COVERED_ITEMS=$((COVERED_ITEMS + PERSONA_TESTED))

echo ""
printf "  $(bold 'Personas: %d / %d')\n" "$PERSONA_TESTED" "$PERSONA_TOTAL"

section "Tools"

TOOL_TOTAL=${#DISC_TOOLS[@]}
TOOL_TESTED=0

for tool in "${DISC_TOOLS[@]}"; do
  found=false
  for src in "$SCRIPT_DIR/agent-features.sh"; do
    if [ -f "$src" ] && grep -qE "PROBED_TOOLS\[\"$tool\"\]|probe_tool \"$tool\"" "$src" 2>/dev/null; then
      found=true
      break
    fi
  done
  if $found; then
    printf "  $(green '●')  %s\n" "$tool"
    TOOL_TESTED=$((TOOL_TESTED + 1))
  else
    printf "  $(yellow '○')  %s $(dim '(not in any test script)')\n" "$tool"
  fi
done

TOTAL_ITEMS=$((TOTAL_ITEMS + TOOL_TOTAL))
COVERED_ITEMS=$((COVERED_ITEMS + TOOL_TESTED))

echo ""
printf "  $(bold 'Tools: %d / %d')\n" "$TOOL_TESTED" "$TOOL_TOTAL"

section "CLI Flags"

FLAG_TOTAL=${#DISC_FLAGS[@]}
FLAG_TESTED=0

for flag in "${DISC_FLAGS[@]}"; do
  found=false
  for src in "$SCRIPT_DIR/cli.sh" "$SCRIPT_DIR/agent-features.sh" "$SCRIPT_DIR/providers.sh"; do
    if [ -f "$src" ] && grep -qi -- "$flag" "$src" 2>/dev/null; then
      found=true
      break
    fi
  done
  if $found; then
    printf "  $(green '●')  %s\n" "$flag"
    FLAG_TESTED=$((FLAG_TESTED + 1))
  else
    printf "  $(yellow '○')  %s $(dim '(not tested)')\n" "$flag"
  fi
done

TOTAL_ITEMS=$((TOTAL_ITEMS + FLAG_TOTAL))
COVERED_ITEMS=$((COVERED_ITEMS + FLAG_TESTED))

echo ""
printf "  $(bold 'Flags: %d / %d')\n" "$FLAG_TESTED" "$FLAG_TOTAL"

section "Overall Summary"

if [ "$TOTAL_ITEMS" -gt 0 ]; then
  PCT=$((COVERED_ITEMS * 100 / TOTAL_ITEMS))
else
  PCT=0
fi

echo ""
printf "  $(bold 'Total coverage: %d / %d (%d%%)')\n" "$COVERED_ITEMS" "$TOTAL_ITEMS" "$PCT"
echo ""
printf "  Providers:  %d / %d\n" "$PROV_KEYED" "$PROV_TOTAL"
printf "  Commands:   %d / %d\n" "$CMD_TESTED" "$CMD_TOTAL"
printf "  Personas:   %d / %d\n" "$PERSONA_TESTED" "$PERSONA_TOTAL"
printf "  Tools:      %d / %d\n" "$TOOL_TESTED" "$TOOL_TOTAL"
printf "  Flags:      %d / %d\n" "$FLAG_TESTED" "$FLAG_TOTAL"
echo ""

if [ "$PCT" -lt 80 ]; then
  printf "  $(yellow 'WARNING: coverage is below 80%% (%d%%)')\n" "$PCT"
  echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit 0
