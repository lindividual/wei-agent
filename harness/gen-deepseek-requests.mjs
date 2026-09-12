#!/usr/bin/env node
/**
 * Generate request-body fixtures for the DeepSeek request builder.
 *
 * The oracle is pi's own request construction, captured rather than recomputed:
 * `stream` accepts an injected `fetch`, so the body pi would have sent is read
 * straight off the request. That covers `buildParams` and `convertMessages`
 * together, including the ordering rules and the fields DeepSeek requires.
 *
 *   node harness/gen-deepseek-requests.mjs
 */
import { readFileSync, writeFileSync } from "node:fs";

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

const user = (text) => ({
  role: "user",
  content: [{ type: "text", text }],
  timestamp: T,
});
const assistant = (content, stopReason = "stop") => ({
  role: "assistant",
  content,
  api: "openai-completions",
  provider: "deepseek",
  model: "deepseek-v4-flash",
  usage: EMPTY_USAGE,
  stopReason,
  timestamp: T,
});
const toolResult = (id, name, text, isError = false) => ({
  role: "toolResult",
  toolCallId: id,
  toolName: name,
  content: [{ type: "text", text }],
  isError,
  timestamp: T,
});
const thinking = (text) => ({
  type: "thinking",
  thinking: text,
  thinkingSignature: "reasoning_content",
});
const text = (t) => ({ type: "text", text: t });
const call = (id, name, args) => ({
  type: "toolCall",
  id,
  name,
  arguments: args,
});

const READ_TOOL = {
  name: "read",
  description: "Read the contents of a file.",
  parameters: {
    type: "object",
    properties: { path: { type: "string", description: "Path to read" } },
    required: ["path"],
  },
};
const GREP_TOOL = {
  name: "grep",
  description: "Search file contents for a pattern.",
  parameters: {
    type: "object",
    properties: { pattern: { type: "string" } },
    required: ["pattern"],
  },
};

const ONLY_SSE =
  'data: {"id":"c","model":"deepseek-v4-flash","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n';

const fixtures = [
  {
    name: "simple_user",
    about: "单条 user 消息，content 是 parts 数组",
    input: { messages: [user("hello")] },
  },
  {
    name: "with_system_prompt",
    about: "系统提示走 system 角色，不是 developer",
    input: { messages: [user("hi")], systemPrompt: "You are a coding agent." },
  },
  {
    name: "multi_turn_text",
    about: "多轮纯文本对话",
    input: {
      messages: [
        user("first"),
        assistant([text("reply one")]),
        user("second"),
        assistant([text("reply two")]),
      ],
    },
  },
  {
    name: "thinking_replay",
    about: "回放 thinking 必须还原成 reasoning_content，否则 DeepSeek 报错",
    input: {
      messages: [
        user("q"),
        assistant([thinking("weighing options"), text("answer")]),
      ],
    },
  },
  {
    name: "assistant_without_reasoning_gets_empty_key",
    about: "同模型回放的 assistant 即使没有 thinking 也要带 reasoning_content 空串",
    input: {
      messages: [user("q"), assistant([text("plain")])],
    },
  },
  {
    name: "tool_call_replay",
    about: "tool_calls 的 arguments 是 JSON 字符串，不是嵌套对象",
    input: {
      messages: [
        user("read the file"),
        assistant([call("call_1", "read", { path: "src/a.ts" })], "toolUse"),
        toolResult("call_1", "read", "file contents"),
      ],
    },
  },
  {
    name: "tool_result_is_role_tool",
    about: "toolResult 映射为 role=tool 并带 tool_call_id",
    input: {
      messages: [
        user("q"),
        assistant([call("call_9", "grep", { pattern: "x" })], "toolUse"),
        toolResult("call_9", "grep", "match 1\nmatch 2"),
        assistant([text("found them")]),
      ],
    },
  },
  {
    name: "tool_result_error_flag",
    about: "isError 的 toolResult 仍然只是文本，错误标记不发给模型",
    input: {
      messages: [
        user("q"),
        assistant([call("c", "bash", { command: "false" })], "toolUse"),
        toolResult("c", "bash", "exit 1", true),
      ],
    },
  },
  {
    name: "empty_assistant_skipped",
    about: "既无文本也无工具调用的 assistant 必须整条丢弃",
    input: {
      messages: [
        user("q"),
        assistant([]),
        assistant([text("")]),
        assistant([text("kept")]),
      ],
    },
  },
  {
    name: "empty_user_skipped",
    about: "content 为空的 user 消息必须整条丢弃",
    input: {
      messages: [user(""), user("real")],
    },
  },
  {
    name: "thinking_high",
    about: "thinking 开启时附带 thinking 对象与 reasoning_effort",
    input: {
      messages: [user("q")],
      thinking: "high",
    },
  },
  {
    name: "thinking_off",
    about: "不指定等级时发送显式的 disabled",
    input: {
      messages: [user("q")],
      thinking: null,
    },
  },
  {
    name: "thinking_minimal",
    about: "catalog 里映射为 null 的等级仍会发送原等级名",
    input: {
      messages: [user("q")],
      thinking: "minimal",
    },
  },
  {
    name: "thinking_max",
    about: "max 等级映射到 max",
    input: {
      messages: [user("q")],
      thinking: "max",
    },
  },
  {
    name: "with_tools",
    about: "工具以 function 包装，parameters 是 JSON Schema",
    input: {
      messages: [user("q")],
      tools: [READ_TOOL, GREP_TOOL],
    },
  },
  {
    name: "max_tokens_and_temperature",
    about: "输出上限走 max_tokens 而不是 max_completion_tokens",
    input: {
      messages: [user("q")],
      maxTokens: 4096,
      temperature: 0.3,
    },
  },
  {
    name: "image_part",
    about: "图片编码为 data URL 的 image_url part",
    input: {
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: "look at this" },
            { type: "image", data: "AAAA", mimeType: "image/png" },
          ],
          timestamp: T,
        },
      ],
    },
  },
  {
    name: "text_plus_thinking_plus_tool",
    about: "一条 assistant 同时带 thinking、正文与工具调用",
    input: {
      messages: [
        user("q"),
        assistant(
          [
            thinking("reasoning"),
            text("calling a tool"),
            call("c1", "read", { path: "a" }),
          ],
          "toolUse",
        ),
        toolResult("c1", "read", "ok"),
      ],
    },
  },
  {
    name: "everything",
    about: "系统提示、工具、思考等级与多轮工具历史同时出现",
    input: {
      messages: [
        user("start"),
        assistant([thinking("hmm"), call("c1", "read", { path: "a" })], "toolUse"),
        toolResult("c1", "read", "aaa"),
        user("next"),
        assistant([text("done")]),
      ],
      systemPrompt: "Be terse.",
      tools: [READ_TOOL],
      thinking: "high",
      maxTokens: 1000,
      temperature: 0.5,
    },
  },
];

