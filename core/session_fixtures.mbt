///|
/// Real session lines lifted verbatim from `~/.upstream/agent/sessions/`.
///
/// Generated, not hand written: each string is one real line, picked as the
/// shortest example of its kind. Regenerate rather than edit.
pub let session_header_fixture : String = "{\"type\":\"session\",\"version\":3,\"id\":\"019ebfdf-06f7-7df2-b5f1-2f447c1149fe\",\"timestamp\":\"2026-06-13T07:25:25.111Z\",\"cwd\":\"/Users/lucas\"}"

///|
pub let entry_fixtures : Array[(String, String)] = [
  (
    "message", "{\"type\":\"message\",\"id\":\"03ff8f7f\",\"parentId\":\"7415f52a\",\"timestamp\":\"2026-06-09T15:16:48.548Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"2\"}],\"timestamp\":1781018208546}}",
  ),
  (
    "model_change", "{\"type\":\"model_change\",\"id\":\"7c382719\",\"parentId\":null,\"timestamp\":\"2026-06-07T13:27:18.659Z\",\"provider\":\"deepseek\",\"modelId\":\"deepseek-v4-pro\"}",
  ),
  (
    "thinking_level_change", "{\"type\":\"thinking_level_change\",\"id\":\"7e9d2cc1\",\"parentId\":null,\"timestamp\":\"2026-06-06T08:21:24.473Z\",\"thinkingLevel\":\"off\"}",
  ),
  (
    "custom", "{\"type\":\"custom\",\"customType\":\"web-search-results\",\"data\":{\"id\":\"mtxybon7iarfol\",\"type\":\"fetch\",\"timestamp\":1789191333763,\"urlMetadata\":[{\"url\":\"https://moonbit-community.github.io/rabbita/components/\",\"title\":\"https://moonbit-community.github.io/rabbita/components/\",\"error\":null,\"contentLength\":467,\"mimeType\":\"text/html\",\"status\":200}],\"fetchCache\":{\"version\":1,\"key\":\"mtxybon7iarfol.json\",\"storedAt\":1789191333770}},\"id\":\"33e32058\",\"parentId\":\"1a9c0213\",\"timestamp\":\"2026-09-12T05:35:33.770Z\"}",
  ),
]
