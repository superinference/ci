#!/bin/bash
# FRITO CI — Security, leakage prevention, binary integrity
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo ""
echo "$(bold 'Security & Integrity Tests')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo ""

CI_DIR=$(dirname "$SCRIPT_DIR")

# ═══════════════════════════════════════════════════════════════════
# SECTION 1: No Source Code Leakage
# ═══════════════════════════════════════════════════════════════════
section "Source Code Leakage"

for ext in ts tsx js jsx mjs cjs mts cts; do
  FOUND=$(find "$CI_DIR" -name "*.$ext" -not -path "*/.git/*" -not -path "*/node_modules/*" 2>/dev/null | head -1 || true)
  [ -z "$FOUND" ] && pass "no-leak: no .$ext files" || fail "no-leak: .$ext file found" "$FOUND"
done

# No TypeScript config
[ ! -f "$CI_DIR/tsconfig.json" ] && pass "no-leak: no tsconfig.json" || fail "no-leak: tsconfig.json found"

# No package-lock
[ ! -f "$CI_DIR/package-lock.json" ] && pass "no-leak: no package-lock.json" || skip "no-leak: package-lock.json" "found"

# No node_modules
[ ! -d "$CI_DIR/node_modules" ] && pass "no-leak: no node_modules/" || fail "no-leak: node_modules/ found"

# No dist/build directories from ami-ui
[ ! -d "$CI_DIR/dist" ] && pass "no-leak: no dist/" || fail "no-leak: dist/ found"
[ ! -d "$CI_DIR/build" ] && pass "no-leak: no build/" || fail "no-leak: build/ found"

# No source maps
SRC_MAP=$(find "$CI_DIR" -name "*.map" -not -path "*/.git/*" 2>/dev/null | head -1 || true)
[ -z "$SRC_MAP" ] && pass "no-leak: no .map files" || fail "no-leak: .map file found" "$SRC_MAP"

# No compiled JS bundles
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

# No frito.json in repo (should only exist in ~/.ami)
FRITO_IN_REPO=$(find "$CI_DIR" -name "frito.json" -not -path "*/.git/*" 2>/dev/null | head -1 || true)
[ -z "$FRITO_IN_REPO" ] && pass "no-creds: no frito.json in repo" || fail "no-creds: frito.json in repo" "$FRITO_IN_REPO"

# No SSH keys
SSH_KEYS=$(find "$CI_DIR" -name "id_rsa" -o -name "id_ed25519" -o -name "*.pem" 2>/dev/null | head -1 || true)
[ -z "$SSH_KEYS" ] && pass "no-creds: no SSH keys" || fail "no-creds: SSH key found" "$SSH_KEYS"

# ═══════════════════════════════════════════════════════════════════
# SECTION 3: Git History Clean
# ═══════════════════════════════════════════════════════════════════
section "Git History"

if git -C "$CI_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "git: is a git repo"

  # No secrets in staged files
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

  # Check .gitignore exists and has key patterns
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

if [ -f "$FRITO_CONFIG" ]; then
  # Permissions
  PERMS=$(stat -c%a "$FRITO_CONFIG" 2>/dev/null || stat -f%OLp "$FRITO_CONFIG" 2>/dev/null || echo "unknown")
  [ "$PERMS" = "600" ] && pass "frito: permissions 600" || skip "frito: permissions" "got: $PERMS"

  # Config is in home directory
  echo "$FRITO_CONFIG" | grep -q "$HOME" && pass "frito: in home directory" || skip "frito: location" "$FRITO_CONFIG"

  # Config not symlinked to something weird
  if [ -L "$FRITO_CONFIG" ]; then
    TARGET=$(readlink -f "$FRITO_CONFIG")
    echo "$TARGET" | grep -q "$HOME" && pass "frito: symlink in home" || fail "frito: symlink target" "$TARGET"
  else
    pass "frito: not a symlink"
  fi

  # Keys are reasonable length (not placeholder)
  for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
    KEY_LEN=$(jq -r ".providers.$pid.keys[0] | length" "$FRITO_CONFIG" 2>/dev/null || echo "0")
    [ "$KEY_LEN" -gt 10 ] && pass "frito/$pid: key length ($KEY_LEN)" || fail "frito/$pid: key too short" "$KEY_LEN"
  done

  # No test/placeholder keys
  for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
    FIRST_KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
    if echo "$FIRST_KEY" | grep -qiE "^(test|fake|dummy|placeholder|xxxx|1234|sample)"; then
      fail "frito/$pid: no placeholder key"
    else
      pass "frito/$pid: no placeholder key"
    fi
  done
else
  skip "frito: config security" "file not found"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 5: Key Not Leaked in CLI Output
# ═══════════════════════════════════════════════════════════════════
section "Key Leakage in CLI"

