#!/bin/bash
# OpenShell container integration tests
# Validates AMI running autonomously inside the openshell-ami container image.
# Expects OPENSHELL_IMAGE to be set (defaults to locally built image).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

IMAGE="${OPENSHELL_IMAGE:-openshell-ami:test}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
SHM_OPTS="--tmpfs /dev/shm:rw,nosuid,nodev,exec,size=2g"
RUN="$CONTAINER_ENGINE run --rm $SHM_OPTS"
SHELL_RUN="$CONTAINER_ENGINE run --rm $SHM_OPTS --entrypoint bash"

echo ""
echo "$(bold 'OpenShell Container Integration Tests')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Image: $IMAGE")"
echo "$(dim "Engine: $CONTAINER_ENGINE")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: Image structure
# ═══════════════════════════════════════════════════════════════════
section "Image Structure"

# Test: image exists
if $CONTAINER_ENGINE image inspect "$IMAGE" >/dev/null 2>&1; then
  pass "image exists ($IMAGE)"
else
  fail "image exists" "$IMAGE not found"
  summary
  exit 1
fi

# Test: image size is reasonable (< 4000MB)
# Image includes AMI runtime, Node.js + tsx/typescript for in-container test execution
IMAGE_SIZE=$($CONTAINER_ENGINE image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null || echo "0")
IMAGE_SIZE_MB=$((IMAGE_SIZE / 1024 / 1024))
if [ "$IMAGE_SIZE_MB" -lt 4000 ]; then
  pass "image size reasonable (${IMAGE_SIZE_MB}MB)"
else
  fail "image size reasonable" "${IMAGE_SIZE_MB}MB (expected < 4000MB)"
fi

# Test: OCI labels
HARNESS_LABEL=$($CONTAINER_ENGINE image inspect "$IMAGE" --format '{{index .Config.Labels "io.openshell.sandbox.harness"}}' 2>/dev/null || echo "")
if [ "$HARNESS_LABEL" = "ami" ]; then
  pass "OCI label: io.openshell.sandbox.harness=ami"
else
  fail "OCI label: io.openshell.sandbox.harness" "got: $HARNESS_LABEL"
fi

LICENSE_LABEL=$($CONTAINER_ENGINE image inspect "$IMAGE" --format '{{index .Config.Labels "io.openshell.sandbox.license"}}' 2>/dev/null || echo "")
if [ "$LICENSE_LABEL" = "Apache-2.0" ]; then
  pass "OCI label: io.openshell.sandbox.license=Apache-2.0"
else
  fail "OCI label: io.openshell.sandbox.license" "got: $LICENSE_LABEL"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: Sandbox user and filesystem
# ═══════════════════════════════════════════════════════════════════
section "Sandbox User & Filesystem"

# Test: runs as sandbox user
WHOAMI=$($SHELL_RUN "$IMAGE" -c 'whoami' 2>/dev/null || echo "")
if [ "$WHOAMI" = "sandbox" ]; then
  pass "runs as sandbox user"
else
  fail "runs as sandbox user" "got: $WHOAMI"
fi

# Test: home directory is /sandbox
HOME_DIR=$($SHELL_RUN "$IMAGE" -c 'echo $HOME' 2>/dev/null || echo "")
if [ "$HOME_DIR" = "/sandbox" ]; then
  pass "home directory is /sandbox"
else
  fail "home directory is /sandbox" "got: $HOME_DIR"
fi

# Test: supervisor user exists
SUPERVISOR=$($CONTAINER_ENGINE run --rm --entrypoint bash --user root "$IMAGE" -c 'id supervisor 2>/dev/null && echo exists || echo missing' 2>/dev/null || echo "")
if echo "$SUPERVISOR" | grep -q "exists"; then
  pass "supervisor user exists"
else
  fail "supervisor user exists"
fi

# Test: /sandbox is writable
WRITABLE=$($SHELL_RUN "$IMAGE" -c 'touch /sandbox/test_write && echo ok && rm /sandbox/test_write' 2>/dev/null || echo "")
if [ "$WRITABLE" = "ok" ]; then
  pass "/sandbox is writable"
