///|
/// The core invariant: a real session line must survive
/// decode → memory → encode unchanged.
///
/// Json's `Eq` compares numbers by value and objects by content, so this
/// tolerates a float being re-serialized in a different-but-equivalent
/// notation while still catching any structural mistake: a dropped optional
/// field, a renamed key, a number that lost precision.
test "real session lines round trip" {
  for entry in fixtures {
    let (name, line) = entry
    let original = @json.parse(line)
    let message = Message::from_json(original)
    let reencoded = message.to_json()
    if reencoded != original {
      fail(
        "round trip changed \{name}\noriginal: \{original.stringify()}\nreencoded: \{reencoded.stringify()}",
      )
    }
  }
}

///|
/// Decoding then encoding then decoding again must be a fixed point, so a
/// session this build writes is readable by this build.
test "encode decode is a fixed point" {
  for entry in fixtures {
    let (name, line) = entry
    let once = Message::from_json(@json.parse(line)).to_json()
    let twice = Message::from_json(once).to_json()
    if once != twice {
      fail("not a fixed point: \{name}")
    }
  }
}

///|
test "text content" {
  let j = @json.parse(
    "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"timestamp\":1}",
  )
  let m = Message::from_json(j)
  assert_true(m is User({ content: [Text("hi")], timestamp: 1L, }))
}

///|
/// `thinkingSignature` must survive verbatim: DeepSeek rejects a replayed
/// assistant message whose `reasoning_content` is missing or renamed.
test "thinking signature is preserved" {
  let j = @json.parse(
    "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"hmm\",\"thinkingSignature\":\"reasoning_content\"}],\"api\":\"openai-completions\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-flash\",\"usage\":{\"input\":1,\"output\":2,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":3,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"stop\",\"timestamp\":2}",
  )
  let message = Message::from_json(j)
  assert_true(
    message
    is Assistant(
      { content: [Thinking(thinking="hmm", signature="reasoning_content")], .. }
    ),
  )
  assert_eq(message.to_json(), j)
}

///|
/// Optional fields must stay absent when the source omitted them, rather than
/// being materialised as null.
test "absent optional fields stay absent" {
  let j = @json.parse(
    "{\"role\":\"assistant\",\"content\":[],\"api\":\"a\",\"provider\":\"p\",\"model\":\"m\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"aborted\",\"timestamp\":3}",
  )
  let reencoded = Message::from_json(j).to_json()
  assert_eq(reencoded, j)
  assert_false(reencoded.stringify().contains("responseId"))
  assert_false(reencoded.stringify().contains("\"reasoning\""))
}

///|
/// Reasons outside the known set are kept, not rejected: a newer provider
/// must not make an older reader fail.
test "unknown stop reason is preserved" {
  let j = @json.parse(
    "{\"role\":\"assistant\",\"content\":[],\"api\":\"a\",\"provider\":\"p\",\"model\":\"m\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"content_filter\",\"timestamp\":4}",
  )
  let message = Message::from_json(j)
  assert_true(
    message is Assistant({ stop_reason: Unknown("content_filter"), .. }),
  )
  assert_eq(message.to_json(), j)
}

///|
/// Tool arguments are opaque JSON, so a shape this build has never seen must
/// still round trip exactly.
test "tool arguments are opaque" {
  let j = @json.parse(
    "{\"role\":\"assistant\",\"content\":[{\"type\":\"toolCall\",\"id\":\"c1\",\"name\":\"bash\",\"arguments\":{\"command\":\"ls\",\"nested\":{\"deep\":[1,2,3]}}}],\"api\":\"a\",\"provider\":\"p\",\"model\":\"m\",\"usage\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0,\"total\":0}},\"stopReason\":\"toolUse\",\"timestamp\":5}",
  )
  assert_eq(Message::from_json(j).to_json(), j)
}

///|
/// A malformed message must be refused rather than silently degraded; losing
/// an assistant turn would corrupt the context sent to the model.
test "malformed input raises" {
  let cases : Array[String] = [
    "{\"role\":\"nope\",\"content\":[]}", "{\"role\":\"user\",\"content\":[{\"type\":\"text\"}]}",
    "{\"role\":\"user\",\"content\":[{\"type\":\"alien\"}],\"timestamp\":1}", "{\"role\":\"user\"}",
    "{\"role\":\"toolResult\",\"toolCallId\":\"c\",\"toolName\":\"t\",\"content\":[],\"timestamp\":1}",
  ]
  for src in cases {
    try Message::from_json(@json.parse(src)) catch {
      _ => ()
    } noraise {
      _ => fail("expected failure for \{src}")
    }
  }
}
