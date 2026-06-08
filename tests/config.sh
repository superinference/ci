#!/bin/bash
# FRITO CI — Config structure, validation, provider entries
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo ""
echo "$(bold 'Config Validation Tests')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo ""

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: Config File Exists & Readable
# ═══════════════════════════════════════════════════════════════════
section "Config File"

if [ -f "$FRITO_CONFIG" ]; then
  pass "config: file exists"
else
  fail "config: file exists" "$FRITO_CONFIG not found"
  summary
  exit 1
fi

[ -r "$FRITO_CONFIG" ] && pass "config: file readable" || fail "config: file readable"

FSIZE=$(stat -c%s "$FRITO_CONFIG" 2>/dev/null || stat -f%z "$FRITO_CONFIG" 2>/dev/null || echo "0")
[ "$FSIZE" -gt 10 ] && pass "config: file non-empty (${FSIZE}B)" || fail "config: file non-empty" "${FSIZE}B"
[ "$FSIZE" -lt 100000 ] && pass "config: file size reasonable (<100KB)" || fail "config: file size" "${FSIZE}B"

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: Valid JSON
# ═══════════════════════════════════════════════════════════════════
section "JSON Validity"

if jq . "$FRITO_CONFIG" >/dev/null 2>&1; then
  pass "json: valid JSON"
else
  fail "json: valid JSON" "parse error"
  summary
  exit 1
fi

ROOT_TYPE=$(jq -r 'type' "$FRITO_CONFIG")
[ "$ROOT_TYPE" = "object" ] && pass "json: root is object" || fail "json: root type" "$ROOT_TYPE"

KEY_COUNT=$(jq 'keys | length' "$FRITO_CONFIG")
[ "$KEY_COUNT" -gt 0 ] && pass "json: has $KEY_COUNT top-level keys" || fail "json: has keys"

# No trailing commas or syntax issues (jq already validated)
pass "json: no syntax errors"

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: Required Top-Level Fields
# ═══════════════════════════════════════════════════════════════════
section "Top-Level Fields"

for field in "enabled" "quality" "referenceProvider" "referenceModel" "providers"; do
  if jq -e "has(\"$field\")" "$FRITO_CONFIG" >/dev/null 2>&1; then
    pass "field: .$field exists"
  else
    fail "field: .$field exists"
  fi
done

# Field types
ENABLED_TYPE=$(jq -r '.enabled | type' "$FRITO_CONFIG" 2>/dev/null || echo "missing")
[ "$ENABLED_TYPE" = "boolean" ] && pass "type: .enabled is boolean" || fail "type: .enabled" "$ENABLED_TYPE"

QUALITY_TYPE=$(jq -r '.quality | type' "$FRITO_CONFIG" 2>/dev/null || echo "missing")
[ "$QUALITY_TYPE" = "string" ] && pass "type: .quality is string" || fail "type: .quality" "$QUALITY_TYPE"

REF_PROV_TYPE=$(jq -r '.referenceProvider | type' "$FRITO_CONFIG" 2>/dev/null || echo "missing")
[ "$REF_PROV_TYPE" = "string" ] && pass "type: .referenceProvider is string" || fail "type: .referenceProvider" "$REF_PROV_TYPE"

REF_MODEL_TYPE=$(jq -r '.referenceModel | type' "$FRITO_CONFIG" 2>/dev/null || echo "missing")
[ "$REF_MODEL_TYPE" = "string" ] && pass "type: .referenceModel is string" || fail "type: .referenceModel" "$REF_MODEL_TYPE"

PROVIDERS_TYPE=$(jq -r '.providers | type' "$FRITO_CONFIG" 2>/dev/null || echo "missing")
[ "$PROVIDERS_TYPE" = "object" ] && pass "type: .providers is object" || fail "type: .providers" "$PROVIDERS_TYPE"

# ═══════════════════════════════════════════════════════════════════
# SECTION 4: Quality Field Values
# ═══════════════════════════════════════════════════════════════════
section "Quality Settings"

QUALITY=$(jq -r '.quality' "$FRITO_CONFIG")
VALID_QUALITIES="speed balanced quality"
if echo "$VALID_QUALITIES" | grep -qw "$QUALITY"; then
  pass "quality: valid value ($QUALITY)"
else
  fail "quality: valid value" "got: $QUALITY, expected: $VALID_QUALITIES"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: Reference Provider & Model
# ═══════════════════════════════════════════════════════════════════
section "Reference Config"

REF_PROVIDER=$(jq -r '.referenceProvider' "$FRITO_CONFIG")
REF_MODEL=$(jq -r '.referenceModel' "$FRITO_CONFIG")

[ -n "$REF_PROVIDER" ] && [ "$REF_PROVIDER" != "null" ] && pass "ref: provider set ($REF_PROVIDER)" || fail "ref: provider set"
[ -n "$REF_MODEL" ] && [ "$REF_MODEL" != "null" ] && pass "ref: model set ($REF_MODEL)" || fail "ref: model set"