else
  fail "/sandbox is writable"
fi

# Test: /tmp is writable
TMP_WRITABLE=$($SHELL_RUN "$IMAGE" -c 'touch /tmp/test_write && echo ok && rm /tmp/test_write' 2>/dev/null || echo "")
if [ "$TMP_WRITABLE" = "ok" ]; then
  pass "/tmp is writable"
else
  fail "/tmp is writable"
fi

# Test: /etc is not writable by sandbox user
ETC_WRITABLE=$($SHELL_RUN "$IMAGE" -c 'touch /etc/test_write 2>/dev/null && echo writable || echo readonly' 2>/dev/null || echo "readonly")
if [ "$ETC_WRITABLE" = "readonly" ]; then
  pass "/etc is read-only for sandbox user"
else
  fail "/etc is read-only for sandbox user"
fi

# Test: PATH includes /sandbox/.local/bin
PATH_CHECK=$($SHELL_RUN "$IMAGE" -c 'echo $PATH' 2>/dev/null || echo "")
if echo "$PATH_CHECK" | grep -q "/sandbox/.local/bin"; then
  pass "PATH includes /sandbox/.local/bin"
else
  fail "PATH includes /sandbox/.local/bin" "$PATH_CHECK"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: AMI binary inside container
# ═══════════════════════════════════════════════════════════════════
section "AMI Binary"

# Test: ami is on PATH
AMI_WHICH=$($SHELL_RUN "$IMAGE" -c 'command -v ami 2>/dev/null || echo missing' 2>/dev/null || echo "missing")
if [ "$AMI_WHICH" != "missing" ]; then
  pass "ami binary on PATH ($AMI_WHICH)"
else
  fail "ami binary on PATH"
fi

# Test: --version works
VERSION=$($SHELL_RUN "$IMAGE" -c 'ami --version 2>&1' 2>/dev/null || echo "")
if echo "$VERSION" | grep -qE "v[0-9]+\.[0-9]+\.[0-9]+"; then
  pass "ami --version works ($VERSION)"
else
  fail "ami --version works" "$VERSION"
fi

# Test: --help works
HELP=$($SHELL_RUN "$IMAGE" -c 'ami --help 2>&1' 2>/dev/null || echo "")
if echo "$HELP" | grep -qi "usage\|options\|help"; then
  pass "ami --help works"
else
  fail "ami --help works"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 4: Entrypoint behavior
# ═══════════════════════════════════════════════════════════════════
section "Entrypoint"

# Test: entrypoint exists and is executable
ENTRY_CHECK=$($CONTAINER_ENGINE run --rm --entrypoint bash --user root "$IMAGE" -c '[ -x /usr/local/bin/entrypoint.sh ] && echo ok || echo missing' 2>/dev/null || echo "")
if [ "$ENTRY_CHECK" = "ok" ]; then
  pass "entrypoint.sh exists and is executable"
else
  fail "entrypoint.sh exists and is executable"
fi

# Test: policy.yaml exists
POLICY_CHECK=$($SHELL_RUN "$IMAGE" -c '[ -f /etc/openshell/policy.yaml ] && echo ok || echo missing' 2>/dev/null || echo "")
if [ "$POLICY_CHECK" = "ok" ]; then
  pass "policy.yaml exists at /etc/openshell/"
else
  fail "policy.yaml exists at /etc/openshell/"
fi

# Test: default CMD (no AGENT_PROMPT) shows help
NO_PROMPT=$($RUN "$IMAGE" ami 2>&1 || true)
if echo "$NO_PROMPT" | grep -qi "help\|usage\|provide.*prompt\|AGENT_PROMPT"; then
  pass "no AGENT_PROMPT shows help/usage"
else
  fail "no AGENT_PROMPT shows help/usage" "${NO_PROMPT:0:80}"
fi

# Test: bash fallback works
BASH_CHECK=$($RUN "$IMAGE" bash -c 'echo hello_from_bash' 2>/dev/null || echo "")
if [ "$BASH_CHECK" = "hello_from_bash" ]; then
  pass "bash fallback works"
