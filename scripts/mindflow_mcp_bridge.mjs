#!/usr/bin/env node
/**
 * Zero-dependency stdio MCP bridge for SyncCanvas × MindFlow.
 * Forwards newline-delimited JSON-RPC 2.0 frames to a running SyncCanvas
 * server (local host mode or standalone sync_hub) via HTTP.
 *
 * Usage:
 *   node mindflow_mcp_bridge.mjs --url http://127.0.0.1:8787 --room default --read-only
 */
import readline from 'node:readline';

const args = process.argv.slice(2);
let baseUrl = 'http://127.0.0.1:8787';
let roomId = 'default';
let readOnly = false;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--read-only') {
    readOnly = true;
  } else if (args[i] === '--url' && i + 1 < args.length) {
    baseUrl = args[++i].replace(/\/+$/, '');
  } else if (args[i] === '--room' && i + 1 < args.length) {
    roomId = args[++i] || 'default';
  }
}

const endpoint = `${baseUrl}/api/rooms/${encodeURIComponent(roomId)}/mindflow/mcp?readOnly=${readOnly ? '1' : '0'}`;

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on('line', async (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let parsedId = null;
  try {
    const parsed = JSON.parse(trimmed);
    parsedId = parsed?.id ?? null;
  } catch {}

  try {
    const resp = await fetch(endpoint, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: trimmed,
    });
    if (resp.status === 202) return;
    const text = await resp.text();
    if (text.trim()) {
      process.stdout.write(`${text.trim()}\n`);
    }
  } catch (err) {
    if (parsedId !== null) {
      process.stdout.write(
        `${JSON.stringify({
          jsonrpc: '2.0',
          id: parsedId,
          error: {
            code: -32000,
            message: `SyncCanvas server unreachable at ${endpoint}: ${err.message}`,
          },
        })}\n`
      );
    }
  }
});