KNOWN_REF_PROVIDERS="openai anthropic google groq mistral cerebras openrouter"
echo "$KNOWN_REF_PROVIDERS" | grep -qw "$REF_PROVIDER" && pass "ref: provider is known" || fail "ref: provider is known" "$REF_PROVIDER"

# If openai, model should be a known openai model
if [ "$REF_PROVIDER" = "openai" ]; then
  KNOWN_OPENAI="gpt-4o gpt-4o-mini gpt-4-turbo o1 o1-mini o3-mini o4-mini"
  echo "$KNOWN_OPENAI" | grep -qw "$REF_MODEL" && pass "ref: known openai model ($REF_MODEL)" || skip "ref: known openai model" "$REF_MODEL"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 6: Enabled Flag
# ═══════════════════════════════════════════════════════════════════
section "Enabled Flag"

ENABLED=$(jq -r '.enabled' "$FRITO_CONFIG")
[ "$ENABLED" = "true" ] && pass "enabled: FRITO is enabled" || skip "enabled: FRITO is disabled" "enabled=$ENABLED"

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: Provider Entries
# ═══════════════════════════════════════════════════════════════════
section "Provider Entries"

PROVIDER_COUNT=$(jq '.providers | keys | length' "$FRITO_CONFIG")
[ "$PROVIDER_COUNT" -gt 0 ] && pass "providers: $PROVIDER_COUNT configured" || fail "providers: none configured"

KNOWN_PROVIDERS="google groq openrouter cerebras mistral huggingface deepseek xai together ollama openai anthropic github luma cohere fireworks perplexity deepinfra"

for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
  echo ""
  echo "  $(dim "▸ Provider: $pid")"

  # Known provider ID
  echo "$KNOWN_PROVIDERS" | grep -qw "$pid" && pass "$pid: known provider ID" || fail "$pid: known provider ID"

  # Has required sub-fields
  for sub in "keys" "model" "tier"; do
    if jq -e ".providers.$pid | has(\"$sub\")" "$FRITO_CONFIG" >/dev/null 2>&1; then
      pass "$pid: has .$sub"
    else
      fail "$pid: has .$sub"
    fi
  done

  # Keys is array
  KEYS_TYPE=$(jq -r ".providers.$pid.keys | type" "$FRITO_CONFIG" 2>/dev/null || echo "missing")
  [ "$KEYS_TYPE" = "array" ] && pass "$pid: .keys is array" || fail "$pid: .keys type" "$KEYS_TYPE"

  # Keys non-empty
  KEY_CNT=$(jq ".providers.$pid.keys | length" "$FRITO_CONFIG" 2>/dev/null || echo "0")
  [ "$KEY_CNT" -gt 0 ] && pass "$pid: has $KEY_CNT key(s)" || fail "$pid: has keys"

  # Each key is a non-empty string
  all_keys_valid=true
  for idx in $(seq 0 $((KEY_CNT - 1))); do
    kval=$(jq -r ".providers.$pid.keys[$idx]" "$FRITO_CONFIG" 2>/dev/null || echo "")
    if [ -n "$kval" ] && [ "$kval" != "null" ] && [ ${#kval} -gt 5 ]; then
      pass "$pid: key[$idx] valid (${#kval} chars)"
    else
      fail "$pid: key[$idx] valid" "empty or too short"
      all_keys_valid=false
    fi
  done

  # No duplicate keys
  UNIQUE_KEYS=$(jq -r ".providers.$pid.keys[]" "$FRITO_CONFIG" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  [ "$UNIQUE_KEYS" -eq "$KEY_CNT" ] && pass "$pid: no duplicate keys" || fail "$pid: duplicate keys" "$UNIQUE_KEYS unique / $KEY_CNT total"

  # Model is non-empty string
  MODEL_VAL=$(jq -r ".providers.$pid.model" "$FRITO_CONFIG" 2>/dev/null || echo "")
  [ -n "$MODEL_VAL" ] && [ "$MODEL_VAL" != "null" ] && pass "$pid: model set ($MODEL_VAL)" || fail "$pid: model set"

  # Tier is valid
  TIER_VAL=$(jq -r ".providers.$pid.tier" "$FRITO_CONFIG" 2>/dev/null || echo "")
  VALID_TIERS="permanent temporary trial free"
  if echo "$VALID_TIERS" | grep -qw "$TIER_VAL"; then
    pass "$pid: tier valid ($TIER_VAL)"
  else
    skip "$pid: tier valid" "got: $TIER_VAL"
  fi

  # Key format validation per provider
  case "$pid" in
    google)
      FIRST_KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      if echo "$FIRST_KEY" | grep -qE "^(AIzaSy|AQ\.)"; then
        pass "$pid: key format matches (AIzaSy/AQ.)"
      else
        skip "$pid: key format" "prefix: ${FIRST_KEY:0:6}"
      fi
      ;;
    groq)
      FIRST_KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      echo "$FIRST_KEY" | grep -q "^gsk_" && pass "$pid: key format (gsk_)" || skip "$pid: key format" "${FIRST_KEY:0:6}"
      ;;
    openrouter)
      FIRST_KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      echo "$FIRST_KEY" | grep -q "^sk-or-" && pass "$pid: key format (sk-or-)" || skip "$pid: key format" "${FIRST_KEY:0:8}"
      ;;
    cerebras)
      FIRST_KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      echo "$FIRST_KEY" | grep -q "^csk-" && pass "$pid: key format (csk-)" || skip "$pid: key format" "${FIRST_KEY:0:6}"
      ;;
    *)
      skip "$pid: key format" "no format rule defined"
      ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: File Permissions