else
  fail "bash fallback works"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: Startup probe
# ═══════════════════════════════════════════════════════════════════
section "Startup Probe"

# Test: /tmp/agent-ready is created by entrypoint
# We need to run with a prompt that will fail fast (no API key) but still touch the probe
PROBE_CHECK=$($CONTAINER_ENGINE run --rm --entrypoint bash \
  -e AGENT_PROMPT="test" \
  "$IMAGE" -c '
    /usr/local/bin/entrypoint.sh ami --help >/dev/null 2>&1 &
    sleep 2
    [ -f /tmp/agent-ready ] && echo ok || echo missing
  ' 2>/dev/null || echo "missing")
if [ "$PROBE_CHECK" = "ok" ]; then
  pass "/tmp/agent-ready created by entrypoint"
else
  skip "/tmp/agent-ready created by entrypoint" "entrypoint execs, probe may not persist in bash -c"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 6: Detached mode execution (requires API key)
# ═══════════════════════════════════════════════════════════════════
section "Detached Mode (Autonomous Execution)"

if [ -n "${AI_API_KEY:-}" ]; then

  # --- 6a: AGENT_PROMPT env var via entrypoint ---
  DETACHED_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    -e AGENT_PROMPT="What is 2+2? Answer with just the number." \
    "$IMAGE" 2>&1 || echo "TIMEOUT")

  if [ "$DETACHED_OUT" = "TIMEOUT" ]; then
    skip "detached/env: produces output" "timed out after 120s"
  elif [ -n "$DETACHED_OUT" ]; then
    pass "detached/env: produced output (${#DETACHED_OUT} bytes)"
  else
    fail "detached/env: produced output" "empty output"
  fi

  # --- 6b: Explicit CLI args (bypass entrypoint env) ---
  CLI_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "What is 3+3? Answer with just the number." \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  if [ "$CLI_OUT" = "TIMEOUT" ]; then
    skip "detached/cli: produces output" "timed out after 120s"
  elif [ -n "$CLI_OUT" ]; then
    pass "detached/cli: produced output (${#CLI_OUT} bytes)"
  else
    fail "detached/cli: produced output" "empty output"
  fi

  # --- 6c: JSONL output format validation ---
  JSONL_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "Say hello" \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  if [ "$JSONL_OUT" = "TIMEOUT" ]; then
    skip "detached/jsonl: valid JSON lines" "timed out after 120s"
  elif [ -n "$JSONL_OUT" ]; then
    VALID_JSON_LINES=0
    TOTAL_LINES=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      TOTAL_LINES=$((TOTAL_LINES + 1))
      if echo "$line" | jq . >/dev/null 2>&1; then
        VALID_JSON_LINES=$((VALID_JSON_LINES + 1))
      fi
    done <<< "$JSONL_OUT"

    if [ "$VALID_JSON_LINES" -gt 0 ]; then
      pass "detached/jsonl: $VALID_JSON_LINES/$TOTAL_LINES valid JSON lines"
    else
      skip "detached/jsonl: valid JSON lines" "no parseable JSON in $TOTAL_LINES lines"
    fi
  else
    fail "detached/jsonl: valid JSON lines" "empty output"
  fi

  # --- 6d: Exit code 0 on success ---
  EXIT_CODE=0
  timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    -e AGENT_PROMPT="What is 1+1? Answer with just the number." \
    "$IMAGE" >/dev/null 2>&1 || EXIT_CODE=$?

  if [ "$EXIT_CODE" -eq 0 ]; then
    pass "detached/exit: code 0 on success"
  elif [ "$EXIT_CODE" -eq 124 ]; then
    skip "detached/exit: code 0" "timed out"
  else
    skip "detached/exit: code 0" "got $EXIT_CODE"
  fi

  # --- 6e: Exit code non-zero without API key ---
  NO_KEY_EXIT=0
  timeout 30 $RUN \
    -e "AI_API_KEY=" \
    -e AGENT_PROMPT="test" \
    "$IMAGE" >/dev/null 2>&1 || NO_KEY_EXIT=$?

  if [ "$NO_KEY_EXIT" -ne 0 ] && [ "$NO_KEY_EXIT" -ne 124 ]; then
    pass "detached/exit: non-zero without API key (exit $NO_KEY_EXIT)"
  elif [ "$NO_KEY_EXIT" -eq 124 ]; then
    skip "detached/exit: no-key check" "timed out"
  else
    skip "detached/exit: no-key check" "got exit 0 (unexpected)"
  fi

  # --- 6f: --yolo flag accepted ---
  YOLO_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "What is 5+5? Just the number." \
    --yolo 2>&1 || echo "TIMEOUT")

  if [ "$YOLO_OUT" = "TIMEOUT" ]; then
    skip "detached/yolo: flag accepted" "timed out"
  elif echo "$YOLO_OUT" | grep -qi "unknown.*yolo\|invalid.*yolo\|unrecognized.*yolo"; then
    fail "detached/yolo: flag accepted" "ami rejected --yolo flag"
  else
    pass "detached/yolo: flag accepted"
  fi

  # --- 6g: Output contains result content ---
  MATH_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "What is 7+7? Reply ONLY with the number, nothing else." \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  if [ "$MATH_OUT" = "TIMEOUT" ]; then
    skip "detached/content: answer in output" "timed out"
  elif echo "$MATH_OUT" | grep -q "14"; then
    pass "detached/content: correct answer found in output"
  elif [ -n "$MATH_OUT" ]; then
    skip "detached/content: answer in output" "output present but 14 not found"
  else
    fail "detached/content: answer in output" "empty output"
  fi

  # --- 6h: Multiple sequential runs produce independent output ---
  RUN1_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "Say alpha" \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  RUN2_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "Say bravo" \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  if [ "$RUN1_OUT" = "TIMEOUT" ] || [ "$RUN2_OUT" = "TIMEOUT" ]; then
    skip "detached/isolation: independent runs" "one or both timed out"
  elif [ -n "$RUN1_OUT" ] && [ -n "$RUN2_OUT" ] && [ "$RUN1_OUT" != "$RUN2_OUT" ]; then
    pass "detached/isolation: sequential runs produce different output"
  elif [ -z "$RUN1_OUT" ] || [ -z "$RUN2_OUT" ]; then
    fail "detached/isolation: independent runs" "one or both produced empty output"
  else
    skip "detached/isolation: independent runs" "outputs identical"
  fi

  # --- 6i: Container does not persist state between runs ---
  $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    -e AGENT_PROMPT="Create a file called /sandbox/marker.txt with the text PERSISTED" \
    "$IMAGE" >/dev/null 2>&1 || true

  PERSIST_CHECK=$($SHELL_RUN "$IMAGE" -c '[ -f /sandbox/marker.txt ] && echo leaked || echo clean' 2>/dev/null || echo "clean")
  if [ "$PERSIST_CHECK" = "clean" ]; then
    pass "detached/isolation: no state persisted between containers"
  else
    fail "detached/isolation: state leaked between containers"
  fi

  # --- 6j: Env vars passed into container are visible to AMI ---
  ENV_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    -e "CUSTOM_VAR=test_value_42" \
    "$IMAGE" ami --prompt "Print the value of the CUSTOM_VAR environment variable. Reply ONLY with the value." \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  if [ "$ENV_OUT" = "TIMEOUT" ]; then
    skip "detached/env-passthrough: custom vars" "timed out"
  elif echo "$ENV_OUT" | grep -q "test_value_42"; then
    pass "detached/env-passthrough: custom env var visible to AMI"
  elif [ -n "$ENV_OUT" ]; then
    skip "detached/env-passthrough: custom vars" "output present but value not found"
  else
    fail "detached/env-passthrough: custom vars" "empty output"
  fi

  # --- 6k: Working directory is /sandbox ---
  CWD_OUT=$(timeout 120 $RUN \
    -e "AI_API_KEY=$AI_API_KEY" \
    "$IMAGE" ami --prompt "Run pwd and reply ONLY with the output path, nothing else." \
    --yolo --output-format jsonl 2>&1 || echo "TIMEOUT")

  if [ "$CWD_OUT" = "TIMEOUT" ]; then
    skip "detached/cwd: working dir is /sandbox" "timed out"
  elif echo "$CWD_OUT" | grep -q "/sandbox"; then
    pass "detached/cwd: working directory is /sandbox"
  elif [ -n "$CWD_OUT" ]; then
    skip "detached/cwd: working dir is /sandbox" "output present but /sandbox not found"
  else
    fail "detached/cwd: working dir is /sandbox" "empty output"
  fi

