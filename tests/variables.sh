#!/bin/bash
# FRITO CI — Centralized test configuration
# All tunable values in one place. Every test script sources this via helpers.sh.

# ─── Timeouts ────────────────────────────────────────────────────
# AMI_TIMEOUT: maximum seconds for a single `ami --prompt` invocation.
# Provider/CLI tests use the shorter timeout; agent-feature tests need longer
# because tool-calling round-trips add latency.
AMI_TIMEOUT_SHORT=45       # providers, cli, slash-commands
AMI_TIMEOUT_LONG=90        # agent-features (tool use, multi-turn)

# Probe timeout: how long to wait when probing a provider to see if it's live.
PROBE_TIMEOUT=30

# ─── Max turns ───────────────────────────────────────────────────
# MAX_TURNS_PROBE: used during liveness probes (just needs one successful reply).
MAX_TURNS_PROBE=4
# MAX_TURNS_TOOL: used during tool-use tests (model calls tool, gets result, replies).
# Needs ≥4: call tool → read result → (optional retry) → reply.
MAX_TURNS_TOOL=5

# ─── Environment baseline ───────────────────────────────────────
# Every `env -i` invocation should include these to suppress TUI chrome and warnings.
# Usage: env -i PATH="$PATH" HOME="$HOME" $ENV_BASE ...
ENV_BASE='TERM=dumb SI_NO_SPLASH=1 NODE_NO_WARNINGS=1'

# ─── Expect (interactive TUI tests) ─────────────────────────────
# Single slash command session
EXPECT_OUTER_TIMEOUT=60    # outer `timeout` wrapper (seconds)
EXPECT_INNER_TIMEOUT=45    # expect's `set timeout` (seconds)
EXPECT_SPAWN_WAIT=5        # sleep after spawn before sending commands
EXPECT_CMD_WAIT=5          # sleep after sending a command before /quit

# Multi-command session
EXPECT_MULTI_OUTER_TIMEOUT=120
EXPECT_MULTI_INNER_TIMEOUT=90
EXPECT_MULTI_CMD_WAIT=3    # sleep between sequential commands

# ─── Rate limiting ──────────────────────────────────────────────
MIN_REQUEST_INTERVAL=3     # seconds between generic API calls
GOOGLE_REQUEST_INTERVAL=5  # seconds between Google API calls (stricter quota)
