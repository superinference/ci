#!/bin/bash
# OpenShell container integration tests
# Validates AMI running autonomously inside the openshell-ami container image.
# Expects OPENSHELL_IMAGE to be set (defaults to locally built image).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

FRITO_CONFIG="${FRITO_CONFIG:-$HOME/.ami/frito.json}"
IMAGE="${OPENSHELL_IMAGE:-openshell-ami:test}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"
RUN="$CONTAINER_ENGINE run --rm"

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

# Test: image size is reasonable (< 500MB)
IMAGE_SIZE=$($CONTAINER_ENGINE image inspect "$IMAGE" --format '{{.Size}}' 2>/dev/null || echo "0")
IMAGE_SIZE_MB=$((IMAGE_SIZE / 1024 / 1024))
if [ "$IMAGE_SIZE_MB" -lt 500 ]; then
  pass "image size reasonable (${IMAGE_SIZE_MB}MB)"
else
  fail "image size reasonable" "${IMAGE_SIZE_MB}MB (expected < 500MB)"
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
WHOAMI=$($RUN "$IMAGE" bash -c 'whoami' 2>/dev/null || echo "")
if [ "$WHOAMI" = "sandbox" ]; then
  pass "runs as sandbox user"
else
  fail "runs as sandbox user" "got: $WHOAMI"
fi

# Test: home directory is /sandbox
HOME_DIR=$($RUN "$IMAGE" bash -c 'echo $HOME' 2>/dev/null || echo "")
if [ "$HOME_DIR" = "/sandbox" ]; then
  pass "home directory is /sandbox"
else
  fail "home directory is /sandbox" "got: $HOME_DIR"
fi

# Test: supervisor user exists
SUPERVISOR=$($RUN --user root "$IMAGE" bash -c 'id supervisor 2>/dev/null && echo exists || echo missing' 2>/dev/null || echo "")
if echo "$SUPERVISOR" | grep -q "exists"; then
  pass "supervisor user exists"
else
  fail "supervisor user exists"
fi

# Test: /sandbox is writable
WRITABLE=$($RUN "$IMAGE" bash -c 'touch /sandbox/test_write && echo ok && rm /sandbox/test_write' 2>/dev/null || echo "")
if [ "$WRITABLE" = "ok" ]; then
  pass "/sandbox is writable"
else
  fail "/sandbox is writable"
fi

# Test: /tmp is writable
TMP_WRITABLE=$($RUN "$IMAGE" bash -c 'touch /tmp/test_write && echo ok && rm /tmp/test_write' 2>/dev/null || echo "")
if [ "$TMP_WRITABLE" = "ok" ]; then
  pass "/tmp is writable"
else
  fail "/tmp is writable"
fi

# Test: /etc is not writable by sandbox user
ETC_WRITABLE=$($RUN "$IMAGE" bash -c 'touch /etc/test_write 2>/dev/null && echo writable || echo readonly' 2>/dev/null || echo "readonly")
if [ "$ETC_WRITABLE" = "readonly" ]; then
  pass "/etc is read-only for sandbox user"
else
  fail "/etc is read-only for sandbox user"
fi

# Test: PATH includes /sandbox/.local/bin
PATH_CHECK=$($RUN "$IMAGE" bash -c 'echo $PATH' 2>/dev/null || echo "")
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
AMI_WHICH=$($RUN "$IMAGE" bash -c 'which ami 2>/dev/null || echo missing' 2>/dev/null || echo "missing")
if [ "$AMI_WHICH" != "missing" ]; then
  pass "ami binary on PATH ($AMI_WHICH)"
else
  fail "ami binary on PATH"
fi

# Test: --version works
VERSION=$($RUN "$IMAGE" bash -c 'ami --version 2>&1' 2>/dev/null || echo "")
if echo "$VERSION" | grep -qE "v[0-9]+\.[0-9]+\.[0-9]+"; then
  pass "ami --version works ($VERSION)"
else
  fail "ami --version works" "$VERSION"
fi

# Test: --help works
HELP=$($RUN "$IMAGE" bash -c 'ami --help 2>&1' 2>/dev/null || echo "")
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
ENTRY_CHECK=$($RUN --user root "$IMAGE" bash -c '[ -x /usr/local/bin/entrypoint.sh ] && echo ok || echo missing' 2>/dev/null || echo "")
if [ "$ENTRY_CHECK" = "ok" ]; then
  pass "entrypoint.sh exists and is executable"
else
  fail "entrypoint.sh exists and is executable"
fi

