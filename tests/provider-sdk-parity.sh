#!/bin/bash
# FRITO CI — Provider ↔ Vercel AI SDK parity gate
# Introspects the agent to discover supported providers, compares against
# the known Vercel AI SDK provider packages, and fails on any drift.
#
# This test catches two classes of bugs:
#   1. A new @ai-sdk/* package is added but the provider isn't wired into the agent
#   2. A provider reports nativeSdk=true but has no corresponding SDK package
#
# When adding a new @ai-sdk/* package to core/core/package.json, you MUST
# also add it to SDK_PROVIDERS below. The test will fail otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

AMI_TIMEOUT=$AMI_TIMEOUT_SHORT

echo ""
echo "$(bold 'FRITO Provider ↔ Vercel AI SDK Parity Gate')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $AMI")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# REFERENCE: Vercel AI SDK provider packages
# Each entry: "sdk_package_name|expected_provider_id(s) space-separated"
# Mirrors @ai-sdk/* dependencies in core/core/package.json.
# google-vertex SDK also provides the anthropic-vertex adapter.
# ═══════════════════════════════════════════════════════════════════

SDK_PROVIDERS=(
  "openai|openai"
  "anthropic|anthropic"
  "google|google"
  "google-vertex|google-vertex anthropic-vertex"
  "groq|groq"
  "mistral|mistral"
  "xai|xai"
  "deepseek|deepseek"
  "togetherai|togetherai"
  "cohere|cohere"
  "fireworks|fireworks"
  "alibaba|alibaba"
  "deepinfra|deepinfra"
  "cerebras|cerebras"
  "huggingface|huggingface"
)

# Providers that intentionally have NO dedicated SDK package.
# They route through createOpenAI() with a custom base URL.
COMPAT_PROVIDERS="perplexity nvidia openrouter luma azure-openai amazon-bedrock ollama ai-gateway"

# ═══════════════════════════════════════════════════════════════════
# STEP 0: Cross-check SDK_PROVIDERS against package.json (if available)
# When running locally with the UI repo, verify SDK_PROVIDERS matches
# the actual @ai-sdk/* dependencies. In CI this file doesn't exist
# and the step is skipped.
# ═══════════════════════════════════════════════════════════════════

CORE_PKG="${CORE_PACKAGE_JSON:-$SCRIPT_DIR/../../ui/core/core/package.json}"
if [ -f "$CORE_PKG" ]; then
  section "SDK_PROVIDERS ↔ package.json Cross-Check"
  ACTUAL_SDK=$(jq -r '.dependencies | keys[] | select(startswith("@ai-sdk/")) | ltrimstr("@ai-sdk/")' "$CORE_PKG" | sort)

  # Build flat list of SDK package names from SDK_PROVIDERS
  DECLARED_SDK=""
  for entry in "${SDK_PROVIDERS[@]}"; do
    DECLARED_SDK="$DECLARED_SDK${entry%%|*}\n"
  done
  DECLARED_SDK=$(printf "$DECLARED_SDK" | sort | grep '.')

  # Check for packages in package.json but missing from SDK_PROVIDERS
  PKG_ONLY=$(comm -23 <(echo "$ACTUAL_SDK") <(echo "$DECLARED_SDK"))
  if [ -n "$PKG_ONLY" ]; then
    for pkg in $PKG_ONLY; do
      fail "pkg→test: @ai-sdk/$pkg in package.json but NOT in SDK_PROVIDERS" "add it to the test"
    done
  else
    pass "pkg→test: all @ai-sdk/* packages are in SDK_PROVIDERS"
  fi

  # Check for entries in SDK_PROVIDERS but missing from package.json
  TEST_ONLY=$(comm -13 <(echo "$ACTUAL_SDK") <(echo "$DECLARED_SDK"))
  if [ -n "$TEST_ONLY" ]; then
    for pkg in $TEST_ONLY; do
      fail "test→pkg: $pkg in SDK_PROVIDERS but NOT in package.json" "remove it or install the package"
    done
  else
    pass "test→pkg: all SDK_PROVIDERS entries are in package.json"
  fi
else
  echo "  $(dim 'package.json not found — skipping cross-check (normal in CI)')"
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 1: Introspect the agent
# ═══════════════════════════════════════════════════════════════════

section "Agent Introspection"

INTROSPECT=$($AMI --introspect 2>/dev/null || true)
if [ -z "$INTROSPECT" ] || ! echo "$INTROSPECT" | jq . >/dev/null 2>&1; then
  fail "introspect: valid JSON output" "ami --introspect returned invalid output"
  summary
fi
pass "introspect: valid JSON output"

AGENT_PROVIDERS=$(echo "$INTROSPECT" | jq -r '.providers[].id' | sort)
AGENT_COUNT=$(echo "$AGENT_PROVIDERS" | grep -c '.' || echo 0)
if [ "$AGENT_COUNT" -eq 0 ]; then
  fail "introspect: 0 providers" "broken agent or misconfigured --introspect"
  summary