// ── Capture the body pi would send ─────────────────────────────────────────

async function captureBody(input) {
  let captured = null;
  const fakeFetch = async (_url, init) => {
    captured = JSON.parse(init.body);
    return new Response(ONLY_SSE, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  };
  const context = { messages: input.messages };
  if (input.systemPrompt) context.systemPrompt = input.systemPrompt;
  if (input.tools) context.tools = input.tools;
  const options = { apiKey: "fixture-key", fetch: fakeFetch };
  if (input.thinking !== undefined && input.thinking !== null) {
    options.reasoningEffort = input.thinking;
  }
  if (input.maxTokens) options.maxTokens = input.maxTokens;
  if (input.temperature !== undefined) options.temperature = input.temperature;

  const s = stream(MODEL, context, options);
  for await (const _ of s) {
    // Drain: the request is issued on the first pull.
  }
  if (!captured) throw new Error("no request body captured");
  return captured;
}

const results = [];
for (const fx of fixtures) {
  const expected = await captureBody(fx.input);
  results.push({ fx, expected });
  const msgs = expected.messages.length;
  const thinking = expected.thinking ? expected.thinking.type : "-";
  const effort = expected.reasoning_effort ?? "-";
  console.log(
    `${fx.name.padEnd(38)} msgs=${String(msgs).padEnd(3)} thinking=${thinking.padEnd(9)} effort=${effort}`,
  );
}

// ── Emit MoonBit ───────────────────────────────────────────────────────────

const esc = (s) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");

const lines = [
  "///|",
  "/// DeepSeek request-body fixtures, captured from pi's own request builder.",
  "///",
  "/// Generated by `harness/gen-deepseek-requests.mjs`; do not edit by hand.",
  "///",
  "/// Each entry is (name, what it protects, input JSON, expected body JSON).",
  "/// The input mirrors what a caller supplies: messages, optional system",
  "/// prompt, optional tools, a thinking level, and optional sampling knobs.",
  "pub let request_fixtures : Array[(String, String, String, String)] = [",
];
for (const { fx, expected } of results) {
  lines.push("  (");
  lines.push(`    "${fx.name}",`);
  lines.push(`    "${esc(fx.about)}",`);
  lines.push(`    "${esc(JSON.stringify(fx.input))}",`);
  lines.push(`    "${esc(JSON.stringify(expected))}",`);
  lines.push("  ),");
}
lines.push("]");

writeFileSync("core/deepseek_request_fixtures.mbt", lines.join("\n") + "\n");
console.log(`\nwrote core/deepseek_request_fixtures.mbt (${results.length} fixtures)`);