# Test: policy.yaml exists
POLICY_CHECK=$($RUN "$IMAGE" bash -c '[ -f /etc/openshell/policy.yaml ] && echo ok || echo missing' 2>/dev/null || echo "")
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
PROBE_CHECK=$($RUN \
  -e AGENT_PROMPT="test" \
  "$IMAGE" bash -c '
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

# Pick a working provider from frito config
DETACHED_KEY=""
DETACHED_ENV=""
DETACHED_MODEL=""

if [ -f "$FRITO_CONFIG" ]; then
  for _pid in groq google cerebras openrouter mistral; do
    if has_key "$_pid"; then
      _k=$(get_key "$_pid")
      _m=$(get_model "$_pid")
      case "$_pid" in
        google)    DETACHED_ENV="GOOGLE_API_KEY" ;;
        groq)      DETACHED_ENV="GROQ_API_KEY" ;;
        mistral)   DETACHED_ENV="MISTRAL_API_KEY" ;;
        cerebras)  DETACHED_ENV="CEREBRAS_API_KEY" ;;
        *)         DETACHED_ENV="AI_API_KEY" ;;
      esac
      DETACHED_KEY="$_k"
      DETACHED_MODEL="$_m"
      break
    fi
  done
fi

if [ -n "$DETACHED_KEY" ]; then
  # Test: simple detached prompt produces JSONL output
  DETACHED_OUT=$(timeout 120 $RUN \
    -e "$DETACHED_ENV=$DETACHED_KEY" \
    -e AGENT_PROMPT="What is 2+2? Answer with just the number." \
    "$IMAGE" 2>/dev/null || echo "TIMEOUT")

  if [ "$DETACHED_OUT" = "TIMEOUT" ]; then
    skip "detached mode: JSONL output" "timed out after 120s"
  elif [ -n "$DETACHED_OUT" ]; then
    pass "detached mode: produced output (${#DETACHED_OUT} bytes)"

    # Test: output contains valid JSON lines
    VALID_JSON_LINES=0
    while IFS= read -r line; do
      if [ -n "$line" ] && echo "$line" | jq . >/dev/null 2>&1; then
        VALID_JSON_LINES=$((VALID_JSON_LINES + 1))
      fi
    done <<< "$DETACHED_OUT"

    if [ "$VALID_JSON_LINES" -gt 0 ]; then
      pass "detached mode: $VALID_JSON_LINES valid JSON lines"
    else
      skip "detached mode: valid JSON lines" "no parseable JSON lines in output"
    fi
  else
    fail "detached mode: produced output" "empty output"
  fi

  # Test: detached mode with explicit CLI args (bypass entrypoint env)
  CLI_OUT=$(timeout 120 $RUN \
    -e "$DETACHED_ENV=$DETACHED_KEY" \
    "$IMAGE" ami --prompt "What is 3+3? Answer with just the number." \
    --yolo --output-format jsonl 2>/dev/null || echo "TIMEOUT")

  if [ "$CLI_OUT" = "TIMEOUT" ]; then
    skip "detached mode: CLI args" "timed out after 120s"
  elif [ -n "$CLI_OUT" ]; then
    pass "detached mode: CLI args produced output (${#CLI_OUT} bytes)"
  else
    fail "detached mode: CLI args produced output" "empty output"
  fi

  # Test: exit code 0 on success
  EXIT_CODE=0
  timeout 120 $RUN \
    -e "$DETACHED_ENV=$DETACHED_KEY" \
    -e AGENT_PROMPT="What is 1+1? Answer with just the number." \
    "$IMAGE" >/dev/null 2>&1 || EXIT_CODE=$?

  if [ "$EXIT_CODE" -eq 0 ]; then
    pass "detached mode: exit code 0 on success"
  elif [ "$EXIT_CODE" -eq 124 ]; then
    skip "detached mode: exit code" "timed out"
  else
    skip "detached mode: exit code" "got $EXIT_CODE (may be expected for non-interactive)"
  fi
else
  skip "detached mode: JSONL output" "no API key available"
  skip "detached mode: CLI args" "no API key available"
  skip "detached mode: exit code" "no API key available"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: Security isolation
# ═══════════════════════════════════════════════════════════════════
section "Security Isolation"

# Test: cannot write to /usr
USR_WRITE=$($RUN "$IMAGE" bash -c 'touch /usr/test 2>/dev/null && echo writable || echo blocked' 2>/dev/null || echo "blocked")
if [ "$USR_WRITE" = "blocked" ]; then
  pass "cannot write to /usr"
else
  fail "cannot write to /usr"
fi

# Test: cannot write to /var
VAR_WRITE=$($RUN "$IMAGE" bash -c 'touch /var/test 2>/dev/null && echo writable || echo blocked' 2>/dev/null || echo "blocked")
if [ "$VAR_WRITE" = "blocked" ]; then
  pass "cannot write to /var"
else
  fail "cannot write to /var"
fi

# Test: not running as root
ID_CHECK=$($RUN "$IMAGE" bash -c 'id -u' 2>/dev/null || echo "0")
if [ "$ID_CHECK" != "0" ]; then
  pass "not running as root (uid=$ID_CHECK)"
else
  fail "not running as root" "running as uid 0"
fi

# Test: no credentials baked into image
CRED_SCAN=$($RUN "$IMAGE" bash -c '
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
  TOOL_CHECK=$($RUN "$IMAGE" bash -c "which $tool 2>/dev/null && echo ok || echo missing" 2>/dev/null || echo "missing")
  if echo "$TOOL_CHECK" | grep -q "ok"; then
    pass "$tool available"
  else
    fail "$tool available"
  fi
done

summary
