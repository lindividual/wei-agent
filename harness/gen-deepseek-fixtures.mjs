#!/usr/bin/env node
/**
 * Generate SSE fixtures and their expected parses.
 *
 * pi-ai is the oracle: every expectation below comes from running the real
 * `openai-completions` stream parser against the same bytes our implementation
 * will see. Nothing here is hand-written, so a disagreement means our parser
 * diverges from pi, not that a constant drifted.
 *
 * Output is a MoonBit source file rather than data files, because `core/` must
 * stay free of IO in order to keep compiling for every backend.
 *
 *   node harness/gen-deepseek-fixtures.mjs
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const PI_AI =
  "/opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai";

const { stream } = await import(`${PI_AI}/dist/api/openai-completions.js`);
const catalog = JSON.parse(
  readFileSync(`${PI_AI}/dist/providers/data/deepseek.json`, "utf8"),
);
const MODEL = catalog["openai-completions"]["deepseek-v4-flash"];

/** A frozen timestamp so the expected output is comparable. */
const TIMESTAMP = 1700000000000;

// ── SSE construction ───────────────────────────────────────────────────────

/** One `data:` frame. */
const frame = (obj) => `data: ${JSON.stringify(obj)}\n\n`;

/** A minimal chunk with a delta. */
const delta = (d, extra = {}) => ({
  id: "chatcmpl-fixture",
  object: "chat.completion.chunk",
  created: 1,
  model: "deepseek-v4-flash",
  choices: [{ index: 0, delta: d, finish_reason: null }],
  ...extra,
});

/** A chunk carrying only a finish_reason. */
const finish = (reason, extra = {}) => ({
  id: "chatcmpl-fixture",
  object: "chat.completion.chunk",
  created: 1,
  model: "deepseek-v4-flash",
  choices: [{ index: 0, delta: {}, finish_reason: reason }],
  ...extra,
});

/** A usage-only trailer chunk; OpenAI sends these with an empty choices array. */
const usage = (u) => ({
  id: "chatcmpl-fixture",
  object: "chat.completion.chunk",
  created: 1,
  model: "deepseek-v4-flash",
  choices: [],
  usage: u,
});

const USAGE_BASIC = {
  prompt_tokens: 100,
  completion_tokens: 5,
  total_tokens: 105,
  prompt_cache_hit_tokens: 0,
  completion_tokens_details: { reasoning_tokens: 0 },
};

// ── Fixtures ───────────────────────────────────────────────────────────────