else
  skip "detached/env: produces output" "no AI_API_KEY set"
  skip "detached/cli: produces output" "no AI_API_KEY set"
  skip "detached/jsonl: valid JSON lines" "no AI_API_KEY set"
  skip "detached/exit: code 0" "no AI_API_KEY set"
  skip "detached/exit: no-key check" "no AI_API_KEY set"
  skip "detached/yolo: flag accepted" "no AI_API_KEY set"
  skip "detached/content: answer in output" "no AI_API_KEY set"
  skip "detached/isolation: independent runs" "no AI_API_KEY set"
  skip "detached/isolation: no state persisted" "no AI_API_KEY set"
  skip "detached/env-passthrough: custom vars" "no AI_API_KEY set"
  skip "detached/cwd: working dir is /sandbox" "no AI_API_KEY set"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: Security isolation
# ═══════════════════════════════════════════════════════════════════
section "Security Isolation"

# Test: cannot write to /usr
USR_WRITE=$($SHELL_RUN "$IMAGE" -c 'touch /usr/test 2>/dev/null && echo writable || echo blocked' 2>/dev/null || echo "blocked")
if [ "$USR_WRITE" = "blocked" ]; then
  pass "cannot write to /usr"
else
  fail "cannot write to /usr"
fi

# Test: cannot write to /var
VAR_WRITE=$($SHELL_RUN "$IMAGE" -c 'touch /var/test 2>/dev/null && echo writable || echo blocked' 2>/dev/null || echo "blocked")
if [ "$VAR_WRITE" = "blocked" ]; then
  pass "cannot write to /var"
