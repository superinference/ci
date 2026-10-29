#!/bin/bash
# FRITO CI — Security, leakage prevention, binary integrity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo ""
echo "$(bold 'Security & Integrity Tests')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo ""

CI_DIR="${CI_DIR:-$(dirname "$SCRIPT_DIR")}"

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: No Source Code Leakage
# ═══════════════════════════════════════════════════════════════════
section "Source Code Leakage"

for ext in ts tsx js jsx mjs cjs mts cts; do
  FOUND=$(find "$CI_DIR" -name "*.$ext" -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null | head -1 || true)
  [ -z "$FOUND" ] && pass "no-leak: no .$ext files" || fail "no-leak: .$ext file found" "$FOUND"
done

[ ! -f "$CI_DIR/tsconfig.json" ] && pass "no-leak: no tsconfig.json" || fail "no-leak: tsconfig.json found"
[ ! -f "$CI_DIR/package-lock.json" ] && pass "no-leak: no package-lock.json" || skip "no-leak: package-lock.json" "found"
[ ! -d "$CI_DIR/node_modules" ] && pass "no-leak: no node_modules/" || fail "no-leak: node_modules/ found"
[ ! -d "$CI_DIR/dist" ] && pass "no-leak: no dist/" || fail "no-leak: dist/ found"
[ ! -d "$CI_DIR/build" ] && pass "no-leak: no build/" || fail "no-leak: build/ found"

SRC_MAP=$(find "$CI_DIR" -name "*.map" -not -path "*/.git/*" 2>/dev/null | head -1 || true)
[ -z "$SRC_MAP" ] && pass "no-leak: no .map files" || fail "no-leak: .map file found" "$SRC_MAP"

JS_BUNDLE=$(find "$CI_DIR" -name "*.bundle.js" -o -name "*.min.js" 2>/dev/null | head -1 || true)
[ -z "$JS_BUNDLE" ] && pass "no-leak: no JS bundles" || fail "no-leak: JS bundle found" "$JS_BUNDLE"

# ═══════════════════════════════════════════════════════════════════
# SECTION 2: No Credential Files
# ═══════════════════════════════════════════════════════════════════
section "Credential Files"

for pat in ".env" ".env.local" ".env.production" ".env.development" "credentials.json" "service-account.json" "secrets.json" "token.json"; do
  FOUND=$(find "$CI_DIR" -name "$pat" -not -path "*/.git/*" 2>/dev/null | head -1 || true)
  [ -z "$FOUND" ] && pass "no-creds: no $pat" || fail "no-creds: $pat found" "$FOUND"
done

# No frito.json tracked in git (it may exist on disk for local testing, but must be gitignored)
FRITO_TRACKED=$(cd "$CI_DIR" && git ls-files --error-unmatch frito.json 2>/dev/null || true)
[ -z "$FRITO_TRACKED" ] && pass "no-creds: frito.json not tracked by git" || fail "no-creds: frito.json tracked in git" "$FRITO_TRACKED"

SSH_KEYS=$(find "$CI_DIR" -name "id_rsa" -o -name "id_ed25519" -o -name "*.pem" 2>/dev/null | head -1 || true)
[ -z "$SSH_KEYS" ] && pass "no-creds: no SSH keys" || fail "no-creds: SSH key found" "$SSH_KEYS"

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: Git History Clean
# ═══════════════════════════════════════════════════════════════════
section "Git History"

if git -C "$CI_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "git: is a git repo"

  STAGED=$(git -C "$CI_DIR" diff --cached --name-only 2>/dev/null || true)
  if [ -n "$STAGED" ]; then
    SECRET_IN_STAGED=false
    for f in $STAGED; do
      for pat in "frito.json" ".env" "credentials" "secret" "private_key"; do
        echo "$f" | grep -qi "$pat" && SECRET_IN_STAGED=true
      done
    done
    $SECRET_IN_STAGED && fail "git: no secrets in staging" || pass "git: no secrets in staging"
  else
    pass "git: staging area clean"
  fi

  if [ -f "$CI_DIR/.gitignore" ]; then
    pass "git: .gitignore exists"
    for pat in ".env" "node_modules" "frito.json"; do
      grep -q "$pat" "$CI_DIR/.gitignore" 2>/dev/null && pass "git: .gitignore has $pat" || skip "git: .gitignore has $pat"
    done
  else
    skip "git: .gitignore exists" "not yet created"
  fi