# ═══════════════════════════════════════════════════════════════════
section "File Permissions"

PERMS=$(stat -c%a "$FRITO_CONFIG" 2>/dev/null || stat -f%OLp "$FRITO_CONFIG" 2>/dev/null || echo "unknown")
[ "$PERMS" = "600" ] && pass "perms: 600 (owner rw only)" || skip "perms: 600" "got: $PERMS"

OWNER=$(stat -c%U "$FRITO_CONFIG" 2>/dev/null || stat -f%Su "$FRITO_CONFIG" 2>/dev/null || echo "unknown")
[ "$OWNER" = "$(whoami)" ] && pass "perms: owned by current user ($OWNER)" || skip "perms: owner" "$OWNER"

# Not world-readable
if [ "$PERMS" != "unknown" ]; then
  WORLD_READ=$(echo "$PERMS" | tail -c 2)
  [ "$WORLD_READ" -eq 0 ] 2>/dev/null && pass "perms: not world-readable" || skip "perms: not world-readable" "last digit: $WORLD_READ"
fi

# Parent directory exists and is writable
CONFIG_DIR=$(dirname "$FRITO_CONFIG")
[ -d "$CONFIG_DIR" ] && pass "perms: parent dir exists ($CONFIG_DIR)" || fail "perms: parent dir"
[ -w "$CONFIG_DIR" ] && pass "perms: parent dir writable" || fail "perms: parent dir writable"

# ═══════════════════════════════════════════════════════════════════
# SECTION 9: Config Completeness
# ═══════════════════════════════════════════════════════════════════
section "Config Completeness"

# Count total keys across all providers
TOTAL_KEYS=0
for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
  kc=$(jq ".providers.$pid.keys | length" "$FRITO_CONFIG" 2>/dev/null || echo "0")
  TOTAL_KEYS=$((TOTAL_KEYS + kc))
done
[ "$TOTAL_KEYS" -gt 0 ] && pass "completeness: $TOTAL_KEYS total API keys" || fail "completeness: no keys"
[ "$TOTAL_KEYS" -ge 3 ] && pass "completeness: ≥3 keys for redundancy" || skip "completeness: redundancy" "$TOTAL_KEYS keys"

# All providers have models
MODELS_SET=0
for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
  m=$(jq -r ".providers.$pid.model" "$FRITO_CONFIG" 2>/dev/null || echo "")
  [ -n "$m" ] && [ "$m" != "null" ] && MODELS_SET=$((MODELS_SET + 1))
done
[ "$MODELS_SET" -eq "$PROVIDER_COUNT" ] && pass "completeness: all $MODELS_SET providers have models" || fail "completeness: models" "$MODELS_SET/$PROVIDER_COUNT"

# No unexpected top-level fields
EXPECTED_FIELDS="enabled quality referenceProvider referenceModel providers"
for field in $(jq -r 'keys[]' "$FRITO_CONFIG" 2>/dev/null); do
  if echo "$EXPECTED_FIELDS" | grep -qw "$field"; then
    pass "completeness: .$field is expected"
  else
    skip "completeness: .$field is unexpected" "extra field"
  fi
done

# ═══════════════════════════════════════════════════════════════════
# SECTION 10: Config Round-Trip
# ═══════════════════════════════════════════════════════════════════
section "Config Round-Trip"

# Read, re-serialize, compare — no data loss
ORIGINAL=$(cat "$FRITO_CONFIG")
RESERIALIZED=$(echo "$ORIGINAL" | jq '.')
if [ "$RESERIALIZED" = "$(jq '.' "$FRITO_CONFIG")" ]; then
  pass "round-trip: jq parse/serialize stable"
else
  fail "round-trip: jq parse/serialize"
fi

# All provider keys survive round-trip
for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
  ORIG_KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
  RT_KEY=$(echo "$RESERIALIZED" | jq -r ".providers.$pid.keys[0]" 2>/dev/null || echo "")
  [ "$ORIG_KEY" = "$RT_KEY" ] && pass "round-trip/$pid: key preserved" || fail "round-trip/$pid: key"
done

summary