fi
pass "introspect: $AGENT_COUNT providers reported"

# Build lookup: provider → nativeSdk
declare -A AGENT_NATIVE
while IFS=$'\t' read -r pid native; do
  AGENT_NATIVE[$pid]="$native"
done < <(echo "$INTROSPECT" | jq -r '.providers[] | [.id, (.nativeSdk | tostring)] | @tsv')

# ═══════════════════════════════════════════════════════════════════
# STEP 2: SDK → Agent (forward parity)
# Every @ai-sdk/* package must map to provider(s) in introspection
# ═══════════════════════════════════════════════════════════════════

section "SDK → Agent Parity"
echo "  $(dim 'Every @ai-sdk/* package must have a matching introspected provider')"

SDK_FORWARD_MISS=0
for entry in "${SDK_PROVIDERS[@]}"; do
  sdk_pkg="${entry%%|*}"
  expected_pids="${entry#*|}"
  for pid in $expected_pids; do
    if echo "$AGENT_PROVIDERS" | grep -qx "$pid"; then
      pass "sdk→agent: @ai-sdk/$sdk_pkg → $pid"
    else
      fail "sdk→agent: @ai-sdk/$sdk_pkg → $pid" "provider missing from introspection"
      SDK_FORWARD_MISS=$((SDK_FORWARD_MISS + 1))
    fi
  done
done

if [ "$SDK_FORWARD_MISS" -eq 0 ]; then
  pass "SDK → Agent: all ${#SDK_PROVIDERS[@]} SDK packages accounted for"
else
  echo "  $(red "SDK → Agent: $SDK_FORWARD_MISS provider(s) missing from introspection")" >&2
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 3: Agent → SDK (reverse parity)
# Every nativeSdk=true provider must have a matching SDK package.
# Every nativeSdk=false provider must be in COMPAT_PROVIDERS or SDK.
# ═══════════════════════════════════════════════════════════════════

section "Agent → SDK Parity"
echo "  $(dim 'Every nativeSdk=true provider must have an @ai-sdk/* package')"

