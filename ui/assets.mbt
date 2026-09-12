///|
/// The client script, inlined into the page.
///
/// Behaviour only: how to apply a patch, how to post a prompt, that a click on something
/// carrying `data-session` means "open that", and that a patch tagged with another session
/// is not for this one. The look lives in `html/theme.mbt`, next to the markup it styles.

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
