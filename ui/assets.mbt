///|
/// The stylesheet and the client script, inlined.
///
/// Serving them from the binary rather than from a directory is the point of the
/// whole design: one file to build, one file to run, and no way for the assets to
/// be out of sync with the server that references them.

///|
/// Styling is deliberately plain. Reasoning and tool blocks use the native
/// `<details>` marker, so there is no collapse state to draw or remember.
pub fn stylesheet() -> String {
  "  :root { color-scheme: light dark; }\n  body { font: 15px/1.55 ui-sans-serif, system-ui, sans-serif; margin: 0; }\n  #transcript { max-width: 62rem; margin: 0 auto; padding: 1.5rem 1rem 8rem; }\n  .exchange { margin-bottom: 1.75rem; }\n  .user { background: rgba(127,127,127,.12); border-radius: .55rem; padding: .7rem .95rem; margin-bottom: .6rem; white-space: pre-wrap; }\n  .blocks > * { margin-bottom: .6rem; }\n  .text { white-space: normal; }\n  details { border-left: 2px solid rgba(127,127,127,.35); padding-left: .8rem; }\n  summary { cursor: pointer; opacity: .75; font-size: .9em; }\n  details[open] summary { margin-bottom: .4rem; }\n  pre { white-space: pre-wrap; word-break: break-word; background: rgba(127,127,127,.1); border-radius: .4rem; padding: .6rem .75rem; margin: .4rem 0; overflow-x: auto; }\n  .result.error pre { border-left: 3px solid #d33; }\n  .pending { opacity: .6; font-size: .9em; }\n  .status { position: fixed; bottom: 5.5rem; left: 0; right: 0; text-align: center; font-size: .85em; opacity: .7; pointer-events: none; }\n  form { position: fixed; bottom: 0; left: 0; right: 0; display: flex; gap: .5rem; padding: .9rem 1rem; background: Canvas; border-top: 1px solid rgba(127,127,127,.3); }\n  textarea { flex: 1; resize: none; font: inherit; padding: .55rem .7rem; border-radius: .45rem; border: 1px solid rgba(127,127,127,.45); background: transparent; color: inherit; }\n  button { font: inherit; padding: .55rem 1.1rem; border-radius: .45rem; border: 1px solid rgba(127,127,127,.45); background: transparent; color: inherit; cursor: pointer; }\n  button:disabled { opacity: .45; cursor: default; }\n"
}

///|
/// The client.
///
/// Forty lines, and that is the whole of it. It knows two things: how to apply a
/// patch, and how to post a prompt. Everything about what the conversation looks
/// like was decided on the server.
///
/// `EventSource` reconnects on its own, and the server sends the current document
/// as the first frame of every connection, so a reconnect recovers without any
/// client-side bookkeeping.
pub fn client_script() -> String {
  "const transcript = document.getElementById('transcript');\nconst status = document.getElementById('status');\nconst form = document.getElementById('composer');\nconst input = document.getElementById('prompt');\nconst send = document.getElementById('send');\nconst stop = document.getElementById('stop');\n\nfunction apply(patch) {\n  if (patch.op === 'status') { status.textContent = patch.text; return; }\n  const node = document.getElementById(patch.target);\n  if (!node) return;\n  if (patch.op === 'append') node.insertAdjacentHTML('beforeend', patch.html);\n  else if (patch.op === 'replace') node.outerHTML = patch.html;\n  else if (patch.op === 'text') node.textContent = patch.text;\n  if (patch.op === 'append' || patch.op === 'replace') {\n    const near = window.innerHeight + window.scrollY >= document.body.offsetHeight - 160;\n    if (near) window.scrollTo(0, document.body.scrollHeight);\n  }\n}\n\nnew EventSource('/events').addEventListener('patch', event => apply(JSON.parse(event.data)));\n\nform.addEventListener('submit', event => {\n  event.preventDefault();\n  const text = input.value.trim();\n  if (!text) return;\n  input.value = '';\n  send.disabled = true;\n  fetch('/prompt', { method: 'POST', body: text })\n    .catch(() => {})\n    .finally(() => { send.disabled = false; input.focus(); });\n});\n\nstop.addEventListener('click', () => {\n  fetch('/abort', { method: 'POST' }).catch(() => {});\n});\n\ninput.addEventListener('keydown', event => {\n  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) form.requestSubmit();\n});\n"
}

///|
/// The composer, which lives outside the transcript so that replacing the
/// transcript never touches what the reader is typing.
pub fn composer() -> @html.Node {
  @html.el("form", attrs=[@html.attr("id", "composer")], children=[
    @html.el("textarea", attrs=[
      @html.attr("id", "prompt"),
      @html.attr("rows", "2"),
      @html.attr("placeholder", "Ask something… (Cmd+Enter to send)"),
      @html.attr("autofocus", ""),
    ]),
    @html.el(
      "button",
      attrs=[@html.attr("id", "send"), @html.attr("type", "submit")],
      children=[@html.txt("Send")],
    ),
  ])
}