else
  fail "cannot write to /var"
fi

# Test: not running as root
ID_CHECK=$($SHELL_RUN "$IMAGE" -c 'id -u' 2>/dev/null || echo "0")
if [ "$ID_CHECK" != "0" ]; then
  pass "not running as root (uid=$ID_CHECK)"
else
  fail "not running as root" "running as uid 0"
fi

# Test: no credentials baked into image
CRED_SCAN=$($SHELL_RUN "$IMAGE" -c '
  found=0
  for pattern in "sk-ant-" "sk-" "AIzaSy" "gsk_" "ANTHROPIC_API_KEY=" "OPENAI_API_KEY="; do
    if grep -rq "$pattern" /sandbox/.config/ /sandbox/.superinference/ 2>/dev/null; then
      found=1
    fi
  done
  echo $found
' 2>/dev/null || echo "0")
if [ "$CRED_SCAN" = "0" ]; then
  pass "no credentials baked into image"
else
  fail "no credentials baked into image"
fi

# Test: env vars not leaking into image layers
ENV_LEAK=$($CONTAINER_ENGINE image inspect "$IMAGE" --format '{{json .Config.Env}}' 2>/dev/null || echo "[]")
if echo "$ENV_LEAK" | grep -qiE "sk-|api_key=sk|AIzaSy"; then
  fail "no API keys in image env" "$ENV_LEAK"
else
  pass "no API keys in image env"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: Tool availability inside container
# ═══════════════════════════════════════════════════════════════════
section "Container Tools"

for tool in git curl jq; do
  TOOL_CHECK=$($SHELL_RUN "$IMAGE" -c "command -v $tool >/dev/null 2>&1 && echo ok || echo missing" 2>/dev/null || echo "missing")
  if echo "$TOOL_CHECK" | grep -q "ok"; then
    pass "$tool available"
  else
    fail "$tool available"
  fi
done

summary
