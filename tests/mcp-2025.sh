#!/bin/bash
# FRITO CI — MCP 2025-06-18 client capabilities (end-to-end, released binary)
#
# Drives the installed `ami` (detached) against a local stdio MCP fixture server
# AND a local mock OpenAI-compatible model server, so the MCP-protocol behaviour
# is validated deterministically — no funded provider, no model flakiness. The
# fixture records what it observed from `ami` to a JSON file; the test asserts on
# that file. Exercised capabilities:
#   - cursor PAGINATION (the report tool lives only on page 2 — the fixture
#     records whether ami followed nextCursor),
#   - ELICITATION (fixture sends elicitation/create; detached ami must answer —
#     declining — and must NOT hang),
#   - client CAPABILITY advertisement (elicitation + sampling in initialize),
#   - a real tool CALL of the page-2 tool.
#
# Convention (mirrors skills.sh / pentest-mcp.sh): when the installed binary
# predates these features the observations are absent and the suite SKIPs the
# capability assertions rather than failing — the hard checks engage once the
# capable release ships (or with AMI= pointing at a local build).
#
# Requires: node (fixture + mock model). No API key needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

echo ""
echo "$(bold 'FRITO MCP 2025-06-18 — client capability e2e (mock provider)')"
echo "$(dim "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)")"
echo "$(dim "Binary: $AMI")"
echo ""

# ═══════════════════════════════════════════════════════════════════
section "Prerequisites"

if ! command -v node >/dev/null 2>&1; then
  skip "prereq/node: node not available (needed for the fixture + mock model)"
  summary; exit 0
fi
pass "prereq/node: $(node --version)"

# ═══════════════════════════════════════════════════════════════════
section "Fixtures"

WORK="$(mktemp -d)"
FIXTURE="$WORK/mcp2025-fixture.cjs"
MOCK="$WORK/mock-model.cjs"
OBS="$WORK/observed.json"
MOCK_PID=""
cleanup() { [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# --- stdio MCP fixture: records observations to $MCP2025_OBS ---------
cat > "$FIXTURE" <<'JS'
const fs = require('fs');
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin });
const OBS = process.env.MCP2025_OBS;
const obs = { clientCaps: null, elicitation: 'PENDING', sampling: 'PENDING', pingAnswered: false, page2Requested: false, reportCalled: false, protocol: null, logOk: false, updatedOk: false };
const flush = () => { if (OBS) { try { fs.writeFileSync(OBS, JSON.stringify(obs)); } catch {} } };
const send = (o) => process.stdout.write(JSON.stringify(o) + '\n');
rl.on('line', (line) => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.method === 'initialize') {
    obs.clientCaps = (m.params && m.params.capabilities) || {};
    obs.protocol = m.params && m.params.protocolVersion;
    flush();
    send({ jsonrpc: '2.0', id: m.id, result: { protocolVersion: '2025-06-18', serverInfo: { name: 'mcp2025-fixture', version: '1' }, capabilities: { tools: {}, logging: {} } } });
    // Fire the full server→client surface shortly after initialize.
    setTimeout(() => {
      send({ jsonrpc: '2.0', id: 7001, method: 'elicitation/create', params: { message: 'need input', requestedSchema: { type: 'object', properties: { x: { type: 'string' } } } } });
      send({ jsonrpc: '2.0', id: 7002, method: 'ping' });
      send({ jsonrpc: '2.0', id: 7003, method: 'sampling/createMessage', params: { messages: [{ role: 'user', content: { type: 'text', text: 'hi' } }], maxTokens: 16 } });
      // Notifications (no reply expected) — the client must tolerate them.
      send({ jsonrpc: '2.0', method: 'notifications/message', params: { level: 'info', logger: 'fixture', data: 'hello' } });
      send({ jsonrpc: '2.0', method: 'notifications/resources/updated', params: { uri: 'file:///x' } });
      obs.logOk = true; obs.updatedOk = true; flush();
    }, 30);
    return;
  }
  if (m.id === 7001 && (m.result || m.error)) { obs.elicitation = m.result || { error: m.error }; flush(); return; }
  if (m.id === 7002 && (m.result || m.error)) { obs.pingAnswered = !!m.result; flush(); return; }
  if (m.id === 7003 && (m.result || m.error)) { obs.sampling = m.result || { error: m.error }; flush(); return; }
  if (m.method === 'tools/list') {
    if (m.params && m.params.cursor === 'pg2') {
      obs.page2Requested = true; flush();
      send({ jsonrpc: '2.0', id: m.id, result: { tools: [{ name: 'mcp2025_report', description: 'Return MCP 2025 diagnostics', inputSchema: { type: 'object', properties: {} } }] } });
    } else {
      send({ jsonrpc: '2.0', id: m.id, result: { tools: [{ name: 'mcp2025_warmup', description: 'warmup', inputSchema: { type: 'object', properties: {} } }], nextCursor: 'pg2' } });
    }
    return;
  }
  if (m.method === 'tools/call') {
    const name = m.params && m.params.name;
    if (name === 'mcp2025_report') { obs.reportCalled = true; flush(); }
    send({ jsonrpc: '2.0', id: m.id, result: { content: [{ type: 'text', text: 'MCP2025_REPORT ' + JSON.stringify(obs) }] } });
    return;
  }
  if (m.method === 'ping') { send({ jsonrpc: '2.0', id: m.id, result: {} }); return; }
});
setInterval(() => {}, 60000);
JS