else
  skip "git: history checks" "not a git repo"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 4: FRITO Config Security
# ═══════════════════════════════════════════════════════════════════
section "FRITO Config Security"

if has_frito_config; then
  # File permissions (only when reading from a file)
  if [ -z "${FRITO_JSON:-}" ] && [ -f "$FRITO_CONFIG" ]; then
    PERMS=$(stat -c%a "$FRITO_CONFIG" 2>/dev/null || stat -f%OLp "$FRITO_CONFIG" 2>/dev/null || echo "unknown")
    [ "$PERMS" = "600" ] && pass "frito: permissions 600" || skip "frito: permissions" "got: $PERMS"

    echo "$FRITO_CONFIG" | grep -q "$HOME" && pass "frito: in home directory" || skip "frito: location" "$FRITO_CONFIG"

    if [ -L "$FRITO_CONFIG" ]; then
      TARGET=$(readlink -f "$FRITO_CONFIG")
      echo "$TARGET" | grep -q "$HOME" && pass "frito: symlink in home" || fail "frito: symlink target" "$TARGET"
    else
      pass "frito: not a symlink"
    fi
  else
    pass "frito: config via env var (no file on disk)"
  fi

  # Keys are reasonable length (not placeholder)
  for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
    KEY_COUNT=$(frito_jq -r ".providers.$pid.keys | length" 2>/dev/null || echo "0")
    if [ "$KEY_COUNT" -eq 0 ]; then
      skip "frito/$pid: key length" "no keys configured"
    else
      KEY_LEN=$(frito_jq -r ".providers.$pid.keys[0] | length" 2>/dev/null || echo "0")
      [ "$KEY_LEN" -gt 10 ] && pass "frito/$pid: key length ($KEY_LEN)" || fail "frito/$pid: key too short" "$KEY_LEN"
    fi
  done

  # No test/placeholder keys
  for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
    FIRST_KEY=$(frito_jq -r ".providers.$pid.keys[0] // empty" 2>/dev/null || echo "")
    if [ -z "$FIRST_KEY" ] || [ "$FIRST_KEY" = "null" ]; then
      pass "frito/$pid: no placeholder key (no key configured)"
    elif echo "$FIRST_KEY" | grep -qiE "^(test|fake|dummy|placeholder|xxxx|1234|sample)"; then
      fail "frito/$pid: no placeholder key"
    else
      pass "frito/$pid: no placeholder key"
    fi
  done
else
  skip "frito: config security" "no config available"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: Key Not Leaked in CLI Output
# ═══════════════════════════════════════════════════════════════════
section "Key Leakage in CLI"

if has_frito_config; then
  VER_OUT=$(ami --version 2>&1 || true)
  for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
    KEY=$(frito_jq -r ".providers.$pid.keys[0] // empty" 2>/dev/null || echo "")
    [ -n "$KEY" ] && [ "$KEY" != "null" ] && assert_not_contains "$VER_OUT" "$KEY" "leak/$pid: key not in --version"
  done

  HELP_OUT=$(ami --help 2>&1 || true)
  for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
    KEY=$(frito_jq -r ".providers.$pid.keys[0] // empty" 2>/dev/null || echo "")
    [ -n "$KEY" ] && [ "$KEY" != "null" ] && assert_not_contains "$HELP_OUT" "$KEY" "leak/$pid: key not in --help"
  done

  if has_key "groq"; then
    KEY=$(get_key "groq")
    rate_limit_wait
    PROMPT_OUT=$(timeout $AMI_TIMEOUT_LONG env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
      GROQ_API_KEY="$KEY" \
      ami --prompt "Say hello" 2>/dev/null) || true
    if [ -n "$PROMPT_OUT" ]; then
      assert_not_contains "$PROMPT_OUT" "$KEY" "leak/groq: key not in --prompt output"
      BASE_URL=$(echo "$PROMPT_OUT" | jq -r '.baseUrl // empty' 2>/dev/null || true)
      if [ -n "$BASE_URL" ]; then
        assert_not_contains "$BASE_URL" "$KEY" "leak/groq: key not in baseUrl"
      fi
    else
      skip "leak/groq: --prompt test" "timed out or no output"
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 6: Binary Integrity
# ═══════════════════════════════════════════════════════════════════
section "Binary Integrity"

