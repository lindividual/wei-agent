///|
/// An image on its way to the model.
///
/// Two files have to agree for a picture to reach the model: the read tool has to return it as an
/// image block (`platform/tools_test.mbt` covers that), and the request builder has to put it on
/// the wire as one. This is the second half, and it is the half that was quietly broken: `vision`
/// was written as `false` at every call site, so a gem that the reader could see was replaced by a
/// placeholder no matter which model was being called.
///
/// Both directions are asserted here, because the degradation is not a fallback for a missing
/// feature — it is the correct behaviour on a text-only model, and it has to keep working.

///|
/// A tool result carrying an image, which is what `read` produces for a picture.
///
/// The shape matters: the read tool returns its image inside a *tool result*, not a user message,
/// and that is the path this test exists to cover. A user message with an image was always handled;
/// the tool result was stringified, so the picture was turned into a note about itself.
fn tool_result_request(vision : Bool) -> Json {
  let result : ToolResultMessage = {
    tool_call_id: "call_1",
    tool_name: "read",
    content: [
      Text("Read image file [image/png] shot.png (80 bytes)"),
      Image(data="aGVsbG8=", mime_type="image/png"),
    ],
    is_error: false,
    timestamp: 0L,
    details: None,
  }
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [ToolResult(result)],
    system_prompt: None,
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision,
  }
  build_deepseek_request(spec)
}

///|
/// A user message with an image, for the other half of the picture.
fn user_image_request(vision : Bool) -> Json {
  let message : Message = User({
    content: [
      Text("what is this"),
      Image(data="aGVsbG8=", mime_type="image/png"),
    ],
    timestamp: 0L,
  })
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [message],
    system_prompt: None,
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision,
  }
  build_deepseek_request(spec)
}

///|
/// A model that can see gets the bytes, as a data URL — the shape every OpenAI-compatible provider
/// including DeepSeek accepts.
test "an image in a user message is sent to a model that can see it" {
  let body = user_image_request(true).stringify()
  assert_true(body.contains("image_url"), msg=body)
  assert_true(body.contains("data:image/png;base64,aGVsbG8="), msg=body)
  assert_true(body.contains("what is this"), msg=body)
}

///|
/// A tool result with an image is sent as content parts, so the model is shown the picture.
///
/// This is the chain the read tool depends on. Sending a string here was the quiet failure: the
/// turn still ran, the note still appeared, and the model answered about a screenshot it had never
/// seen.
test "an image in a tool result reaches a model that can see it" {
  let body = tool_result_request(true).stringify()
  assert_true(body.contains("image_url"), msg=body)
  assert_true(body.contains("data:image/png;base64,aGVsbG8="), msg=body)
  assert_true(body.contains("shot.png"), msg=body)
  assert_true(body.contains("tool_call_id"), msg=body)
}

///|
/// With no image, a tool result stays a plain string — what upstream sends, and what the recorded request
/// fixtures pin. The array form is for pictures, not for every tool call.
test "a tool result with no image is still a plain string" {
  let result : ToolResultMessage = {
    tool_call_id: "call_2",
    tool_name: "bash",
    content: [Text("total 0\n")],
    is_error: false,
    timestamp: 0L,
    details: None,
  }
  let spec : RequestSpec = {
    model: "deepseek-v4-flash",
    messages: [ToolResult(result)],
    system_prompt: None,
    tools: [],
    thinking: Disabled,
    max_tokens: None,
    temperature: None,
    vision: true,
  }
  let body = build_deepseek_request(spec).stringify()
  assert_false(body.contains("image_url"), msg=body)
  // A string, not an array: the fixture comparison would fail otherwise.
  assert_true(body.contains("\"content\":\"total 0"), msg=body)
}

///|
/// A model that cannot see gets a placeholder that says so, and the turn still runs.
///
/// This is the behaviour the README calls out as matching upstream, and it is what keeps a pasted
/// screenshot from ending the turn on a text-only model. It must not regress as the vision path is
/// wired up — the two are different models, not an old and a new implementation.
test "an image is degraded to a placeholder on a model that cannot see" {
  let user = user_image_request(false).stringify()
  assert_false(user.contains("image_url"), msg=user)
  assert_true(
    user.contains("image omitted: model does not support images"),
    msg=user,
  )
  let tool = tool_result_request(false).stringify()
  assert_false(tool.contains("image_url"), msg=tool)
  assert_true(
    tool.contains("tool image omitted: model does not support images"),
    msg=tool,
  )
}

///|
/// Whether a model can see is a fact about the model, and it is read from the catalog.
///
/// The bug this replaces was a literal `false` at the call site, so the check that matters is that
/// the answer comes from the model's own entry rather than from a default.
test "whether a model sees images comes from the catalog" {
  // The default model's catalog entry lists text and image input.
  assert_true(model_sees_images(default_model_id()))
  assert_true(model_sees_images("deepseek-flash"))
  // Pro is text-only in the same catalog, so the same conversation degrades on it.
  assert_false(model_sees_images("deepseek-v4-pro"))
  // A model this build does not know falls back to the default's answer, because that is the model
  // the request will actually be sent to.
  assert_eq(model_sees_images("deepseek-v9-someday"), default_model().vision)
}
