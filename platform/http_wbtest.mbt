///|
/// What a reader is told when the endpoint refuses a request.
///
/// The status line alone is not a diagnosis, and this is the code that decides how much of the answer
/// reaches them — so it is worth pinning: a 400 that says "tool message must immediately follow the
/// assistant message" is a fixable session, and a 400 that says "HTTP 400" is an hour of guessing.

///|
test "the endpoint's message is unwrapped from the JSON around it" {
  assert_eq(
    clip_error_detail(
      "{\"error\":{\"message\":\"Invalid request: bad tool ordering\",\"type\":\"invalid_request_error\",\"code\":\"x\"}}",
    ),
    "Invalid request: bad tool ordering",
  )
  // A flatter envelope, and a bare object with `message` — both are seen in the wild, and neither is
  // worth a different code path than the one above.
  assert_eq(
    clip_error_detail("{\"error\":\"too many requests\"}"),
    "too many requests",
  )
  assert_eq(
    clip_error_detail("{\"message\":\"context length exceeded\"}"),
    "context length exceeded",
  )
  // An error with no message at all: the whole body is more useful than nothing.
  assert_eq(
    clip_error_detail("{\"error\":{\"code\":\"x\"}}"),
    "{\"error\":{\"code\":\"x\"}}",
  )
}

///|
test "a body that is not JSON is shown as it came" {
  // A proxy's error page, a gateway's plain text. Unwrapping is an optimisation, not a requirement:
  // the reader comparing it with the endpoint's docs is who this message is for.
  assert_eq(
    clip_error_detail("<html><body>502 Bad Gateway</body></html>"),
    "<html><body>502 Bad Gateway</body></html>",
  )
  assert_eq(clip_error_detail("upstream timed out"), "upstream timed out")
  assert_eq(clip_error_detail(""), "")
  assert_eq(clip_error_detail("   \n  "), "")
  // Including a long one: an error page is not exempt from the clip just because it is not JSON —
  // that is the shape of body the clip exists for.
  assert_true(
    clip_error_detail("<html>" + "z".repeat(error_detail_limit * 2)).length() <=
    error_detail_limit + 1,
  )
}

///|
test "a long explanation is clipped rather than becoming the message" {
  let long = "x".repeat(error_detail_limit + 500)
  let clipped = clip_error_detail(long)
  // The limit plus the ellipsis: `…` is one character, not one byte, so this counts characters the
  // way the clip does.
  assert_eq(clipped.length(), error_detail_limit + 1, msg="clipped and marked")
  assert_true(clipped.has_suffix("…"))
  // And an explanation that just fits is not marked up as if it were cut.
  let exact = "y".repeat(error_detail_limit)
  assert_eq(clip_error_detail(exact).length(), error_detail_limit)
  assert_false(clip_error_detail(exact).has_suffix("…"))
}
