///|
/// How context messages that are not conversation reach a provider.
///
/// Each entry is (name, input JSON, expected message JSON). The input is the
/// context message as the session log records it; the expected value is what a
/// provider actually receives.
pub let llm_message_fixtures : Array[(String, String, String)] = [
  (
    "compaction_summary", "{\"role\":\"compactionSummary\",\"summary\":\"## Goal\\nship it\",\"tokensBefore\":4096,\"timestamp\":1700000000000}",
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"The conversation history before this point was compacted into the following summary:\\n\\n<summary>\\n## Goal\\nship it\\n</summary>\"}],\"timestamp\":1700000000000}",
  ),
  (
    "branch_summary", "{\"role\":\"branchSummary\",\"summary\":\"earlier attempt\",\"fromId\":\"abc\",\"timestamp\":1700000000000}",
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"The following is a summary of a branch that this conversation came back from:\\n\\n<summary>\\nearlier attempt</summary>\"}],\"timestamp\":1700000000000}",
  ),
  (
    "custom_parts", "{\"role\":\"custom\",\"customType\":\"hook\",\"content\":[{\"type\":\"text\",\"text\":\"injected\"}],\"display\":false,\"timestamp\":1700000000000}",
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"injected\"}],\"timestamp\":1700000000000}",
  ),
  (
    "custom_string", "{\"role\":\"custom\",\"customType\":\"hook\",\"content\":\"plain string\",\"display\":false,\"timestamp\":1700000000000}",
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"plain string\"}],\"timestamp\":1700000000000}",
  ),
]