if [ -f "$FRITO_CONFIG" ]; then
  # --version should not contain any API key
  VER_OUT=$(ami --version 2>&1 || true)
  for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
    KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
    [ -n "$KEY" ] && assert_not_contains "$VER_OUT" "$KEY" "leak/$pid: key not in --version"
  done

  # --help should not contain any API key
  HELP_OUT=$(ami --help 2>&1 || true)
  for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
    KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
    [ -n "$KEY" ] && assert_not_contains "$HELP_OUT" "$KEY" "leak/$pid: key not in --help"
  done

  # --prompt output should not contain the API key (test with one provider)
  if has_key "groq"; then
    KEY=$(get_key "groq")
    rate_limit_wait
    PROMPT_OUT=$(timeout 90 env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" NODE_NO_WARNINGS=1 \
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

AMI_BIN=$(which ami 2>/dev/null || echo "")
if [ -n "$AMI_BIN" ]; then
  # Binary is not a shell script (should be compiled)
  FIRST_BYTES=$(head -c 2 "$AMI_BIN" 2>/dev/null | xxd -p 2>/dev/null || echo "")
  FILE_TYPE=$(file "$AMI_BIN" 2>/dev/null || echo "unknown")

  # It's either an ELF binary, a Mach-O, or a Node.js SEA
  if echo "$FILE_TYPE" | grep -qiE "ELF|Mach-O|executable|PE32"; then
    pass "binary: compiled executable"
  elif echo "$FILE_TYPE" | grep -qi "script"; then
    skip "binary: script wrapper" "$(echo "$FILE_TYPE" | head -c 40)"
  else
    pass "binary: type $(echo "$FILE_TYPE" | head -c 40)"
  fi

  # Extract strings once (cached) to avoid re-scanning 150MB binary per check
  STRINGS_CACHE=$(timeout 60 strings "$AMI_BIN" 2>/dev/null || true)

  # Binary should not contain raw source paths
  if echo "$STRINGS_CACHE" | grep -q "ami-ui/cli/src/" 2>/dev/null; then
    fail "binary: no source paths leaked"
  else
    pass "binary: no source paths leaked"
  fi

  # Binary should not contain raw API keys
  if [ -f "$FRITO_CONFIG" ]; then
    for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
      KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      if [ -n "$KEY" ] && echo "$STRINGS_CACHE" | grep -q "$KEY" 2>/dev/null; then
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

# Test files should not contain real API keys
for tf in "$SCRIPT_DIR"/*.sh; do
  [ -f "$tf" ] || continue
  FNAME=$(basename "$tf")

  if [ -f "$FRITO_CONFIG" ]; then
    for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
      KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      if [ -n "$KEY" ] && grep -q "$KEY" "$tf" 2>/dev/null; then
        fail "test-sec/$FNAME: no $pid key hardcoded"
      else
        pass "test-sec/$FNAME: no $pid key"
      fi
    done
  fi
done

# Workflow file should not contain real keys
WF_FILE="$CI_DIR/.github/workflows/frito.yml"
if [ -f "$WF_FILE" ]; then
  if [ -f "$FRITO_CONFIG" ]; then
    for pid in $(jq -r '.providers | keys[]' "$FRITO_CONFIG" 2>/dev/null); do
      KEY=$(jq -r ".providers.$pid.keys[0]" "$FRITO_CONFIG" 2>/dev/null || echo "")
      if [ -n "$KEY" ] && grep -q "$KEY" "$WF_FILE" 2>/dev/null; then
        fail "test-sec/workflow: no $pid key"
      else
        pass "test-sec/workflow: no $pid key"
      fi
    done
  fi

  # Workflow uses secrets, not hardcoded values
  grep -q "secrets.AMI_FRITO" "$WF_FILE" && pass "test-sec/workflow: uses secrets.AMI_FRITO" || skip "test-sec/workflow: secrets ref"
  grep -q "chmod 600" "$WF_FILE" && pass "test-sec/workflow: chmod 600 on config" || skip "test-sec/workflow: chmod 600"
else
  skip "test-sec/workflow" "not found"
fi

# ═══════════════════════════════════════════════════════════════════
# SECTION 8: Repo Structure
# ═══════════════════════════════════════════════════════════════════
section "Repo Structure"

# Only expected file types
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

# No large files (>1MB)
LARGE=$(find "$CI_DIR" -type f -size +1M -not -path "*/.git/*" 2>/dev/null | head -1 || true)
[ -z "$LARGE" ] && pass "repo: no files >1MB" || fail "repo: large file" "$LARGE"

# No hidden files (except .git, .github, .gitignore)
HIDDEN=$(find "$CI_DIR" -maxdepth 1 -name ".*" -not -name ".git" -not -name ".github" -not -name ".gitignore" 2>/dev/null | head -1 || true)
[ -z "$HIDDEN" ] && pass "repo: no unexpected hidden files" || skip "repo: hidden file" "$HIDDEN"

summary