AMI_BIN=$(command -v ami 2>/dev/null || echo "")
if [ -n "$AMI_BIN" ]; then
  FILE_TYPE=$(file "$AMI_BIN" 2>/dev/null || echo "unknown")

  if echo "$FILE_TYPE" | grep -qiE "ELF|Mach-O|executable|PE32"; then
    pass "binary: compiled executable"
  elif echo "$FILE_TYPE" | grep -qi "script"; then
    skip "binary: script wrapper" "$(echo "$FILE_TYPE" | head -c 40)"
  else
    pass "binary: type $(echo "$FILE_TYPE" | head -c 40)"
  fi

  STRINGS_CACHE=$(timeout 60 strings "$AMI_BIN" 2>/dev/null || true)

  if echo "$STRINGS_CACHE" | grep -q "ami-ui/cli/src/" 2>/dev/null; then
    fail "binary: no source paths leaked"
  else
    pass "binary: no source paths leaked"
  fi

  if has_frito_config; then
    for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
      KEY=$(frito_jq -r ".providers.$pid.keys[0] // empty" 2>/dev/null || echo "")
      if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
        pass "binary: no $pid key embedded (no key configured)"
      elif echo "$STRINGS_CACHE" | grep -q "$KEY" 2>/dev/null; then
        fail "binary: no $pid key embedded"
      else
        pass "binary: no $pid key embedded"
      fi
    done
  fi
else
  skip "binary: integrity" "ami not found"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 7: Test Files Security
# ═══════════════════════════════════════════════════════════════════
section "Test File Security"

if has_frito_config; then
  for tf in "$SCRIPT_DIR"/*.sh; do
    [ -f "$tf" ] || continue
    FNAME=$(basename "$tf")

    for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
      KEY=$(frito_jq -r ".providers.$pid.keys[0] // empty" 2>/dev/null || echo "")
      if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
        pass "test-sec/$FNAME: no $pid key (no key configured)"
      elif grep -q "$KEY" "$tf" 2>/dev/null; then
        fail "test-sec/$FNAME: no $pid key hardcoded"
      else
        pass "test-sec/$FNAME: no $pid key"
      fi
    done
  done

  WF_FILE="$CI_DIR/.github/workflows/frito.yml"
  if [ -f "$WF_FILE" ]; then
    for pid in $(frito_jq -r '.providers | keys[]' 2>/dev/null); do
      KEY=$(frito_jq -r ".providers.$pid.keys[0] // empty" 2>/dev/null || echo "")
      if [ -z "$KEY" ] || [ "$KEY" = "null" ]; then
        pass "test-sec/workflow: no $pid key (no key configured)"
      elif grep -q "$KEY" "$WF_FILE" 2>/dev/null; then
        fail "test-sec/workflow: no $pid key"
      else
        pass "test-sec/workflow: no $pid key"
      fi
    done

    grep -q "secrets.AMI_FRITO" "$WF_FILE" && pass "test-sec/workflow: uses secrets.AMI_FRITO" || skip "test-sec/workflow: secrets ref"
    grep -q "FRITO_JSON" "$WF_FILE" && pass "test-sec/workflow: uses FRITO_JSON env var" || skip "test-sec/workflow: FRITO_JSON ref"
  else
    skip "test-sec/workflow" "not found"
  fi
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: Repo Structure
# ═══════════════════════════════════════════════════════════════════
section "Repo Structure"

UNEXPECTED=$(find "$CI_DIR" -type f \
  -not -path "*/.git/*" \
  -not -name "*.sh" \
  -not -name "*.yml" \
  -not -name "*.yaml" \
  -not -name "*.md" \
  -not -name "*.json" \
  -not -name "*.txt" \
  -not -name ".gitignore" \
  -not -name "LICENSE" \
  2>/dev/null | head -5 || true)

if [ -z "$UNEXPECTED" ]; then
  pass "repo: only expected file types"
else
  skip "repo: unexpected files" "$UNEXPECTED"
fi

LARGE=$(find "$CI_DIR" -type f -size +1M -not -path "*/.git/*" 2>/dev/null | head -1 || true)
[ -z "$LARGE" ] && pass "repo: no files >1MB" || fail "repo: large file" "$LARGE"

HIDDEN=$(find "$CI_DIR" -maxdepth 1 -name ".*" -not -name ".git" -not -name ".github" -not -name ".gitignore" 2>/dev/null | head -1 || true)
[ -z "$HIDDEN" ] && pass "repo: no unexpected hidden files" || skip "repo: hidden file" "$HIDDEN"

summary