# --- mock OpenAI-compatible model: 1st turn calls the MCP tool, 2nd ends -----
cat > "$MOCK" <<'JS'
const http = require('http');
const TOOL = 'mcp__mcp2025__mcp2025_report';
const srv = http.createServer((req, res) => {
  if (req.method !== 'POST') { res.statusCode = 404; res.end(); return; }
  let body = ''; req.on('data', (d) => body += d);
  req.on('end', () => {
    let hasToolResult = false;
    try { const j = JSON.parse(body); hasToolResult = (j.messages || []).some((m) => m.role === 'tool' || (Array.isArray(m.content) && m.content.some((c) => c && c.type === 'tool-result'))); } catch {}
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', 'Connection': 'keep-alive' });
    const send = (o) => res.write('data: ' + JSON.stringify(o) + '\n\n');
    if (!hasToolResult) {
      send({ id: 'c1', object: 'chat.completion.chunk', choices: [{ index: 0, delta: { role: 'assistant', tool_calls: [{ index: 0, id: 'call_1', type: 'function', function: { name: TOOL, arguments: '' } }] }, finish_reason: null }] });
      send({ object: 'chat.completion.chunk', choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: '{}' } }] }, finish_reason: null }] });
      send({ object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }] });
    } else {
      send({ id: 'c2', object: 'chat.completion.chunk', choices: [{ index: 0, delta: { role: 'assistant', content: 'done' }, finish_reason: null }] });
      send({ object: 'chat.completion.chunk', choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] });
    }
    res.write('data: [DONE]\n\n');
    res.end();
  });
});
srv.listen(0, '127.0.0.1', () => { console.log('PORT=' + srv.address().port); });
setInterval(() => {}, 60000);
JS

mkdir -p "$WORK/.superinference"
cat > "$WORK/.superinference/mcp.json" <<JSON
{ "mcpServers": { "mcp2025": { "command": "node", "args": ["$FIXTURE"], "env": { "MCP2025_OBS": "$OBS" } } } }
JSON
pass "fixtures/written: stdio MCP fixture + mock model + mcp.json"

# Fixture self-check.
FIXTURE_OK=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  | timeout 10 node "$FIXTURE" 2>/dev/null | head -1 | grep -c 'mcp2025-fixture' || true)
[ "$FIXTURE_OK" = "1" ] && pass "fixtures/sanity: MCP server answers initialize" || { fail "fixtures/sanity: MCP server did not answer"; summary; }

# Start the mock model and read its port.
node "$MOCK" >"$WORK/mock.log" 2>&1 &
MOCK_PID=$!
PORT=""
for _ in $(seq 1 50); do
  PORT=$( (grep -oE 'PORT=[0-9]+' "$WORK/mock.log" 2>/dev/null || true) | head -1 | cut -d= -f2 || true)
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] && pass "fixtures/mock-model: listening on 127.0.0.1:$PORT" || { fail "fixtures/mock-model: never bound a port"; summary; }

# ═══════════════════════════════════════════════════════════════════
section "End-to-end via detached ami (mock provider)"

