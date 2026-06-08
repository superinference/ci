#!/bin/bash
# FRITO CI — binary install and health tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

section "AMI Binary Install"

# Install via official script
INSTALL_OUTPUT=$(curl -fsSL https://www.superinference.org/install.sh | bash 2>&1) || true

# Test: install script ran
if echo "$INSTALL_OUTPUT" | grep -qi "install\|update"; then
  pass "install script executed"
else
  fail "install script executed" "no install/update output"
fi

# Find the binary
AMI_BIN=""
for candidate in "$HOME/.local/bin/ami" /usr/local/bin/ami; do
  if [ -f "$candidate" ]; then
    AMI_BIN="$candidate"
    break
  fi
done

# Also check PATH
if [ -z "$AMI_BIN" ] && command -v ami >/dev/null 2>&1; then
  AMI_BIN=$(command -v ami)
fi

if [ -z "$AMI_BIN" ]; then
  fail "binary found" "ami not found in expected locations"
  summary
  exit 1
fi

pass "binary found at $AMI_BIN"

section "Binary Health Checks"

# Test: binary is executable
if [ -x "$AMI_BIN" ]; then
  pass "binary is executable"
else
  fail "binary is executable"
fi

# Test: file size is reasonable (>100KB, <100MB)
SIZE=$(stat -c%s "$AMI_BIN" 2>/dev/null || stat -f%z "$AMI_BIN" 2>/dev/null || echo "0")
if [ "$SIZE" -gt 100000 ] && [ "$SIZE" -lt 200000000 ]; then
  pass "binary size reasonable ($(( SIZE / 1024 ))KB)"
else
  fail "binary size reasonable" "size=$SIZE bytes"
fi

# Test: --version returns valid output
VERSION_OUTPUT=$("$AMI_BIN" --version 2>&1 || true)
if echo "$VERSION_OUTPUT" | grep -q "superinference v"; then
  pass "--version output: $VERSION_OUTPUT"
else
  fail "--version returns valid output" "got: $VERSION_OUTPUT"
fi

# Test: version string format
if echo "$VERSION_OUTPUT" | grep -qE "v[0-9]+\.[0-9]+\.[0-9]+"; then
  pass "version matches semver pattern"
else
  fail "version matches semver pattern" "$VERSION_OUTPUT"
fi

# Test: --help returns usage info
HELP_OUTPUT=$("$AMI_BIN" --help 2>&1 || true)
if echo "$HELP_OUTPUT" | grep -qi "usage\|options\|help"; then
  pass "--help shows usage info"
else
  fail "--help shows usage info"
fi

# Test: --help mentions key options
for opt in "--base-url" "--api-key" "--model"; do
  if echo "$HELP_OUTPUT" | grep -qF -- "$opt"; then
    pass "--help documents $opt"
  else
    fail "--help documents $opt"
  fi
done

# Test: --help mentions env vars
for var in "AI_API_KEY" "GOOGLE_API_KEY"; do
  if echo "$HELP_OUTPUT" | grep -q "$var"; then
    pass "--help documents $var"
  else
    fail "--help documents $var"
  fi
done

# Test: no error exit code for --version
if "$AMI_BIN" --version >/dev/null 2>&1; then
  pass "--version exits cleanly"
else
  fail "--version exits cleanly"
fi

# Test: no error exit code for --help
if "$AMI_BIN" --help >/dev/null 2>&1; then
  pass "--help exits cleanly"
else
  fail "--help exits cleanly"
fi

# Test: binary is not a symlink to something weird
if [ -L "$AMI_BIN" ]; then
  TARGET=$(readlink -f "$AMI_BIN")
  if [ -f "$TARGET" ]; then
    pass "symlink target exists ($TARGET)"
  else
    fail "symlink target exists" "broken symlink → $TARGET"
  fi
else
  pass "binary is a regular file (not symlink)"
fi

summary
