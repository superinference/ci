# SuperInference CI

[![FRITO Test Suite](https://github.com/superinference/ci/actions/workflows/frito.yml/badge.svg)](https://github.com/superinference/ci/actions/workflows/frito.yml)
[![OpenShell Container](https://github.com/superinference/ci/actions/workflows/openshell.yml/badge.svg)](https://github.com/superinference/ci/actions/workflows/openshell.yml)

End-to-end test suite for [SuperInference AMI](https://www.superinference.org) — tests the released binary installed via the public install script against live provider APIs.

## Test Suites

| Suite | What it tests |
|-------|---------------|
| **Install** | Binary download, PATH, `--version`, `--help` |
| **Security** | No hardcoded keys, gitignore rules, file permissions (`security.sh`) |
| **Config** | `frito.json` schema, provider entries, model fields |
| **CLI** | All flags from `--help`, dynamic coverage gate |
| **Providers** | Core provider inference (5 providers) |
| **Providers All** | All 18 providers, model discovery, liveness probes |
| **Slash Commands** | TUI commands via `expect`, dynamic discovery |
| **Agent Features** | Tool execution, sessions, permissions, detached mode |
| **OpenShell** | Container build, security scan, in-container tests |

## How It Works

1. `ami` is installed fresh from `https://www.superinference.org/install.sh`
2. API keys are passed via `FRITO_JSON` env var from the `AMI_FRITO` GitHub secret -- **never written to disk**
3. Tests discover features dynamically (flags, commands, providers, models)
4. Any discovered feature without a test **fails the suite**
5. Runs weekly on Monday + on-demand via `workflow_dispatch`

## Running Locally

```bash
# Option A: env var (no file on disk)
export FRITO_JSON='{"enabled":false,"providers":{"groq":{"keys":["gsk_..."],"model":"...","tier":"paid"}}}'
bash tests/providers-all.sh

# Option B: config file
cp frito.example.json frito.json   # fill in real keys
FRITO_CONFIG=$PWD/frito.json bash tests/providers-all.sh

# Run all suites
for t in install security config cli providers providers-all slash-commands agent-features openshell; do
  echo "=== $t ==="
  bash "tests/$t.sh"
done
```

## Setup

1. Create the `AMI_FRITO` repository secret with the `FRITO_JSON` content (see `frito.example.json`)
2. The secret is passed as `FRITO_JSON` env var -- credentials never touch disk
3. Workflows run automatically on schedule or trigger manually from the Actions tab

## Dependencies

- `jq` -- JSON parsing
- `expect` -- PTY-based TUI testing (slash-commands suite only)
- `curl` -- API calls and ami installation