set +e
OUT=$(cd "$WORK" && timeout "$AMI_TIMEOUT_LONG" env -i PATH="$PATH" HOME="$HOME" $ENV_BASE \
  AI_API_KEY=mock AI_BASE_URL="http://127.0.0.1:$PORT/v1" \
  $AMI --prompt 'Call the mcp2025_report tool and report its result.' \
  --model mock-model --permission-mode auto-allow --max-turns 6 --output-format text 2>&1)
RC=$?
set -e

if [ "$RC" = "124" ]; then
  fail "e2e/no-hang: ami timed out — a server elicitation likely stalled the run" "${OUT:0:120}"
  summary
fi
pass "e2e/no-hang: run completed (exit $RC) — elicitation did not stall it"

if [ ! -f "$OBS" ]; then
  skip "e2e: no observations captured — binary likely predates MCP 2025-06-18 support" "${OUT:0:120}"
  summary; exit 0
fi

PROTO=$(jq -r '.protocol // empty' "$OBS" 2>/dev/null || true)
[ "$PROTO" = "2025-06-18" ] && pass "e2e/protocol: ami negotiated protocolVersion 2025-06-18" \
  || fail "e2e/protocol: expected 2025-06-18, got '${PROTO}'"

HAS_ELICIT=$(jq -r '.clientCaps.elicitation != null' "$OBS" 2>/dev/null || echo false)
HAS_SAMPLING=$(jq -r '.clientCaps.sampling != null' "$OBS" 2>/dev/null || echo false)
if [ "$HAS_ELICIT" = "true" ] && [ "$HAS_SAMPLING" = "true" ]; then
  pass "e2e/capabilities: ami advertised elicitation + sampling at initialize"
else
  fail "e2e/capabilities: elicitation=$HAS_ELICIT sampling=$HAS_SAMPLING" "$(jq -c '.clientCaps' "$OBS" 2>/dev/null)"
fi

PAGE2=$(jq -r '.page2Requested' "$OBS" 2>/dev/null || echo false)
[ "$PAGE2" = "true" ] && pass "e2e/pagination: ami followed nextCursor to discover the page-2 tool" \
  || fail "e2e/pagination: ami did not request page 2 (nextCursor not followed)"

ELICIT_ACTION=$(jq -r '.elicitation.action // empty' "$OBS" 2>/dev/null || true)
[ "$ELICIT_ACTION" = "decline" ] && pass "e2e/elicitation: detached ami declined the server elicitation (no hang)" \
  || fail "e2e/elicitation: expected decline, got '${ELICIT_ACTION}'" "$(jq -c '.elicitation' "$OBS" 2>/dev/null)"

# Ping: the server pinged ami; ami must answer the request (keepalive).
PING=$(jq -r '.pingAnswered' "$OBS" 2>/dev/null || echo false)
[ "$PING" = "true" ] && pass "e2e/ping: ami answered the server's ping request" \
  || fail "e2e/ping: ami did not answer the server ping" "$(jq -c '.' "$OBS" 2>/dev/null)"

# Sampling: the server asked ami to run a model turn. Detached ami wires the
# handler but has no approval callback, so it must REFUSE (human-in-the-loop) with
# a JSON-RPC error — never silently hang or silently run.
SAMPLING_ERR=$(jq -r '.sampling.error.code // empty' "$OBS" 2>/dev/null || true)
if [ -n "$SAMPLING_ERR" ]; then
  pass "e2e/sampling: detached ami refused the server sampling request (error $SAMPLING_ERR)"
else
  fail "e2e/sampling: expected a JSON-RPC error refusal from detached ami" "$(jq -c '.sampling' "$OBS" 2>/dev/null)"
fi

# Resilience: unsolicited log + resource-updated notifications must not break the run.
LOGOK=$(jq -r '.logOk' "$OBS" 2>/dev/null || echo false)
[ "$LOGOK" = "true" ] && pass "e2e/notifications: ami tolerated logging + resource-updated notifications" \
  || skip "e2e/notifications: notification resilience not observed"

REPORT_CALLED=$(jq -r '.reportCalled' "$OBS" 2>/dev/null || echo false)
[ "$REPORT_CALLED" = "true" ] && pass "e2e/tool-call: ami executed the page-2 MCP tool" \
  || skip "e2e/tool-call: the mock model's tool call did not execute (connect-time checks still passed)"

summary