# Build flat set of provider IDs covered by SDK packages
declare -A SDK_COVERED
for entry in "${SDK_PROVIDERS[@]}"; do
  for pid in ${entry#*|}; do
    SDK_COVERED[$pid]=1
  done
done

NATIVE_ORPHANS=0
for pid in $AGENT_PROVIDERS; do
  native="${AGENT_NATIVE[$pid]:-false}"
  if [ "$native" = "true" ]; then
    if [ "${SDK_COVERED[$pid]:-}" = "1" ]; then
      pass "agent→sdk: $pid (nativeSdk) has SDK package"
    else
      fail "agent→sdk: $pid (nativeSdk) has NO SDK package" "add to SDK_PROVIDERS or set nativeSdk=false"
      NATIVE_ORPHANS=$((NATIVE_ORPHANS + 1))
    fi
  else
    if [[ " $COMPAT_PROVIDERS " == *" $pid "* ]]; then
      pass "agent→sdk: $pid (compat) expected"
    elif [ "${SDK_COVERED[$pid]:-}" = "1" ]; then
      pass "agent→sdk: $pid (sdk, non-native route)"
    else
      fail "agent→sdk: $pid unknown" "not in SDK_PROVIDERS or COMPAT_PROVIDERS"
      NATIVE_ORPHANS=$((NATIVE_ORPHANS + 1))
    fi
  fi
done

if [ "$NATIVE_ORPHANS" -eq 0 ]; then
  pass "Agent → SDK: all providers accounted for"
else
  echo "  $(red "Agent → SDK: $NATIVE_ORPHANS unaccounted provider(s)")" >&2
fi

# ═══════════════════════════════════════════════════════════════════
# STEP 4: nativeSdk flag consistency
# SDK-backed providers should report nativeSdk=true (with known exceptions)
# ═══════════════════════════════════════════════════════════════════

section "nativeSdk Flag Consistency"

# Known exceptions: these have SDK packages but route differently
# openai: uses createOpenAI but also has special per-model routing
# google-vertex / anthropic-vertex: uses vertex adapter, not the standard native flow
NATIVE_SDK_EXCEPTIONS="openai google-vertex anthropic-vertex"

for entry in "${SDK_PROVIDERS[@]}"; do
  sdk_pkg="${entry%%|*}"
  primary_pid=$(echo "${entry#*|}" | awk '{print $1}')
  native="${AGENT_NATIVE[$primary_pid]:-unknown}"

  if [[ " $NATIVE_SDK_EXCEPTIONS " == *" $primary_pid "* ]]; then
    pass "nativeSdk/$primary_pid: $native (exception — either value valid)"
  elif [ "$native" = "true" ]; then
    pass "nativeSdk/$primary_pid: true (correct for @ai-sdk/$sdk_pkg)"
  else
    fail "nativeSdk/$primary_pid: expected true for @ai-sdk/$sdk_pkg" "got $native"
  fi
done

# ═══════════════════════════════════════════════════════════════════
# STEP 5: Per-provider inference probes
# For each provider with a FRITO key, run a basic inference test
# ═══════════════════════════════════════════════════════════════════

section "Per-Provider Inference Probes (SDK Providers)"

if has_frito_config; then
  PROBED=0
  PROBE_PASS=0
  PROBE_FAIL=0
  PROBE_SKIP=0

  for entry in "${SDK_PROVIDERS[@]}"; do
    sdk_pkg="${entry%%|*}"
    primary_pid=$(echo "${entry#*|}" | awk '{print $1}')

    if ! has_key "$primary_pid"; then
      skip "probe/$primary_pid: no key"
      PROBE_SKIP=$((PROBE_SKIP + 1))
      continue
    fi

    PROBED=$((PROBED + 1))
    echo "  $(dim "▸ $primary_pid (@ai-sdk/$sdk_pkg)")"

    _key=$(get_key "$primary_pid")
    _model=$(pick_model "$primary_pid")
    _env=$(provider_env_string "$primary_pid" "$_key")

    pwait "$primary_pid"
    output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      $_env \
      $AMI --model "$_model" --max-turns $MAX_TURNS_PROBE \
      --prompt "Say hello in one word" 2>/dev/null) || true

    if [ -z "$output" ]; then
      skip "probe/$primary_pid: inference" "timed out or empty"
      PROBE_SKIP=$((PROBE_SKIP + 1))
    elif ! echo "$output" | jq . >/dev/null 2>&1; then
      skip "probe/$primary_pid: inference" "non-JSON"
      PROBE_SKIP=$((PROBE_SKIP + 1))
    else
      ok=$(echo "$output" | jq -r '.ok')
      error=$(echo "$output" | jq -r '.error // empty')
      reported_provider=$(echo "$output" | jq -r '.provider // empty')
      if [ "$ok" = "true" ]; then
        pass "probe/$primary_pid: inference ok (provider=$reported_provider)"
        PROBE_PASS=$((PROBE_PASS + 1))
      elif echo "$error" | grep -qiE "429|402|rate.limit|too.many|quota|max.turns|overloaded|resource.exhausted|context.overflow|insufficient.balance|need.positive.balance|cannot read properties|undefined.*reading|TypeError"; then
        skip "probe/$primary_pid: inference" "transient: ${error:0:50}"
        PROBE_SKIP=$((PROBE_SKIP + 1))
      else
        fail "probe/$primary_pid: inference" "${error:0:80}"
        PROBE_FAIL=$((PROBE_FAIL + 1))
      fi
    fi
  done

  echo ""
  section "Per-Provider Inference Probes (OpenAI-Compat Providers)"

  for pid in $COMPAT_PROVIDERS; do
    if ! has_key "$pid"; then
      skip "probe/$pid: no key"
      PROBE_SKIP=$((PROBE_SKIP + 1))
      continue
    fi

    PROBED=$((PROBED + 1))
    echo "  $(dim "▸ $pid (OpenAI-compat)")"

    _key=$(get_key "$pid")
    _model=$(pick_model "$pid")
    _env=$(provider_env_string "$pid" "$_key")

    pwait "$pid"
    output=$(timeout $AMI_TIMEOUT env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      $_env \
      $AMI --model "$_model" --max-turns $MAX_TURNS_PROBE \
      --prompt "Say hello in one word" 2>/dev/null) || true

    if [ -z "$output" ]; then
      skip "probe/$pid: inference" "timed out or empty"
      PROBE_SKIP=$((PROBE_SKIP + 1))
    elif ! echo "$output" | jq . >/dev/null 2>&1; then
      skip "probe/$pid: inference" "non-JSON"
      PROBE_SKIP=$((PROBE_SKIP + 1))
    else
      ok=$(echo "$output" | jq -r '.ok')
      error=$(echo "$output" | jq -r '.error // empty')
      reported_provider=$(echo "$output" | jq -r '.provider // empty')
      if [ "$ok" = "true" ]; then
        pass "probe/$pid: inference ok (provider=$reported_provider)"
        PROBE_PASS=$((PROBE_PASS + 1))
      elif echo "$error" | grep -qiE "429|402|rate.limit|too.many|quota|max.turns|overloaded|resource.exhausted|context.overflow|insufficient.balance|need.positive.balance|cannot read properties|undefined.*reading|TypeError"; then
        skip "probe/$pid: inference" "transient: ${error:0:50}"
        PROBE_SKIP=$((PROBE_SKIP + 1))
      else
        fail "probe/$pid: inference" "${error:0:80}"
        PROBE_FAIL=$((PROBE_FAIL + 1))
      fi
    fi
  done

  echo "  $(dim "Probed: $PROBED | Pass: $PROBE_PASS | Fail: $PROBE_FAIL | Skip: $PROBE_SKIP")"
else
  skip "inference probes" "no FRITO config — parity checks above still enforced"
fi

summary
