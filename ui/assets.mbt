///|
/// The client script, inlined into the page.
///
/// Behaviour only: how to apply a patch, how to post a prompt, that a click on something
/// carrying `data-session` means "open that", that a patch tagged with another session
/// is not for this one, and that the settings forms post themselves rather than navigating.
/// The look lives in `html/theme.mbt`, next to the markup it styles.

///|
/// The client.
///
/// Under a hundred lines, and that is the whole of it. It knows five things: how to apply a
/// patch, how to post a prompt, that a click on something carrying `data-session` means "open
/// that", that a patch tagged with another session is not for it, and that the settings
/// forms are posted rather than navigated to.
///
/// Written as lines joined rather than one long literal: the escaping is the only thing
/// that can go wrong here, and it is easier to see when each line stands alone. The script
/// is inlined into the page rather than served as a file, so a build cannot leave it out of
/// sync with the server that references it.
pub fn client_script() -> String {
  [
    "const status = document.getElementById('status');", "const form = document.getElementById('composer');",
    "const input = document.getElementById('prompt');", "const send = document.getElementById('send');",
    "", "// Whether the next transcript should be shown from its end. True on load and after the reader",
    "// asks for a session: a long conversation is read from the newest end, and landing at the top",
    "// means scrolling past everything first. Streaming appends are different — they follow only",
    "// when the reader is already at the bottom, so scrolling up to read is not yanked away.",
    "let land = true;",
    // Set when the reader asks for more of the conversation, so the transcript replacement that
    // answers it can correct the scroll offset instead of just keeping it. See `apply`.
     "let grow = false;", "", "function atBottom() {", "  return window.innerHeight + window.scrollY >= document.body.offsetHeight - 160;",
    "}", "", "function toBottom() { window.scrollTo(0, document.body.scrollHeight); }",
    // Code blocks are the one thing a reader routinely wants to take away with them, and they
    // arrive as opaque HTML from the markdown renderer — there is no node the server could have
    // put a button in. So the button is added here. Each block is marked once so a later refresh
    // does not stack a second button on top of the first.
    //
    // The language comes from the `language-…` class cmark puts on the `<code>`, which nothing
    // else on the page was reading.
    // One measurement per distinct language, shared across every call — the note inside
    // `decorateCode` is why the width is cached by language rather than taken per block.
     "const controlWidths = new Map();", "", "function decorateCode() {", "  const scope = document.getElementById('transcript');",
    "  if (!scope) return;", "  for (const pre of scope.querySelectorAll('pre:not([data-copyable])')) {",
    "    pre.setAttribute('data-copyable', '1');", "    const code = pre.querySelector('code');",
    "    const lang = code && code.className.indexOf('language-') === 0 ? code.className.slice(9) : '';",
    "    const tools = document.createElement('div');", "    tools.className = 'code-tools';",
    "    if (lang) {", "      const tag = document.createElement('span');", "      tag.className = 'code-lang';",
    "      tag.textContent = lang;", "      tools.appendChild(tag);", "    }", "    const button = document.createElement('button');",
    "    button.type = 'button';", "    button.className = 'copy';", "    button.textContent = 'Copy';",
    "    const settle = label => {", "      button.textContent = label;", "      setTimeout(() => { button.textContent = 'Copy'; }, 1400);",
    "    };",
    // The clipboard can legitimately refuse — an insecure context, a denied permission. Saying so
    // is not enough on its own, so the fallback selects the code: the reader's next keystroke then
    // does what the button could not, instead of leaving them to drag across a wide block.
     "    const fallback = () => {", "      const range = document.createRange();",
    "      range.selectNodeContents(code || pre);", "      const selection = window.getSelection();",
    "      selection.removeAllRanges();", "      selection.addRange(range);", "      settle(navigator.platform.indexOf('Mac') === 0 ? 'Press ⌘C' : 'Press Ctrl+C');",
    "    };", "    button.addEventListener('click', () => {", "      const write = navigator.clipboard && navigator.clipboard.writeText",
    "        ? navigator.clipboard.writeText(code ? code.textContent : pre.textContent)",
    "        : Promise.reject(new Error('no clipboard'));", "      write.then(() => settle('Copied'), fallback);",
    "    });", "    tools.appendChild(button);",
    // Wrapped rather than appended to the <pre>: a button inside a preformatted element becomes
    // part of what a drag-select picks up, and the block beside it scrolls sideways.
     "    const wrap = document.createElement('div');", "    wrap.className = 'code-block';",
    "    pre.parentNode.insertBefore(wrap, pre);", "    wrap.appendChild(pre);",
    "    wrap.appendChild(tools);",
    // The block reserves exactly the room its controls take, measured rather than guessed: the
    // badge is as wide as the language's name, and a reserve a few pixels short leaves the end of a
    // scrolled line underneath the Copy button, where no amount of scrolling recovers it. The
    // stylesheet's own value is what shows in the moment before this runs.
    //
    // Measured once per *language*, not once per block. Reading `offsetWidth` after changing the DOM
    // forces a synchronous layout, and doing that for every block turned decorating a long
    // transcript into seconds of layout thrashing — 1,919 blocks cost 3.4 seconds, which was more
    // than parsing and inserting the whole transcript put together. The width only depends on the
    // badge text and the button, so one measurement per distinct language is both correct and
    // roughly two orders of magnitude cheaper.
     "    let reserved = controlWidths.get(lang);", "    if (reserved === undefined) {",
    "      reserved = tools.offsetWidth + 12;", "      controlWidths.set(lang, reserved);",
    "    }", "    wrap.style.setProperty('--code-controls', reserved + 'px');", "  }",
    "}", "",
    // The command list is shown only while the composer holds something trying to be a command: a
    // slash with no space after it yet. A slash anywhere else is a path or a division, and the page
    // should not open a menu over someone typing `/usr/local/bin` into the middle of a sentence.
     "const commands = document.getElementById('commands');", "const COMMAND_RE = /^\\/[^ ]*$/;",
    "function hideCommands() { if (commands) commands.hidden = true; }", "function syncCommands() {",
    "  if (!commands) return;",
    // Filtered by prefix, not merely opened by one. A reader who has typed `/us` is asking about a
    // particular command, and answering with the whole list — none of it matching — is worse than
    // answering with nothing.
     "  const typed = input.value;", "  if (!COMMAND_RE.test(typed)) { hideCommands(); return; }",
    "  const wanted = typed.toLowerCase();", "  let shown = 0;", "  for (const row of commands.querySelectorAll('.command')) {",
    "    const matches = row.dataset.fill.toLowerCase().indexOf(wanted) === 0;",
    "    row.hidden = !matches;", "    if (matches) shown += 1;", "  }", "  commands.hidden = shown === 0;",
    "}", "",
    // Renaming in place. The row is what is being named, so the box appears where the name was
    // rather than in a dialog the reader has to find their way back from.
     "function beginRename(button) {",
    // The name is the label inside the row's button — not the button, which also holds the
    // running marker and the age, and not the row, which holds the actions as well.
     "  const row = button.closest('li');", "  const label = row && row.querySelector('.label');",
    "  if (!label) return;", "  const original = label.textContent.trim();", "  const box = document.createElement('input');",
    "  box.type = 'text';", "  box.value = original;", "  box.className = 'rename-form';",
    "  box.setAttribute('aria-label', 'session name');", "  label.parentNode.replaceChild(box, label);",
    "  button.hidden = true;", "  box.focus(); box.select();", "  let settled = false;",
    "  const restore = () => { box.parentNode.replaceChild(label, box); button.hidden = false; };",
    "  const finish = send => {", "    if (settled) return;", "    settled = true;",
    "    const name = box.value.trim();",
    // Nothing typed, or nothing changed: put the row back rather than writing a no-op entry into
    // the log. A rename that says the same thing is still a line the next reader has to skip.
     "    if (!send || name === '' || name === original) { restore(); return; }",
    // Encoded, because the body is form-decoded on the way in and a `+` in a name is a plus.
    // Sent as it was typed, like the composer sends a prompt: the route hands the body straight to
    // the same rename the `/name` command reaches, so the two ways in decode identically — which is
    // to say, not at all. Encoding on this path alone would make a name with a `+` in it arrive as
    // a space here and literally from the composer.
     "    fetch('/name', { method: 'POST', body: name }).catch(() => {});", "  };",
    "  box.addEventListener('keydown', event => {", "    if (event.key === 'Enter') { event.preventDefault(); finish(true); }",
    "    else if (event.key === 'Escape') { event.preventDefault(); finish(false); }",
    "  });", "  box.addEventListener('blur', () => finish(true));", "}", "",
    // A finished tool block is handed over open — the result is what the reader was waiting for, and
    // arriving folded puts it behind a click nobody knows to make — and folds itself a moment later.
    // The attribute travels on that one frame, so the block is open only in the moment its result
    // lands: a page reloaded after that shows it folded, like every other finished tool, and the
    // server never has to know which of its blocks a reader has already looked at.
     "function settle(scope) {", "  if (!scope) return;",
    // The element that carries the attribute is usually the root of what was just patched in, and
    // `querySelectorAll` only looks at descendants — so the root is asked about separately. Missing
    // this is a block that is handed over open and then never folds.
     "  const blocks = scope.matches('[data-settle]') ? [scope] : [...scope.querySelectorAll('[data-settle]')];",
    "  for (const block of blocks) {", "    const ms = Number(block.dataset.settle) || 0;",
    // Removed first, so a block that is replaced again before the timer fires cannot be scheduled
    // to fold twice — and so a reader who opened it in the meantime keeps it open.
     "    block.removeAttribute('data-settle');", "    setTimeout(() => { block.open = false; }, ms);",
    "  }", "}",
    // A tool block that has reported, and the fold it belongs in.
    //
    // The newest finished tool is left outside for a moment — long enough to read the result — and
    // then file() puts it away when the next tool starts. It is folded on the way in rather than
    // arriving folded: the two halves say different things ("here is what came back" and "that is
    // done with now"), and doing both at once would read as the result being whisked away.
    //
    // Folding and filing are separate attributes on separate frames, not a delay decided here: the
    // server says when each happens, because the server is the one that knows whether a turn has
    // more work to do.
     "", "function file(scope) {", "  if (!scope) return;", "  const movers = scope.matches('[data-file]') ? [scope] : [...scope.querySelectorAll('[data-file]')];",
    "  for (const mover of movers) {", "    const block = document.getElementById(mover.dataset.file);",
    "    const fold = document.getElementById(mover.dataset.fileInto);",
    // Cleared first for the same reason as the fold above: one instruction, acted on once.
     "    mover.removeAttribute('data-file');", "    mover.removeAttribute('data-file-into');",
    "    if (!block || !fold) continue;", "    setTimeout(() => {",
    // Folded by hand, because this block is not being replaced by the server again — it is moving,
    // and the fold is what says it is over. Without this the last tool in a turn would stay open.
     "      block.open = false;",
    // Moved, not re-rendered: the server has no patch that says "put this there", and re-sending the
    // markup would lose anything the reader had opened inside it.
     "      fold.appendChild(block);", "    }, 200);", "  }", "}", "", "function apply(patch) {",
    "  if (patch.op === 'status') { status.textContent = patch.text; return; }",
    "  const node = document.getElementById(patch.target);", "  if (!node) return;",
    "  if (!node) return;", "  const follow = atBottom();", "  if (patch.op === 'append') node.insertAdjacentHTML('beforeend', patch.html);",
    "  else if (patch.op === 'appendtext') node.insertAdjacentText('beforeend', patch.text);",
    "  else if (patch.op === 'replace') {", "    // Replacing the transcript is a session arriving. Landing at its end is what the reader",
    "    // came for; a reconnect replaces the same content, so there the reader keeps their place.",
    "    const keep = window.scrollY;",
    // Growing upward needs a different correction from every other replace, and the browser will not
    // do it for us: the whole transcript is one element, so swapping it is not "content inserted
    // above the viewport" as far as scroll anchoring is concerned — it is a new subtree, and the
    // scroll offset is simply kept. Keeping the offset while the page grows above the reader moves
    // what they were reading down by exactly the height that was added: measured at 4,202px for
    // three turns. So the offset is corrected by the height difference instead.
     "    const growFrom = grow ? document.body.scrollHeight : 0;", "    node.outerHTML = patch.html;",
    "    node.outerHTML = patch.html;", "    decorateCode();", "    settle(document.getElementById(patch.target));",
    "    file(document.getElementById(patch.target));", "    if (patch.target === 'transcript' && land) { land = false; toBottom(); }",
    "    else if (grow && patch.target === 'transcript') {", "      grow = false;",
    "      window.scrollTo(0, keep + (document.body.scrollHeight - growFrom));",
    "    }", "    else window.scrollTo(0, keep);", "    return;", "  }", "  if (patch.op === 'append') { decorateCode(); settle(node); file(node); }",
    "  if (follow) toBottom();", "}", "", "// Before the first frame arrives, so the page opens where the conversation ended.",
    "toBottom();", "decorateCode();", "", "// Which session this page is showing. Sessions run in parallel, so a patch produced",
    "// for another one has to be dropped: applying it would append a hidden session's",
    "// output to the visible transcript.", "let shown = document.getElementById('transcript').dataset.shownSession;",
    "",
    // The stream, and whether it is still alive.
    //
    // `EventSource` reconnects on its own once it *notices* a broken connection, and the frames it
    // missed while disconnected are re-fetched as a whole snapshot on reconnect. The gap is the
    // noticing: a half-open socket — the browser swapped networks, the machine slept, a proxy
    // dropped the flow — produces no error for minutes, or ever. The page sits frozen on whatever
    // it was last told, and a manual reload fixes it, which is exactly what makes it hard to report.
    //
    // So this does not trust the connection to notice. Every frame carries a liveness signal for
    // free: if *anything* arrives, the pipe works. The server also sends a named `ping` when it has
    // nothing else to say, so an idle connection is still observably alive. When neither has
    // happened for longer than that ping period allows, the page rebuilds the stream itself.
     "let lastSeen = Date.now();", "let stream = null;", "const LIVENESS_MS = 40000;",
    "function connect() {", "  if (stream) stream.close();",
    // Connecting counts as having heard something. Without this the watchdog's own reconnects feed
    // it: a rebuild that is answered with nothing (the server is busy rendering, not dead) leaves
    // the old timestamp in place, so the next check fires five seconds later and rebuilds again —
    // and every rebuild asks the server for a whole snapshot, which is the most expensive thing it
    // does. A slow server would be pushed further behind by the page trying to help. Treating the
    // reconnect as a liveness event bounds the retry to one per staleness window.
     "  lastSeen = Date.now();", "  stream = new EventSource('/events');", "  stream.addEventListener('ping', () => { lastSeen = Date.now(); });",
    "  stream.addEventListener('patch', event => {", "  lastSeen = Date.now();",
    "  const frame = JSON.parse(event.data);", "  if (frame.session) {", "    if (frame.session === shown) apply(frame.patch);",
    "    return;", "  }",
    // Which session this page is showing is re-read in a `finally`, and that word is doing real
    // work. An unscoped transcript replacement is the only thing that tells the page it has moved
    // to a different session; if `apply` throws before the re-read — a decoration step, a scroll,
    // anything — then `shown` keeps the *old* id, every subsequent scoped frame fails the
    // comparison above, and the page stops updating entirely until it is reloaded. A reload fixes
    // it, which is exactly what makes it hard to report: the server is right, the frames are
    // right, and the client is quietly listening for the wrong session.
     "  try {", "    apply(frame);", "  } finally {", "    if (frame.op === 'replace' && frame.target === 'transcript') {",
    "      const node = document.getElementById('transcript');", "      shown = node ? node.dataset.shownSession : '';",
    "    }", "  }", "  });", "}", "connect();", "setInterval(() => { if (Date.now() - lastSeen > LIVENESS_MS) connect(); }, 5000);",
    "", "// One listener for the whole sidebar: rows come and go as the regions refresh, and",
    "// listeners attached per row would not survive that.", "document.addEventListener('click', event => {",
    // The navigation fold. A class on the sidebar rather than the `open` attribute of a
    // `<details>`, because the element has to survive a region refresh and a rebuilt `<details>`
    // forgets what it was. The button reports what it did, for a screen reader.
     "  const nav = event.target.closest('#nav-toggle');", "  if (nav) {", "    const sidebar = nav.closest('.sidebar');",
    "    const open = sidebar.classList.toggle('open');", "    nav.setAttribute('aria-expanded', open ? 'true' : 'false');",
    "    return;", "  }",
    // Reasoning while it is arriving: the newest lines show, and this opens the rest. An
    // attribute rather than `<details open>`, for the reason in `html/render.mbt` — the block is
    // replaced by the finished rendering when the turn ends, so what it must do then is collapse,
    // and remembering is exactly the wrong behaviour.
    //
    // The same handler serves the figures under an answer. Two attributes are the whole convention:
    // the button says what it controls (`data-expands`), the target says whether it is open
    // (`data-expanded`). Anything that needs to open and close without carrying state back to the
    // server belongs in this pair, not in a third one-off listener.
     "  const expand = event.target.closest('[data-expands]');", "  if (expand) {",
    "    const target = document.getElementById(expand.dataset.expands);", "    if (target) {",
    "      const open = target.toggleAttribute('data-expanded');", "      expand.setAttribute('aria-expanded', open ? 'true' : 'false');",
    "    }", "    return;", "  }",
    // A suggestion, whether it is one of the welcome's examples or a row of the command list: put
    // it in the composer and leave it there. Not sent — sending is the reader's decision, and a
    // command needs its argument filled in before sending it means anything.
     "  const fill = event.target.closest('[data-fill]');", "  if (fill) {", "    input.value = fill.dataset.fill;",
    "    hideCommands();", "    input.focus();",
    // Caret at the end, so the argument a command is waiting for is typed where it belongs.
     "    input.setSelectionRange(input.value.length, input.value.length);", "    return;",
    "  }",
    // The rename control swaps the label for a box holding it. In place rather than in a dialog:
    // the row is what is being named, and the reader is already looking at it.
     "  const rename = event.target.closest('[data-rename]');", "  if (rename) {",
    "    beginRename(rename);", "    return;", "  }",
    // Delete and undo. Both post the path they name, so a click works on the row it was aimed at
    // even if the list has moved on. Nothing is confirmed here on purpose — the delete is a rename
    // and the notice it produces offers the way back, which is the other answer to the same worry.
     "  const remove = event.target.closest('[data-delete]');", "  if (remove) {",
    "    fetch('/session/delete', { method: 'POST', body: remove.dataset.delete }).catch(() => {});",
    "    return;", "  }",
    // More of the conversation. The reply is a whole new transcript, so what keeps the reader's place
    // is the browser's own scroll anchoring — it exists for exactly this, content inserted above the
    // viewport. The button is disabled while its request is in flight, because pressing it twice
    // moves the window twice and re-renders twice for one intention.
     "  const earlier = event.target.closest('[data-earlier]');", "  if (earlier) {",
    "    earlier.disabled = true;", "    grow = true;", "    fetch('/earlier', { method: 'POST', body: '' }).catch(() => {});",
    "    return;", "  }", "  const undo = event.target.closest('[data-undo]');",
    "  if (undo) {", "    fetch('/session/undo', { method: 'POST', body: undo.dataset.undo }).catch(() => {});",
    "    return;", "  }",
    // The folder chooser. The server opens its own dialog and waits for it, so nothing here is
    // disabled or shown as busy while it is up: the reader is looking at the dialog, not the page.
    // The answer comes back as the same patches an added path produces.
     "  const pick = event.target.closest('#workspace-pick');", "  if (pick) {",
    "    land = true;", "    fetch('/workspace/pick', { method: 'POST', body: '' }).catch(() => {});",
    "    return;", "  }", "  // A stop names the session it is for, so a background turn can be ended without",
    "  // bringing it on screen first.", "  const stopTask = event.target.closest('[data-stop]');",
    "  if (stopTask) {", "    fetch('/abort', { method: 'POST', body: stopTask.dataset.stop }).catch(() => {});",
    "    return;", "  }", "  // A kill names the job, so it works whichever session is on screen.",
    "  const kill = event.target.closest('[data-kill]');", "  if (kill) {", "    fetch('/job/kill', { method: 'POST', body: kill.dataset.kill }).catch(() => {});",
    "    return;", "  }",
    // The two answers to an interrupted turn. Neither carries a prompt: the one in flight is
    // already in the log, and re-sending it would append the question a second time. The body is
    // empty rather than the session id, so the server acts on what is on screen — a notice can be
    // stale by the time it is clicked, and the server is the one that can check.
     "  if (event.target.closest('[data-continue]')) {", "    land = true;", "    fetch('/continue', { method: 'POST', body: '' }).catch(() => {});",
    "    return;", "  }", "  if (event.target.closest('[data-dismiss]')) {", "    fetch('/dismiss', { method: 'POST', body: '' }).catch(() => {});",
    "    return;", "  }",
    // The rows that name a session: the sidebar's own, and the labels in the Running and Background
    // panels. Those two answer "something is happening elsewhere" and "that process is still
    // running", and the reader's next move is usually to go and look — so their labels open the
    // session rather than making them find it in the list.
    //
    // Deliberately not on the transcript. `[data-session]` used to be there, and then every click in
    // the conversation — opening a block, selecting text — asked the server to switch to it. The id
    // it carried is short, so no file was found by that name and a new session was started instead:
    // the transcript was replaced by an empty one on the next click.
     "  const open = event.target.closest('[data-session]');", "  if (open) {", "    // Asking for a session is asking to be shown its end.",
    "    land = true;",
    // On a narrow screen picking from the list is also an answer to the fold: the list has done its
    // job, and left open it would sit on top of the conversation the reader just chose. A label in
    // one of the panels is not a pick from that list, so it leaves the fold alone.
     "    const folded = document.querySelector('.sidebar.open');", "    if (folded && open.closest('.sidebar')) {",
    "      folded.classList.remove('open');", "      const toggle = document.getElementById('nav-toggle');",
    "      if (toggle) toggle.setAttribute('aria-expanded', 'false');", "    }",
    "    fetch('/session', { method: 'POST', body: open.dataset.session }).catch(() => {});",
    "    return;", "  }",
    // The way past the sidebar's cap for one workspace. The list lives on the server, so this asks
    // it for the rest rather than doing anything to the page.
     "  const more = event.target.closest('[data-more]');", "  if (more) {", "    fetch('/more', { method: 'POST', body: more.dataset.more }).catch(() => {});",
    "    return;", "  }", "  const fresh = event.target.closest('[data-new]');",
    "  if (fresh) {", "    land = true;", "    const folded = document.querySelector('.sidebar.open');",
    "    if (folded) {", "      folded.classList.remove('open');", "      const toggle = document.getElementById('nav-toggle');",
    "      if (toggle) toggle.setAttribute('aria-expanded', 'false');", "    }",
    "    fetch('/new', { method: 'POST', body: fresh.dataset.new }).catch(() => {});",
    "  }", "});", "", "// Adding a workspace posts and stays put; a form submit would navigate to the response.",
    "// Delegated rather than attached to the form: the sidebar is replaced whenever it is",
    "// refreshed, and a listener on the old node would be gone with it.", "document.addEventListener('submit', event => {",
    "  const add = event.target.closest('#add-workspace');", "  if (!add) return;",
    "  event.preventDefault();", "  const field = add.querySelector('#workspace-path');",
    "  const path = field.value.trim();", "  if (!path) return;", "  field.value = '';",
    "  // Adding one opens a session in it, so the reader lands at that session's end too.",
    "  land = true;", "  fetch('/workspace', { method: 'POST', body: path }).catch(() => {});",
    "});", "", "// Settings is a set of forms, posted the same way as everything else: the server writes, broadcasts",
    "// the result and the panel is replaced with what is actually in effect. A form-encoded body",
    "// rather than JSON, because the skill list is a set of checkboxes and that is exactly the",
    "// encoding a form already has. The key field is cleared on submit because the server never",
    "// sends a key back — leaving the value on screen would show a credential the page itself",
    "// refused to render. `key-clear` and `limits-clear` are forms of their own rather than second",
    "// buttons in the forms above: `new FormData(form)` leaves submit buttons out entirely, so a",
    "// button's value would never reach the server. The instructions textarea posts like the rest and",
    "// is left filled in: unlike a key, the server does send it back, so clearing the box would mean",
    "// retyping the whole thing to make one edit.", "document.addEventListener('submit', event => {",
    "  const keyForm = event.target.closest('#key-form');", "  const skillsForm = event.target.closest('#skills-form');",
    "  const clearForm = event.target.closest('#key-clear');", "  const limitsForm = event.target.closest('#limits-form');",
    "  const limitsClear = event.target.closest('#limits-clear');", "  const agentsForm = event.target.closest('#agents-form');",
    "  const modeForm = event.target.closest('#mode-form');", "  if (!keyForm && !skillsForm && !clearForm && !limitsForm && !limitsClear && !agentsForm && !modeForm) return;",
    "  event.preventDefault();", "  const form = keyForm || skillsForm || clearForm || limitsForm || limitsClear || agentsForm || modeForm;",
    "  const url = skillsForm ? '/settings/skills' : agentsForm ? '/settings/agents' : modeForm ? '/settings/mode' : keyForm || clearForm ? '/settings/key' : '/settings/limits';",
    "  const body = new URLSearchParams(new FormData(form)).toString();", "  if (keyForm) { const field = form.querySelector('#key-input'); if (field) field.value = ''; }",
    "  fetch(url, { method: 'POST', body }).catch(() => {});", "});", "", "form.addEventListener('submit', event => {",
    "  event.preventDefault();", "  const text = input.value.trim();", "  if (!text) return;",
    "  input.value = '';", "  send.disabled = true;", "  fetch('/prompt', { method: 'POST', body: text })",
    "    .catch(() => {})", "    .finally(() => { send.disabled = false; input.focus(); });",
    "});", "", "// The model picker. Delegated, and by `change` rather than by a submit: the `<select>` lives",
    "// inside the composer form, and making it a submitter would send the reader's prompt along with",
    "// the model. A refused switch comes back as a patch that puts the control where it was.",
    "document.addEventListener('change', event => {", "  const picker = event.target.closest('#model-picker');",
    "  if (!picker) return;", "  fetch('/model', { method: 'POST', body: picker.value }).catch(() => {});",
    "});", "", "// Stop is delegated rather than bound to the node, because the button is replaced whenever a",
    "// turn starts or ends — a listener attached to it would be thrown away with the old node.",
    "document.addEventListener('click', event => {", "  const stop = event.target.closest('#stop');",
    "  if (!stop) return;", "  fetch('/abort', { method: 'POST' }).catch(() => {});",
    "});", "", "input.addEventListener('input', syncCommands);", "input.addEventListener('keydown', event => {",
    "  if (event.key === 'Escape') { hideCommands(); return; }", "  if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) form.requestSubmit();",
    "});", "", "// The elapsed times in the tasks panel, and on a tool that is running, count here rather than",
    "// on the server: a frame a second to move a number the browser can work out itself would be",
    "// paying for nothing. One selector for both, because they are one convention — an element",
    "// carrying `data-since` is a clock, and its text becomes how long ago that was.",
    "function tick() {", "  const now = Date.now();", "  for (const node of document.querySelectorAll('[data-since]')) {",
    "    const seconds = Math.max(0, Math.round((now - Number(node.dataset.since)) / 1000));",
    "    if (seconds < 60) node.textContent = seconds + 's';", "    else if (seconds < 3600) node.textContent = Math.floor(seconds / 60) + 'm ' + (seconds % 60) + 's';",
    "    else node.textContent = Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm';",
    "  }",
    // And the elements that are only true until a moment has passed. One attribute, one meaning: an
    // element carrying `data-expires` is an offer with a deadline, and it takes itself away when
    // the deadline is behind the reader. The server stops rendering it on the same rule, so this is
    // what makes it go while the page is open — the alternative is a frame from the server to say
    // "still nothing", four times, to move something that is already on the page.
    //
    // The undo note after a delete is the only user today, and the reason it is worth an attribute
    // is that the offer is a courtesy rather than a control: a reader who has moved on should not
    // have to dismiss it.
     "  for (const node of document.querySelectorAll('[data-expires]')) {", "    if (Number(node.dataset.expires) <= now) node.remove();",
    "  }", "}", "setInterval(tick, 1000);", "",
    // ── settings, as a modal ───────────────────────────────────────────────
    // Opened by script rather than by the element that holds it, which is the price of a modal:
    // `showModal` is what gives focus trapping, `Esc` and the backdrop for free, and no declarative
    // attribute reaches it. What it buys is worth that: the panel gets the whole surface instead of
    // the sidebar's column, and the browser owns the ways out.
     "const settingsDialog = document.getElementById('settings');",
    // Delegated from the document, not bound inside the dialog: the control is rendered once and
    // never replaced, but the dialog's insides are replaced on every save, so a listener bound in
    // there would belong to a node that no longer exists after the first Apply.
     "document.addEventListener('click', event => {", "  if (event.target.closest('#settings-open')) {",
    "    if (!settingsDialog.open) settingsDialog.showModal();", "    syncSettingsNav();",
    "    return;", "  }", "  if (event.target.closest('#settings-close')) { settingsDialog.close(); return; }",
    "  const item = event.target.closest('.settings-nav-item');", "  if (!item) return;",
    "  const section = document.getElementById(item.dataset.section);",
    // Scrolled rather than jumped: the sections are one column and a jump loses the reader's sense
    // of where they are in it. `block: 'start'` lands the heading under the top edge, which is what
    // `scroll-margin-top` on the section is for.
     "  if (section) section.scrollIntoView({ block: 'start', behavior: 'smooth' });",
    "  markSettingsNav(item.dataset.section);", "});", "", "function markSettingsNav(id) {",
    "  for (const button of document.querySelectorAll('.settings-nav-item')) {",
    "    button.setAttribute('aria-current', button.dataset.section === id ? 'true' : 'false');",
    "  }", "}", "",
    // The mark follows scrolling, not only clicks: a reader who scrolls by hand should see it move,
    // and one who clicks should not be told they are somewhere they are not. Not `scrollend` — it is
    // not everywhere yet — so this measures from the browser's own geometry instead.
     "function syncSettingsNav() {", "  const body = document.getElementById('settings-body');",
    "  if (!body) return;", "  const sections = [...body.querySelectorAll('.settings-section')];",
    "  if (!sections.length) return;",
    // Scrolled to the bottom, the last section is what the reader is looking at even though its
    // heading is still below the top edge. Without this the last item can never be marked: the
    // panel's content is shorter than its viewport, so even the deepest scroll position leaves the
    // last heading halfway down. Measured rather than assumed — the browser check caught exactly
    // this, with the mark stuck on the section before the one that was clicked.
     "  if (body.scrollTop + body.clientHeight >= body.scrollHeight - 2) {", "    markSettingsNav(sections[sections.length - 1].id);",
    "    return;", "  }", "  const mark = body.scrollTop + 1;", "  let current = null;",
    "  for (const section of sections) {", "    if (section.offsetTop <= mark) current = section.id;",
    "  }", "  if (current) markSettingsNav(current);", "}", "",
    // Bound with `capture`, because scroll does not bubble: without it the document never hears an
    // event that happened on a descendant.
     "document.addEventListener('scroll', event => {", "  if (event.target && event.target.id === 'settings-body') syncSettingsNav();",
    "}, true);",
  ].join("\n")
}
