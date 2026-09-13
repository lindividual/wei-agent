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
    "const stop = document.getElementById('stop');", "", "// Whether the next transcript should be shown from its end. True on load and after the reader",
    "// asks for a session: a long conversation is read from the newest end, and landing at the top",
    "// means scrolling past everything first. Streaming appends are different — they follow only",
    "// when the reader is already at the bottom, so scrolling up to read is not yanked away.",
    "let land = true;", "", "function atBottom() {", "  return window.innerHeight + window.scrollY >= document.body.offsetHeight - 160;",
    "}", "", "function toBottom() { window.scrollTo(0, document.body.scrollHeight); }",
    "", "function apply(patch) {", "  if (patch.op === 'status') { status.textContent = patch.text; return; }",
    "  const node = document.getElementById(patch.target);", "  if (!node) return;",
    "  const follow = atBottom();", "  if (patch.op === 'append') node.insertAdjacentHTML('beforeend', patch.html);",
    "  else if (patch.op === 'appendtext') node.insertAdjacentText('beforeend', patch.text);",
    "  else if (patch.op === 'replace') {", "    // Replacing the transcript is a session arriving. Landing at its end is what the reader",
    "    // came for; a reconnect replaces the same content, so there the reader keeps their place.",
    "    const keep = window.scrollY;", "    node.outerHTML = patch.html;", "    if (patch.target === 'transcript' && land) { land = false; toBottom(); }",
    "    else window.scrollTo(0, keep);", "    return;", "  }", "  if (follow) toBottom();",
    "}", "", "// Before the first frame arrives, so the page opens where the conversation ended.",
    "toBottom();", "", "// Which session this page is showing. Sessions run in parallel, so a patch produced",
    "// for another one has to be dropped: applying it would append a hidden session's",
    "// output to the visible transcript.", "let shown = document.getElementById('transcript').dataset.session;",
    "", "new EventSource('/events').addEventListener('patch', event => {", "  const frame = JSON.parse(event.data);",
    "  if (frame.session) {", "    if (frame.session === shown) apply(frame.patch);",
    "    return;", "  }", "  apply(frame);", "  if (frame.op === 'replace' && frame.target === 'transcript') {",
    "    const node = document.getElementById('transcript');", "    shown = node ? node.dataset.session : '';",
    "  }", "});", "", "// One listener for the whole sidebar: rows come and go as the regions refresh, and",
    "// listeners attached per row would not survive that.", "document.addEventListener('click', event => {",
    "  // A stop names the session it is for, so a background turn can be ended without",
    "  // bringing it on screen first.", "  const stopTask = event.target.closest('[data-stop]');",
    "  if (stopTask) {", "    fetch('/abort', { method: 'POST', body: stopTask.dataset.stop }).catch(() => {});",
    "    return;", "  }", "  // A kill names the job, so it works whichever session is on screen.",
    "  const kill = event.target.closest('[data-kill]');", "  if (kill) {", "    fetch('/job/kill', { method: 'POST', body: kill.dataset.kill }).catch(() => {});",
    "    return;", "  }", "  const open = event.target.closest('[data-session]');",
    "  if (open) {", "    // Asking for a session is asking to be shown its end.",
    "    land = true;", "    fetch('/session', { method: 'POST', body: open.dataset.session }).catch(() => {});",
    "    return;", "  }", "  const fresh = event.target.closest('[data-new]');",
    "  if (fresh) {", "    land = true;", "    fetch('/new', { method: 'POST', body: fresh.dataset.new }).catch(() => {});",
    "  }", "});", "", "// Adding a workspace posts and stays put; a form submit would navigate to the response.",
    "// Delegated rather than attached to the form: the sidebar is replaced whenever it is",
    "// refreshed, and a listener on the old node would be gone with it.", "document.addEventListener('submit', event => {",
    "  const add = event.target.closest('#add-workspace');", "  if (!add) return;",
    "  event.preventDefault();", "  const field = add.querySelector('#workspace-path');",
    "  const path = field.value.trim();", "  if (!path) return;", "  field.value = '';",
    "  // Adding one opens a session in it, so the reader lands at that session's end too.",
    "  land = true;", "  fetch('/workspace', { method: 'POST', body: path }).catch(() => {});",
    "});", "", "form.addEventListener('submit', event => {", "  event.preventDefault();",
    "  const text = input.value.trim();", "  if (!text) return;", "  input.value = '';",
    "  send.disabled = true;", "  fetch('/prompt', { method: 'POST', body: text })",
    "    .catch(() => {})", "    .finally(() => { send.disabled = false; input.focus(); });",
    "});", "", "stop.addEventListener('click', () => {", "  fetch('/abort', { method: 'POST' }).catch(() => {});",
    "});", "", "input.addEventListener('keydown', event => {", "  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) form.requestSubmit();",
    "});", "", "// The elapsed times in the tasks panel count here rather than on the server: a frame a",
    "// second to move a number the browser can work out itself would be paying for nothing.",
    "function tick() {", "  const now = Date.now();", "  for (const node of document.querySelectorAll('#tasks [data-since]')) {",
    "    const seconds = Math.max(0, Math.round((now - Number(node.dataset.since)) / 1000));",
    "    if (seconds < 60) node.textContent = seconds + 's';", "    else if (seconds < 3600) node.textContent = Math.floor(seconds / 60) + 'm ' + (seconds % 60) + 's';",
    "    else node.textContent = Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm';",
    "  }", "}", "setInterval(tick, 1000);",
  ].join("\n")
}