const fixtures = [
  {
    name: "simple_text",
    about: "纯文本，delta 分多块到达",
    body:
      frame(delta({ content: "Hello" })) +
      frame(delta({ content: ", " })) +
      frame(delta({ content: "world" })) +
      frame(finish("stop")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "thinking_then_text",
    about: "reasoning_content 先到，正文后到；signature 必须是 reasoning_content",
    body:
      frame(delta({ reasoning_content: "Let me " })) +
      frame(delta({ reasoning_content: "think." })) +
      frame(delta({ content: "Answer." })) +
      frame(finish("stop")) +
      frame(
        usage({
          ...USAGE_BASIC,
          completion_tokens: 12,
          completion_tokens_details: { reasoning_tokens: 7 },
        }),
      ) +
      "data: [DONE]\n\n",
  },
  {
    name: "single_tool_call",
    about: "工具参数被切成多个片段，必须拼回来再解析",
    body:
      frame(delta({ content: "Let me look." })) +
      frame(
        delta({
          tool_calls: [
            {
              index: 0,
              id: "call_abc",
              type: "function",
              function: { name: "read", arguments: '{"pa' },
            },
          ],
        }),
      ) +
      frame(
        delta({
          tool_calls: [
            { index: 0, function: { arguments: 'th":"src/' } },
          ],
        }),
      ) +
      frame(
        delta({
          tool_calls: [{ index: 0, function: { arguments: 'main.ts"}' } }],
        }),
      ) +
      frame(finish("tool_calls")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "parallel_tool_calls",
    about: "两个工具调用交错到达，必须按 index 归位",
    body:
      frame(
        delta({
          tool_calls: [
            { index: 0, id: "call_a", type: "function", function: { name: "read", arguments: '{"path":"a"}' } },
            { index: 1, id: "call_b", type: "function", function: { name: "grep", arguments: '{"pat' } },
          ],
        }),
      ) +
      frame(
        delta({
          tool_calls: [
            { index: 1, function: { arguments: 'tern":"x"}' } },
            { index: 0, function: { arguments: "" } },
          ],
        }),
      ) +
      frame(finish("tool_calls")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "usage_with_cache",
    about: "prompt_cache_hit_tokens 非零；输入计数要扣掉缓存命中",
    body:
      frame(delta({ content: "cached" })) +
      frame(finish("stop")) +
      frame(
        usage({
          prompt_tokens: 5000,
          completion_tokens: 30,
          total_tokens: 5030,
          prompt_cache_hit_tokens: 4608,
          completion_tokens_details: { reasoning_tokens: 11 },
        }),
      ) +
      "data: [DONE]\n\n",
  },
  {
    name: "cache_in_details",
    about: "OpenAI 风格的 prompt_tokens_details.cached_tokens 优先于 deepseek 字段",
    body:
      frame(delta({ content: "x" })) +
      frame(finish("stop")) +
      frame(
        usage({
          prompt_tokens: 200,
          completion_tokens: 1,
          total_tokens: 201,
          prompt_cache_hit_tokens: 999,
          prompt_tokens_details: { cached_tokens: 150, cache_write_tokens: 10 },
        }),
      ) +
      "data: [DONE]\n\n",
  },
  {
    name: "finish_length",
    about: "finish_reason=length 映射到 Length",
    body:
      frame(delta({ content: "truncated…" })) +
      frame(finish("length")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "finish_content_filter",
    about: "content_filter 映射到 Error 并带出错误信息",
    body:
      frame(delta({ content: "partial" })) +
      frame(finish("content_filter")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "reasoning_alias",
    about: "兼容端点用 reasoning 而非 reasoning_content，signature 要跟着变",
    body:
      frame(delta({ reasoning: "alt " })) +
      frame(delta({ reasoning: "field" })) +
      frame(delta({ content: "done" })) +
      frame(finish("stop")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "response_model_differs",
    about: "API 回传的 model 名与请求不同时记入 responseModel",
    body:
      frame({
        ...delta({ content: "hi" }),
        model: "deepseek-flash",
      }) +
      frame({ ...finish("stop"), model: "deepseek-flash" }) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "noise_between_events",
    about: "空 delta、非 JSON 负载与注释行都不能破坏解析",
    body:
      ": keep-alive\n\n" +
      frame(delta({ content: "a" })) +
      "data: not-json\n\n" +
      "\n\n" +
      frame(delta({})) +
      frame(delta({ content: "b" })) +
      frame(finish("stop")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "unicode_split",
    about: "多字节字符跨 chunk 拼接后必须完整",
    body:
      frame(delta({ content: "让我" })) +
      frame(delta({ content: "读一下" })) +
      frame(delta({ content: "这个文件。" })) +
      frame(finish("stop")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
  {
    name: "empty_content_null",
    about: "content 为 null 的 delta 不能被当成空字符串追加",
    body:
      frame(delta({ content: null })) +
      frame(delta({ content: "real" })) +
      frame(delta({ content: null, reasoning_content: null })) +
      frame(finish("stop")) +
      frame(usage(USAGE_BASIC)) +
      "data: [DONE]\n\n",
  },
];

// ── Run the oracle ─────────────────────────────────────────────────────────

async function parseWithPi(body) {
  const fakeFetch = async () =>
    new Response(body, {
      status: 200,
      headers: { "content-type": "text/event-stream" },
    });
  const s = stream(
    MODEL,
    {
      messages: [
        { role: "user", content: [{ type: "text", text: "hi" }], timestamp: TIMESTAMP },
      ],
    },
    { apiKey: "fixture-key", fetch: fakeFetch },
  );
  let message = null;
  let error = null;
  for await (const ev of s) {
    if (ev.type === "done") message = ev.message;
    if (ev.type === "error") error = ev.error;
  }
  return { message, error };
}

/** Drop fields our comparison does not cover, and freeze the timestamp. */
function normalize(msg) {
  const out = { ...msg, timestamp: TIMESTAMP };
  return out;
}

const results = [];
for (const fx of fixtures) {
  const { message, error } = await parseWithPi(fx.body);
  const payload = message ?? error;
  if (!payload) {
    throw new Error(`fixture ${fx.name}: pi produced neither message nor error`);
  }
  results.push({
    name: fx.name,
    about: fx.about,
    body: fx.body,
    expected: normalize(payload),
  });
  const tag = message ? "ok" : "error-event";
  console.log(
    `${fx.name.padEnd(24)} ${tag.padEnd(12)} stopReason=${payload.stopReason} blocks=${(payload.content || []).length}`,
  );
}

// Responses recorded from the live API, if any. These carry their own recorded
// bytes and pi-derived expectation, so they are merged rather than rebuilt.
const livePath = "harness/fixtures/live.json";
if (existsSync(livePath)) {
  for (const rec of JSON.parse(readFileSync(livePath, "utf8"))) {
    results.push({
      name: rec.name,
      about: rec.about,
      body: rec.body,
      expected: normalize(rec.expected),
    });
    console.log(
      `${rec.name.padEnd(24)} ${"recorded".padEnd(12)} stopReason=${rec.expected.stopReason} blocks=${(rec.expected.content || []).length}`,
    );
  }
}

// ── Emit MoonBit ───────────────────────────────────────────────────────────

const esc = (s) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");

const lines = [
  "///|",
  "/// DeepSeek SSE fixtures and the parse pi-ai produces for them.",
  "///",
  "/// Generated by `harness/gen-deepseek-fixtures.mjs`; do not edit by hand.",
  "/// pi-ai is the oracle, so a test failure here means this implementation",
  "/// diverges from pi rather than that a constant drifted.",
  "///",
  "/// Each entry is (name, what it protects, sse body, expected message JSON).",
  "pub let sse_fixtures : Array[(String, String, String, String)] = [",
];
for (const { name, about, body, expected } of results) {
  lines.push("  (");
  lines.push(`    "${name}",`);
  lines.push(`    "${esc(about)}",`);
  lines.push(`    "${esc(body)}",`);
  lines.push(`    "${esc(JSON.stringify(expected))}",`);
  lines.push("  ),");
}
lines.push("]");

writeFileSync("core/deepseek_fixtures.mbt", lines.join("\n") + "\n");
console.log(`\nwrote core/deepseek_fixtures.mbt (${results.length} fixtures)`);
