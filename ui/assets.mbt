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
  "  :root { color-scheme: light dark; }\n  * { box-sizing: border-box; }\n  body { font: 15px/1.55 ui-sans-serif, system-ui, sans-serif; margin: 0; }\n  .layout { display: flex; align-items: flex-start; gap: 1.5rem; max-width: 78rem; margin: 0 auto; }\n  .sidebar { flex: 0 0 16rem; position: sticky; top: 0; max-height: 100vh; overflow-y: auto; padding: 1.25rem .5rem 8rem 1rem; font-size: .9em; }\n  .sidebar details.workspace { margin-bottom: .6rem; }\n  .sidebar summary { overflow: hidden; white-space: nowrap; }\n  .sidebar summary .name { display: inline-block; vertical-align: bottom; max-width: 11rem; overflow: hidden; text-overflow: ellipsis; }\n  .sidebar details.workspace > summary { font-weight: 600; opacity: .8; padding: .1rem .2rem; }\n  .sidebar details.workspace.active > summary { opacity: 1; }\n  .sidebar details.workspace .new { opacity: .75; font-size: .95em; }\n  .sidebar button { display: block; width: 100%; text-align: left; font: inherit; padding: .4rem .55rem; border: 1px solid transparent; border-radius: .4rem; background: transparent; color: inherit; cursor: pointer; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }\n  .sidebar button:hover { background: rgba(127,127,127,.14); }\n  .sidebar ul { list-style: none; margin: 0; padding: 0; }\n  .sidebar li.current button { border-color: rgba(127,127,127,.5); font-weight: 600; }\n  .sidebar li { position: relative; }\n  .sidebar .dot { position: absolute; right: .55rem; top: .5rem; width: .45rem; height: .45rem; border-radius: 50%; background: currentColor; opacity: .75; animation: pulse 1.2s ease-in-out infinite; }\n  @keyframes pulse { 50% { opacity: .25; } }\n  .sidebar .meta { opacity: .6; font-size: .85em; padding: 0 .55rem .5rem; }\n  .sidebar .empty { opacity: .6; padding: 0 .55rem; }\n  #transcript { flex: 1 1 auto; min-width: 0; padding: 1.5rem 0 8rem; }\n  .exchange { margin-bottom: 1.75rem; }\n  .user { background: rgba(127,127,127,.12); border-radius: .55rem; padding: .7rem .95rem; margin-bottom: .6rem; white-space: pre-wrap; }\n  /* Markdown wraps every paragraph, and its default margins would pad the bubble out to twice the height of its text. */\n  .user > :first-child, .text > :first-child { margin-top: 0; }\n  .user > :last-child, .text > :last-child { margin-bottom: 0; }\n  .blocks > * { margin-bottom: .6rem; }\n  .text { white-space: normal; }\n  details { border-left: 2px solid rgba(127,127,127,.35); padding-left: .8rem; }\n  details.compaction { border-left-style: dashed; }\n  summary { cursor: pointer; opacity: .75; font-size: .9em; }\n  details[open] summary { margin-bottom: .4rem; }\n  pre { white-space: pre-wrap; word-break: break-word; background: rgba(127,127,127,.1); border-radius: .4rem; padding: .6rem .75rem; margin: .4rem 0; overflow-x: auto; }\n  .result.error pre { border-left: 3px solid #d33; }\n  .pending { opacity: .6; font-size: .9em; }\n  .status { position: fixed; bottom: 5.5rem; left: 0; right: 0; text-align: center; font-size: .85em; opacity: .7; pointer-events: none; }\n  form { position: fixed; bottom: 0; left: 0; right: 0; display: flex; gap: .5rem; padding: .9rem 1rem; background: Canvas; border-top: 1px solid rgba(127,127,127,.3); }\n  textarea { flex: 1; resize: none; font: inherit; padding: .55rem .7rem; border-radius: .45rem; border: 1px solid rgba(127,127,127,.45); background: transparent; color: inherit; }\n  button { font: inherit; padding: .55rem 1.1rem; border-radius: .45rem; border: 1px solid rgba(127,127,127,.45); background: transparent; color: inherit; cursor: pointer; }\n  button:disabled { opacity: .45; cursor: default; }\n  .sidebar button { padding: .4rem .55rem; border-radius: .4rem; }\n"
}

///|
/// The client.
///
/// Sixty lines, and that is the whole of it. It knows four things: how to apply a patch,
/// how to post a prompt, that a click on something carrying `data-session` means "open
/// that", and that a patch tagged with another session is not for it.
///
/// Written as lines joined rather than one long literal: the escaping is the only thing
/// that can go wrong here, and it is easier to see when each line stands alone. The script
/// is inlined into the page rather than served as a file, so a build cannot leave it out of
/// sync with the server that references it.
pub fn client_script() -> String {
  [
    "const status = document.getElementById('status');", "const form = document.getElementById('composer');",
    "const input = document.getElementById('prompt');", "const send = document.getElementById('send');",
    "const stop = document.getElementById('stop');", "", "function apply(patch) {",
    "  if (patch.op === 'status') { status.textContent = patch.text; return; }",
    "  const node = document.getElementById(patch.target);", "  if (!node) return;",
    "  if (patch.op === 'append') node.insertAdjacentHTML('beforeend', patch.html);",
    "  else if (patch.op === 'replace') node.outerHTML = patch.html;", "  else if (patch.op === 'text') node.textContent = patch.text;",
    "  if (patch.op === 'append' || patch.op === 'replace') {", "    const near = window.innerHeight + window.scrollY >= document.body.offsetHeight - 160;",
    "    if (near) window.scrollTo(0, document.body.scrollHeight);", "  }", "}",
    "", "// Which session this page is showing. Sessions run in parallel, so a patch produced",
    "// for another one has to be dropped: applying it would append a hidden session's",
    "// output to the visible transcript.", "let shown = document.getElementById('transcript').dataset.session;",
    "", "new EventSource('/events').addEventListener('patch', event => {", "  const frame = JSON.parse(event.data);",
    "  if (frame.session) {", "    if (frame.session === shown) apply(frame.patch);",
    "    return;", "  }", "  apply(frame);", "  if (frame.op === 'replace' && frame.target === 'transcript') {",
    "    const node = document.getElementById('transcript');", "    shown = node ? node.dataset.session : '';",
    "  }", "});", "", "// One listener for the whole sidebar: rows come and go as the regions refresh, and",
    "// listeners attached per row would not survive that.", "document.addEventListener('click', event => {",
    "  const open = event.target.closest('[data-session]');", "  if (open) {", "    fetch('/session', { method: 'POST', body: open.dataset.session }).catch(() => {});",
    "    return;", "  }", "  const fresh = event.target.closest('[data-new]');",
    "  if (fresh) fetch('/new', { method: 'POST', body: fresh.dataset.new }).catch(() => {});",
    "});", "", "form.addEventListener('submit', event => {", "  event.preventDefault();",
    "  const text = input.value.trim();", "  if (!text) return;", "  input.value = '';",
    "  send.disabled = true;", "  fetch('/prompt', { method: 'POST', body: text })",
    "    .catch(() => {})", "    .finally(() => { send.disabled = false; input.focus(); });",
    "});", "", "stop.addEventListener('click', () => {", "  fetch('/abort', { method: 'POST' }).catch(() => {});",
    "});", "", "input.addEventListener('keydown', event => {", "  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) form.requestSubmit();",
    "});",
  ].join("\n")
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
    @html.el(
      "button",
      attrs=[@html.attr("id", "stop"), @html.attr("type", "button")],
      children=[@html.txt("Stop")],
    ),
  ])
}
