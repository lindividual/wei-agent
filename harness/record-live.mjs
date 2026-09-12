#!/usr/bin/env node
/**
 * Record live DeepSeek responses and turn them into fixtures.
 *
 * Hand-built SSE covers the shapes worth protecting, but it encodes assumptions
 * about what the provider sends. A recorded response has no such assumptions:
 * it is whatever DeepSeek actually emitted, which is the only thing that can
 * catch a rule the fixtures were written around.
 *
 * The recorded bytes are also parsed by pi-ai so the expectation is the
 * oracle's, not ours.
 *
 *   node harness/record-live.mjs            # record and refresh fixtures
 *   node harness/record-live.mjs --dry      # show what would be recorded
 *
 * Requires a DeepSeek key: DEEPSEEK_API_KEY, or pi's credential store.
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";

const PI_AI =
  "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai";

const { stream } = await import(`${PI_AI}/dist/api/openai-completions.js`);
const catalog = JSON.parse(
  readFileSync(`${PI_AI}/dist/providers/data/deepseek.json`, "utf8"),
);
const MODEL = catalog["openai-completions"]["deepseek-v4-flash"];
const T = 1700000000000;
const EMPTY_USAGE = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};

function apiKey() {
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY;
  const path = `${homedir()}/.pi/agent/auth.json`;
  if (!existsSync(path)) throw new Error("no key: set DEEPSEEK_API_KEY");
  const store = JSON.parse(readFileSync(path, "utf8"));
  const key = store?.deepseek?.key;
  if (!key) throw new Error("no deepseek key in pi's credential store");
  return key;
}

const READ_TOOL = {
  name: "read",
  description: "Read the contents of a file.",
  parameters: {
    type: "object",
    properties: { path: { type: "string", description: "Path to read" } },
    required: ["path"],
  },
};

// Requests are built by pi, so the recorded response corresponds to a real
// request shape rather than a hand-written approximation of one.
const scenarios = [
  {
    name: "live_simple",
    about: "真实响应：无思考等级，纯文本",
    context: {
      messages: [
        { role: "user", content: [{ type: "text", text: "Reply with exactly: pong" }], timestamp: T },
      ],
    },
    options: {},
  },
  {
    name: "live_thinking",
    about: "真实响应：开启思考，reasoning_content 与正文并存",
    context: {
      messages: [
        {
          role: "user",
          content: [{ type: "text", text: "What is 17 * 23? Reply with just the number." }],
          timestamp: T,
        },
      ],
    },
    options: { reasoningEffort: "high" },
  },
  {
    name: "live_tool_call",
    about: "真实响应：模型发起工具调用，参数分块到达",
    context: {
      messages: [
        {
          role: "user",
          content: [{ type: "text", text: "Read the file src/index.ts please." }],
          timestamp: T,
        },
      ],
      tools: [READ_TOOL],
      systemPrompt: "You are a coding agent. Use the read tool when asked.",
    },
    options: { reasoningEffort: "high" },
  },
];

const dry = process.argv.includes("--dry");
const key = dry ? null : apiKey();

async function record(scenario) {
  // Capture the request pi would send, then issue it for real so the response
  // is genuine and not a replay.
  let requestBody = null;
  const capture = async (_url, init) => {
    requestBody = JSON.parse(init.body);
    return new Response("", { status: 200, headers: { "content-type": "text/event-stream" } });
  };
  const captureStream = stream(MODEL, scenario.context, {
    ...scenario.options,
    apiKey: "capture",
    fetch: capture,
  });
  for await (const _ of captureStream) {
    // Drain to trigger the request.
  }

  if (dry) return { requestBody, sse: null };

  const response = await fetch("https://api.deepseek.com/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(requestBody),
  });
  if (!response.ok) {
    throw new Error(`live request failed: ${response.status} ${await response.text()}`);
  }
  const sse = await response.text();
  return { requestBody, sse };
}

/** Parse recorded bytes with pi-ai so the expectation is the oracle's. */
async function expectFrom(sse) {
  const fakeFetch = async () =>
    new Response(sse, { status: 200, headers: { "content-type": "text/event-stream" } });
  const s = stream(
    MODEL,
    { messages: [{ role: "user", content: [{ type: "text", text: "x" }], timestamp: T }] },
    { apiKey: "fixture-key", fetch: fakeFetch },
  );
  let message = null;
  let error = null;
  for await (const ev of s) {
    if (ev.type === "done") message = ev.message;
    if (ev.type === "error") error = ev.error;
  }
  const payload = message ?? error;
  if (!payload) throw new Error("pi produced neither a message nor an error");
  return { ...payload, timestamp: T };
}

const out = [];
for (const scenario of scenarios) {
  const { requestBody, sse } = await record(scenario);
  if (dry) {
    console.log(`${scenario.name}: would send ${JSON.stringify(requestBody).length} bytes`);
    continue;
  }
  const expected = await expectFrom(sse);
  out.push({
    name: scenario.name,
    about: scenario.about,
    body: sse,
    expected,
  });
  console.log(
    `${scenario.name.padEnd(18)} sse=${String(sse.length).padStart(6)}B blocks=${(expected.content || []).length} stop=${expected.stopReason}`,
  );
}

if (!dry) {
  mkdirSync("harness/fixtures", { recursive: true });
  writeFileSync("harness/fixtures/live.json", JSON.stringify(out, null, 1));
  console.log(`\nwrote harness/fixtures/live.json (${out.length} recordings)`);
}
