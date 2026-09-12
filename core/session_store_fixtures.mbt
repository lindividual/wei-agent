///|
/// Real session-store facts: directory names paired with the working
/// directory that produced them, and one small complete session file.
///
/// Generated from `~/.pi/agent/sessions/`. The pairs matter because the
/// encoding is lossy (`/` and `:` both become `-`), so a round trip cannot be
/// inferred — it has to be checked against what pi actually wrote.
pub let session_dir_fixtures : Array[(String, String)] = [
  ("/Users/lucas", "--Users-lucas--"),
  ("/Users/lucas/Documents", "--Users-lucas-Documents--"),
  ("/Users/lucas/Documents/GitHub", "--Users-lucas-Documents-GitHub--"),
  (
    "/Users/lucas/Documents/GitHub/DevCloudflare", "--Users-lucas-Documents-GitHub-DevCloudflare--",
  ),
  (
    "/Users/lucas/Documents/GitHub/DevCloudflare/src/webappv2", "--Users-lucas-Documents-GitHub-DevCloudflare-src-webappv2--",
  ),
  (
    "/Users/lucas/Documents/GitHub/Madolumo", "--Users-lucas-Documents-GitHub-Madolumo--",
  ),
  (
    "/Users/lucas/Documents/GitHub/dechat_v_0.1", "--Users-lucas-Documents-GitHub-dechat_v_0.1--",
  ),
  (
    "/Users/lucas/Documents/GitHub/dechat_v_0.1/webapp", "--Users-lucas-Documents-GitHub-dechat_v_0.1-webapp--",
  ),
]

///|
pub let small_session_file : String = "{\"type\":\"session\",\"version\":3,\"id\":\"01a02d4c-602a-792e-bb37-223885b163d7\",\"timestamp\":\"2026-08-23T06:26:15.210Z\",\"cwd\":\"/Users/lucas/Documents/GitHub/dechat_v_0.1\"}\n{\"type\":\"model_change\",\"id\":\"1f41c707\",\"parentId\":null,\"timestamp\":\"2026-08-23T06:26:15.245Z\",\"provider\":\"deepseek\",\"modelId\":\"deepseek-v4-flash\"}\n{\"type\":\"thinking_level_change\",\"id\":\"8b2187d4\",\"parentId\":\"1f41c707\",\"timestamp\":\"2026-08-23T06:26:15.245Z\",\"thinkingLevel\":\"high\"}\n{\"type\":\"message\",\"id\":\"6bd2a42d\",\"parentId\":\"8b2187d4\",\"timestamp\":\"2026-08-23T06:26:18.662Z\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"pi\"}],\"timestamp\":1787466378656}}\n{\"type\":\"message\",\"id\":\"038ecec4\",\"parentId\":\"6bd2a42d\",\"timestamp\":\"2026-08-23T06:26:21.713Z\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"用户只输入了\\\"pi\\\"。这可能是在询问关于 pi 本身的信息。根据指南，我应该用中文回复。让我先了解一下用户想做什么——\\\"pi\\\"可能是指 pi 编码代理本身，或者可能是误输入。\\n\\n我应该询问用户想要做什么，或者查看 pi 的文档来提供帮助。既然用户只是输入了\\\"pi\\\"，我可以用中文询问他们的需求。\",\"thinkingSignature\":\"reasoning_content\"},{\"type\":\"text\",\"text\":\"你好！你输入了 \\\"pi\\\"——请问你想了解什么？\\n\\n如果你是想问 **pi 编码代理本身**，我可以帮你：\\n- 查看 pi 的文档（README、docs 目录）\\n- 了解扩展、主题、技能、快捷键、SDK 集成等\\n- 查看示例代码\\n\\n如果你想做的是**别的事情**（比如查看当前项目 `dechat_v_0.1`），也请告诉我具体需求。\\n\\n需要我做什么？\"}],\"api\":\"openai-completions\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-flash\",\"usage\":{\"input\":5231,\"output\":176,\"cacheRead\":768,\"cacheWrite\":0,\"reasoning\":78,\"totalTokens\":6175,\"cost\":{\"input\":0.00073234,\"output\":0.00004928,\"cacheRead\":0.0000021503999999999998,\"cacheWrite\":0,\"total\":0.0007837704000000001}},\"stopReason\":\"stop\",\"timestamp\":1787466378733,\"responseId\":\"39a436d6-10d4-46ca-927f-89c9a4d1de71\",\"rawStopReason\":\"stop\"}}\n"
