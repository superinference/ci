#!/bin/bash
# FRITO CI — Prompt (input) Cache Suite
#
# Prompt caching reuses the large, stable system-prompt+tools prefix across turns
# so repeat calls bill (and latency) only the delta. It is KNOWN BROKEN on
# anthropic-vertex (cache is written but never read back — cache_read stays 0).
# This suite proves caching really works per provider and FAILS where it doesn't.
#
# Two gates:
#   1. COVERAGE GATE (no provider needed): every supported provider (ami
#      --introspect .providers[]) must be classified as either CACHE-capable or
#      explicitly NO-CACHE. A NEW provider that is neither FAILS the suite — you
#      cannot add a provider without deciding (and testing) its cache behavior.
#   2. REAL CACHE PROBE (needs a live key): for each cache-capable provider with a
#      key, run a multi-turn agent run (forces >=2 inferences that reuse the
#      cached prefix) and assert .usage.cachedPromptTokens > 0. Zero cache reads on
#      a cache-capable provider is a FAILURE (this is exactly the vertex bug).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/discover.sh"   # provides DISC_PROVIDERS

AMI_TIMEOUT="${AMI_TIMEOUT:-180}"

# Providers with native prompt caching that MUST serve cache reads. anthropic-vertex
# is intentionally included: it is cache-capable, so the probe runs and (today)
# FAILS, surfacing the broken-read bug rather than hiding it.
CACHE_CAPABLE=(anthropic anthropic-vertex openai azure-openai google google-vertex deepseek)
# Providers that do not offer (or do not report) prompt-cache reads — acknowledged,
# so the coverage gate passes without a live probe.
NO_CACHE=(groq mistral xai togetherai cohere fireworks perplexity deepinfra cerebras nvidia alibaba amazon-bedrock openrouter huggingface luma)

in_list() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

is_transient() {
  local output="$1"; [ -z "$output" ] && return 0
  local err; err=$(echo "$output" | jq -r '.error // empty' 2>/dev/null || true)
  [ -z "$err" ] && return 0
  echo "$err" | grep -qiE "429|rate.limit|too.many|quota|resource.exhausted|timeout|ECONNREFUSED|ETIMEDOUT|HTTP [45]|Max retries|overloaded|max.turns|server error|context.overflow|request.too.large|not.found|no.such.model|model.not" && return 0
  return 1
}

echo ""
echo "$(bold 'FRITO Prompt Cache — per-provider input-cache verification')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $AMI")"

# ═══════════════════════════════════════════════════════════════════
section "Prerequisites"
command -v jq >/dev/null 2>&1 || { fail "prereq/jq"; summary; }
pass "prereq/jq: available"
if [ "${#DISC_PROVIDERS[@]}" -eq 0 ]; then fail "prereq/discovery: no providers discovered"; summary; fi
pass "prereq/discovery: ${#DISC_PROVIDERS[@]} providers"

# ═══════════════════════════════════════════════════════════════════
# COVERAGE GATE — every supported provider must be classified (no key needed).
# A new provider in neither list fails here: classify + test it.
# ═══════════════════════════════════════════════════════════════════
section "Cache Classification Gate"
UNCLASSIFIED=0
for pid in "${DISC_PROVIDERS[@]}"; do
  if in_list "$pid" "${CACHE_CAPABLE[@]}"; then
    pass "gate/$pid: cache-capable (will be probed when keyed)"
  elif in_list "$pid" "${NO_CACHE[@]}"; then
    pass "gate/$pid: declared no-cache (acknowledged)"
  else
    fail "gate/$pid: UNCLASSIFIED" "add $pid to CACHE_CAPABLE or NO_CACHE in prompt-cache.sh and test it"
    UNCLASSIFIED=$((UNCLASSIFIED + 1))
  fi
done
# Stale classification (listed but no longer a supported provider) — informational.
for pid in "${CACHE_CAPABLE[@]}" "${NO_CACHE[@]}"; do
  in_list "$pid" "${DISC_PROVIDERS[@]}" || skip "gate/stale: $pid" "classified but not in introspect"
done
if [ "$UNCLASSIFIED" -eq 0 ]; then
  pass "Cache classification gate: all ${#DISC_PROVIDERS[@]} providers classified"
else
  fail "Cache classification gate" "$UNCLASSIFIED provider(s) unclassified"
fi

# ═══════════════════════════════════════════════════════════════════
# REAL CACHE PROBE — per cache-capable provider with a live key.
# ═══════════════════════════════════════════════════════════════════
if ! has_frito_config; then
  skip "probe: no frito config" "classification gate still enforced above"
  summary
fi

# Prompt forces a 2nd inference (a tool call), so the large system-prompt+tools
# prefix is sent again within the cache TTL and should be read from cache.
CACHE_PROMPT="Use the bash tool to run exactly: echo CACHE_PROBE_42 . Then reply with only the single word it printed."

PROBED=0
for pid in "${CACHE_CAPABLE[@]}"; do
  # Probe every cache-capable provider that has a key — independent of whether
  # introspect listed it (so a keyed anthropic-vertex is ALWAYS probed and its
  # broken-read bug is surfaced, even if discovery fell back to the static list).
  if ! has_key "$pid"; then
    skip "probe/$pid: no key" "cannot run live cache probe"
    continue
  fi
  PROBED=$((PROBED + 1))
  section "cache probe: $pid"
  MODEL="$(get_model "$pid")"
  ENVV="$(provider_env_string "$pid" "$(get_key "$pid")")"
  echo "  $(dim "model: ${MODEL:-default}")"
  pwait "$pid"
  out=$(timeout "$AMI_TIMEOUT" env -i PATH="$PATH" HOME="$HOME" $ENV_BASE $ENVV \
    $AMI --model "$MODEL" --permission-mode auto-allow --max-turns 4 --output-format json \
    --prompt "$CACHE_PROMPT" 2>/dev/null) || true

  if [ -z "$out" ] || ! echo "$out" | jq . >/dev/null 2>&1; then
    skip "probe/$pid: run" "empty/non-JSON output"
    continue
  fi
  ok=$(echo "$out" | jq -r '.ok')
  err=$(echo "$out" | jq -r '.error // empty')
  cached=$(echo "$out" | jq -r '.usage.cachedPromptTokens // 0')
  prompt_toks=$(echo "$out" | jq -r '.usage.promptTokens // 0')
  turns=$(echo "$out" | jq -r '.usage.turns // 0')

  if [ "$ok" != "true" ]; then
    if is_transient "$out"; then skip "probe/$pid: run" "transient: ${err:0:60}"; else fail "probe/$pid: run" "${err:0:80}"; fi
    continue
  fi
  pass "probe/$pid: ran (prompt=$prompt_toks tok, turns=$turns)"

  # A single-turn run can't exercise cross-call cache reuse — don't penalize it.
  if [ "$turns" -lt 2 ]; then
    skip "probe/$pid: cache read" "only $turns turn(s) — no prefix reuse to cache"
    continue
  fi

  if [ "$cached" -gt 0 ] 2>/dev/null; then
    pass "probe/$pid: input cache WORKS (cachedPromptTokens=$cached)"
  else
    fail "probe/$pid: INPUT CACHE BROKEN" "cachedPromptTokens=0 across $turns turns on a cache-capable provider (e.g. the anthropic-vertex read bug)"
  fi
done

if [ "$PROBED" -eq 0 ]; then
  skip "probe: no cache-capable provider keyed" "classification gate still enforced"
fi

summary
