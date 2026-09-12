///|
/// Real messages lifted verbatim from `~/.pi/agent/sessions/`, one per
/// shape worth protecting.
///
/// Generated, not hand written: each string is the inner `message` object
/// of a real session entry, picked as the shortest example of its shape.
/// Regenerate rather than edit if the format ever changes.
pub let fixtures : Array[(String, String)] = [
  (
    "user", "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"1\"}],\"timestamp\":1781021032905}",
  ),
  (
    "assistant_full", "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"The user says the frontend is down. Let me check.\",\"thinkingSignature\":\"reasoning_content\"},{\"type\":\"toolCall\",\"id\":\"call_00_XwhwwPSOUPjA5c8ph50R1295\",\"name\":\"bash\",\"arguments\":{\"command\":\"lsof -ti :5173\"}}],\"api\":\"openai-completions\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-pro\",\"usage\":{\"input\":76,\"output\":62,\"cacheRead\":182656,\"cacheWrite\":0,\"reasoning\":13,\"totalTokens\":182794,\"cost\":{\"input\":3.306e-05,\"output\":5.394e-05,\"cacheRead\":0.000662128,\"cacheWrite\":0,\"total\":0.000749128}},\"stopReason\":\"toolUse\",\"timestamp\":1784470926440,\"responseId\":\"b666b8f0-770e-4383-912b-d8c9e5b33223\"}",
  ),
  (
    "assistant_respmodel", "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"恢复成功\"}],\"api\":\"openai-completions\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-flash\",\"usage\":{\"input\":176,\"output\":3,\"cacheRead\":7040,\"cacheWrite\":0,\"reasoning\":0,\"totalTokens\":7219,\"cost\":{\"input\":2.464e-05,\"output\":8.4e-07,\"cacheRead\":1.9712e-05,\"cacheWrite\":0,\"total\":4.5192e-05}},\"stopReason\":\"stop\",\"timestamp\":1789190455229,\"responseId\":\"14ff0275-5de5-40d1-bfc2-7d1ad8c300bd\",\"responseModel\":\"deepseek-flash\",\"rawStopReason\":\"stop\"}",
  ),
  (
    "assistant_error", "{\"role\":\"assistant\",\"content\":[],\"api\":\"openai-completions\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-pro\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"error\",\"timestamp\":1781017441893,\"errorMessage\":\"Connection error.\"}",
  ),
  (
    "toolresult_plain", "{\"role\":\"toolResult\",\"toolCallId\":\"call_00_WNC9PHuqzwWDzz29ojU43783\",\"toolName\":\"read\",\"content\":[{\"type\":\"text\",\"text\":\"\"}],\"isError\":false,\"timestamp\":1780923555005}",
  ),
  (
    "toolresult_details", "{\"role\":\"toolResult\",\"toolCallId\":\"call_00_1MRC9rNphixXB0MaVH5a8625\",\"toolName\":\"bash\",\"content\":[{\"type\":\"text\",\"text\":\"Command aborted\"}],\"details\":{},\"isError\":true,\"timestamp\":1783136468177}",
  ),
]
