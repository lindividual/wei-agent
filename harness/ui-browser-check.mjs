#!/usr/bin/env node
/**
 * Browser acceptance for the UI.
 *
 * The server-rendered design is verified at the byte level elsewhere: the tests
 * assert what the frames contain. What they cannot see is what a browser does with
 * them — and the worst bug this UI has had was exactly that kind. The first frame
 * carried a whole HTML document where a fragment was expected; applied with
 * `outerHTML`, the browser spliced the document's contents into the body, leaving
 * two composers of which only the detached one had its listeners. Every byte-level
 * assertion passed while the page was unusable.
 *
 * So this drives a real browser: a headless Chrome of its own (not the user's),
 * over the DevTools protocol, with real input events, real reconnects, and a hard
 * failure on any uncaught exception.
 *
 *   node harness/ui-browser-check.mjs            # expects a built ui.exe
 *   node harness/ui-browser-check.mjs --keep     # leave the screenshot and store
 *
 * Requires the `ui` package to be built (`moon build --target native`) and a
 * DeepSeek key reachable the way `moon run ui` finds one, because two of the checks
 * need a real turn.
 */
import { spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
// Set once the page is attached, so the crash handler below can report what the page threw.
let cdp = null;
const UI_BIN_SOURCE = "_build/native/debug/build/ui/ui.exe";
// The copy actually run, taken once at startup.
//
// The reconnect check restarts the server, which means spawning this path a second time — and it used
// to be spawned straight out of the build directory. That is fine until something else is building:
// a rebuild landing mid-run then swaps the server under the second half of the checks, so the run
// measures two different programs and reports the difference as a failure of the page. Copying first
// makes the run measure one artifact, whichever one was there when it started.
let UI_BIN = UI_BIN_SOURCE;
const KEEP = process.argv.includes("--keep");
const PORT = await freePort();
const DEBUG_PORT = await freePort();
const URL = `http://127.0.0.1:${PORT}/`;

/// A port nothing is listening on.
///
/// Bound and released rather than fixed: a leftover process from a previous run
/// holding the port turns a check of the UI into a check of nothing.
async function freePort() {
  return await new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

const failures = [];
const notes = [];

function check(ok, label, detail) {
  if (ok) {
    console.log(`  ok   ${label}`);
  } else {
    console.log(`  FAIL ${label}${detail ? `\n       ${detail}` : ""}`);
    failures.push(label);
  }
}

function note(text) {
  notes.push(text);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// The store directory name for a working directory.
///
/// Reimplemented here rather than imported, because the check has to be able to
/// seed a workspace the server has never seen. `assertEncodingRule` keeps the copy
/// honest: it is checked against the directory the server itself created.
function storeDirName(cwd) {
  const start = cwd.startsWith("/") ? 1 : 0;
  const body = cwd
    .slice(start)
    .replace(/[/\\:]/g, "-");
  return `--${body}--`;
}

/// The tag the transcript advertises for the session it is showing.
///
/// This is what the client compares scoped frames against, and it is the only stable way to say
/// *which* session is on screen. Asserting on the conversation's text does not work any more: a long
/// session is rendered as a window over its newest turns, so its first question — the thing these
/// checks used to look for — is deliberately not in the page.
function tagOf(path) {
  const name = path.split("/").pop();
  const stem = name.endsWith(".jsonl") ? name.slice(0, -".jsonl".length) : name;
  return stem.split("_").pop();
}

/// The settings panel writes a file under `$HOME`, and a check must not edit the real one: run
/// the server with a scratch home, and give it the credential store so real turns still work.
///
/// This is also what makes the check hermetic: the skills the panel lists come from `$HOME`, so a
/// machine with a large collection would otherwise see a different panel than a fresh checkout.
function scratchHome() {
  const home = mkdtempSync(join(tmpdir(), "pws-home-"));
  const auth = join(homedir(), ".pi/agent/auth.json");
  if (existsSync(auth)) {
    mkdirSync(join(home, ".pi/agent"), { recursive: true });
    copyFileSync(auth, join(home, ".pi/agent/auth.json"));
  }
  // One skill, so the panel has something to switch: an empty list renders an explanation
  // instead, and neither state would be exercised.
  const skill = join(home, ".pi/agent/skills/browser-demo");
  mkdirSync(skill, { recursive: true });
  writeFileSync(
    join(skill, "SKILL.md"),
    "---\nname: browser-demo\ndescription: Seeded by the browser check.\n---\n\n" +
      "# browser-demo\n\nA body the model can only have read through the expansion: reply with\n" +
      "exactly SKILL-BODY-OK-9f2c when this skill is invoked.\n",
  );
  return home;
}

/// A session file the server will accept: a header, then `turns` exchanges.
///
/// `turns` exists so a check can seed a conversation taller than the viewport: what the page does
/// with the scroll position is only observable when there is something to scroll.
function sessionFile(cwd, label, turns = 1) {
  const id = Math.random().toString(16).slice(2, 10);
  const at = new Date(1700000000000).toISOString();
  const line = (o) => JSON.stringify(o);
  const exchange = (n) => [
    line({
      type: "message",
      id: `u${n}`,
      parentId: n === 1 ? null : `a${n - 1}`,
      timestamp: at,
      message: {
        role: "user",
        content: [{ type: "text", text: n === 1 ? label : `question ${n}` }],
        timestamp: 1700000000000,
      },
    }),
    line({
      type: "message",
      id: `a${n}`,
      parentId: `u${n}`,
      timestamp: at,
      message: {
        role: "assistant",
        content: [{ type: "text", text: `an answer of a few lines, for ${n}.\n\nWith a second paragraph so the conversation is tall enough to need scrolling.` }],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: {
          input: 1,
          output: 1,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 2,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
        },
        stopReason: "stop",
        timestamp: 1700000000000,
      },
    }),
  ];
  const seeded = [line({ type: "session", version: 3, id, timestamp: at, cwd })];
  for (let n = 1; n <= turns; n++) seeded.push(...exchange(n));
  return { id, text: seeded.join("\n") + "\n" };
}

/// The same, for a session with only a header and one exchange.
function shortSessionFile(cwd, label) {
  return sessionFile(cwd, label, 1);
}

/// Unused: kept for the older call shape.
function sessionFileLegacy(cwd, label) {
  const id = Math.random().toString(16).slice(2, 10);
  const at = new Date(1700000000000).toISOString();
  const line = (o) => JSON.stringify(o);
  return {
    id,
    text: [
      line({ type: "session", version: 3, id, timestamp: at, cwd }),
      line({
        type: "message",
        id: "u1",
        parentId: null,
        timestamp: at,
        message: {
          role: "user",
          content: [{ type: "text", text: label }],
          timestamp: 1700000000000,
        },
      }),
      line({
        type: "message",
        id: "a1",
        parentId: "u1",
        timestamp: at,
        message: {
          role: "assistant",
          content: [{ type: "text", text: "seeded" }],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: {
            input: 1,
            output: 1,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: 2,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
          },
          stopReason: "stop",
          timestamp: 1700000000000,
        },
      }),
    ].join("\n") + "\n",
  };
}

// ── a very small CDP client ────────────────────────────────────────────────

class Session {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.exceptions = [];
    this.consoleErrors = [];
    ws.addEventListener("message", (event) => this.onMessage(event.data));
  }

  onMessage(data) {
    const message = JSON.parse(data);
    if (message.id !== undefined) {
      const waiter = this.pending.get(message.id);
      if (waiter) {
        this.pending.delete(message.id);
        if (message.error) waiter.reject(new Error(JSON.stringify(message.error)));
        else waiter.resolve(message.result);
      }
      return;
    }
    // Anything uncaught is a failure of the page, not of the checks.
    if (message.method === "Runtime.exceptionThrown") {
      this.exceptions.push(
        message.params.exceptionDetails?.exception?.description ??
          JSON.stringify(message.params.exceptionDetails),
      );
    }
    if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
      this.consoleErrors.push(
        message.params.args.map((a) => a.value ?? a.description ?? "").join(" "),
      );
    }
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} timed out`));
      }, 30000);
    });
  }

  /// Evaluate in the page and return the value, raising on a thrown error.
  async eval(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(
        `${expression} threw: ${result.exceptionDetails.exception?.description}`,
      );
    }
    return result.result.value;
  }

  /// Move the pointer. The point is the page's own `:hover` rules: a reveal that only exists for a
  /// pointer cannot be seen any other way, and faking the style would test the fake.
  async moveMouse(x, y) {
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
    // One frame, so the style the check reads is the one the browser has settled on.
    await sleep(100);
  }

  /// Poll an expression until it is truthy, so the checks do not race the page.
  async waitFor(expression, label, timeoutMs = 60000) {
    const deadline = Date.now() + timeoutMs;
    let last;
    while (Date.now() < deadline) {
      last = await this.eval(expression);
      if (last) return true;
      await sleep(250);
    }
    throw new Error(`timed out waiting for ${label} (${expression}); last=${JSON.stringify(last)}`);
  }

  async screenshot(path) {
    const result = await this.send("Page.captureScreenshot", { format: "png" });
    const { writeFileSync } = await import("node:fs");
    writeFileSync(path, Buffer.from(result.data, "base64"));
    return path;
  }
}

async function httpJson(url, attempts = 60) {
  for (let i = 0; i < attempts; i++) {
    try {
      const response = await fetch(url);
      if (response.ok) return await response.json();
    } catch {
      /* not up yet */
    }
    await sleep(250);
  }
  throw new Error(`no answer from ${url}`);
}

// ── the server under test ──────────────────────────────────────────────────

function startServer(store, home) {
  // `--no-picker` because this run is unattended: the folder chooser is a real dialog on the
  // machine's own screen, and nothing here could close it. A host without a chooser is the one
  // whose way in is the path field, which is what the workspace checks drive — and the assertion
  // further down that the chooser is absent is then about the flag rather than about the host.
  const child = spawn(UI_BIN, ["--port", String(PORT), "--store", store, "--no-picker"], {
    stdio: ["ignore", "pipe", "pipe"],
    // The scratch home keeps the settings panel's file, and the skills it lists, out of the
    // real `$HOME`.
    env: { ...process.env, HOME: home },
  });
  // The server logs to stderr on purpose (it is the stream that survives a crash),
  // so a failure to start has to be surfaced from there.
  child.stdout.on("data", (d) => process.stdout.write(`  [ui] ${d}`));
  child.stderr.on("data", (d) => process.stdout.write(`  [ui] ${d}`));
  return child;
}

/// Wait for the server to answer at all.
///
/// Not `httpJson`: the readiness probe returns the page, and parsing HTML as JSON
/// throws — which the retry loop would read as "not up yet" forever.
async function waitForServer() {
  for (let i = 0; i < 160; i++) {
    try {
      const response = await fetch(URL);
      if (response.ok) return;
    } catch {
      /* not up yet */
    }
    await sleep(250);
  }
  throw new Error(`no answer from ${URL}`);
}

// ── the checks ─────────────────────────────────────────────────────────────

async function main() {
  if (!existsSync(UI_BIN_SOURCE)) {
    console.error(`missing ${UI_BIN_SOURCE} — run: moon build --target native`);
    process.exit(2);
  }
  UI_BIN = join(mkdtempSync(join(tmpdir(), "pws-bin-")), "ui.exe");
  copyFileSync(UI_BIN_SOURCE, UI_BIN);
  const store = mkdtempSync(join(tmpdir(), "pws-browser-"));
  const home = scratchHome();
  const profile = mkdtempSync(join(tmpdir(), "pws-chrome-"));
  mkdirSync(join(profile, "Default"), { recursive: true });

  let backgroundPids = [];
  let server = startServer(store, home);
  let chrome = null;
  try {
    await waitForServer();
  } catch (err) {
    server.kill("SIGKILL");
    throw err;
  }
  console.log(`server up on ${PORT}, store ${store}`);

  chrome = spawn(
    CHROME,
    [
      "--headless=new",
      `--remote-debugging-port=${DEBUG_PORT}`,
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      "--window-size=1280,900",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  const targets = await httpJson(`http://127.0.0.1:${DEBUG_PORT}/json/list`);
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve);
    ws.addEventListener("error", reject);
  });
  cdp = new Session(ws);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");

  try {
    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor("document.readyState === 'complete'", "page load", 20000);
    // The first SSE frame arrives asynchronously; give it a moment to be applied,
    // because that is the frame this whole check exists for.
    await sleep(1500);

    console.log("\nstructure (the first frame must not duplicate or detach anything)");
    const counts = await cdp.eval(
      `JSON.stringify(Object.fromEntries(['transcript','sessions','composer','send','stop','status','prompt']
        .map(id => [id, document.querySelectorAll('#' + id).length])))`,
    );
    const seen = JSON.parse(counts);
    check(
      Object.values(seen).every((n) => n === 1),
      "each element exists exactly once",
      counts,
    );
    check(
      (await cdp.eval("document.querySelectorAll('html').length")) === 1,
      "the document was not nested into itself",
    );
    check(
      (await cdp.eval("document.querySelectorAll('.exchange').length")) === 0,
      "a brand new session starts with an empty transcript",
    );

    console.log("\ncomposer (the listeners must be on the elements that are on screen)");
    const prompt = "Reply with exactly: browser-ok";
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = ${JSON.stringify(prompt)};
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes(${JSON.stringify(prompt)})`,
      "the prompt to appear in the transcript",
      30000,
    );
    check(true, "submitting the form reaches the server and comes back as a patch");

    console.log("\nturn (streaming, then the rendered reply, then the status line)");
    await cdp.waitFor(
      `/#status/.test('') || document.getElementById('status').textContent.length > 0`,
      "the status line to say something",
    );
    await cdp.waitFor(
      `document.querySelectorAll('#transcript .blocks .text').length > 0`,
      "the reply to land in the transcript",
      90000,
    );
    await cdp.waitFor(
      // The *footer*, not the status line. A finished turn's figures live under its reply, and the
      // status line deliberately carries only what the footer cannot say — that a guard stopped the
      // turn. Waiting for the status line here would have been waiting for the duplication back.
      `document.querySelectorAll('#transcript .turn-stats').length > 0`,
      "the turn's figures to appear under the reply",
      90000,
    );
    const status = await cdp.eval("document.getElementById('status').textContent");
    // A turn that just finished normally: nothing to announce, because the answer is the report.
    check(
      !/model call/.test(status),
      "a finished turn does not restate its own figures on the status line",
      status,
    );
    const footer = await cdp.eval(
      "[...document.querySelectorAll('#transcript .turn-stats')].pop().textContent",
    );
    check(/\$\d/.test(footer), "the turn's footer reports a cost", footer);
    check(/model call/.test(footer), "the footer reports the model calls", footer);
    // The figures under the composer report what the session has used, from the log.
    const figures = await cdp.eval("document.getElementById('usage').textContent");
    check(
      /tokens/.test(figures) && /cost/.test(figures) && /context/.test(figures),
      "the figures under the composer report usage, cost and context",
      figures,
    );
    check(
      !/\b0 in \/ 0 out\b/.test(figures),
      "a session that has run a turn reports figures that are not all zero",
      figures,
    );
    const costText = await cdp.eval(
      "[...document.querySelectorAll('#usage .chip')].find(c => c.textContent.startsWith('cost')).textContent",
    );
    check(/\$\d+\.\d{4,}/.test(costText), "the cost has enough digits to be non-zero", costText);
    const costDetail = await cdp.eval(
      "[...document.querySelectorAll('#usage .chip')].find(c => c.textContent.startsWith('cost')).title",
    );
    check(
      /input \$/.test(costDetail) && /output \$/.test(costDetail),
      "the breakdown is one hover away",
      costDetail,
    );
    // The bar is a warning rather than a gauge, so this checks the rule and not just the element:
    // the figure is always a proportion of the window, and the bar is drawn only once that
    // proportion is big enough to see. A fresh session against a large window is nowhere near it,
    // and an empty rectangle still draws the eye — which is the state this used to be in.
    const ctx = await cdp.eval(`(() => {
      const chip = [...document.querySelectorAll('#usage .chip')].find(c => c.textContent.startsWith('context'));
      const scale = (n, s) => Number(n) * (s === 'k' ? 1e3 : s === 'M' ? 1e6 : 1);
      const m = chip.textContent.match(/([\\d.]+)([kM]?) \\/ ([\\d.]+)([kM]?)/);
      return {
        text: chip.textContent,
        meter: !!chip.querySelector('.meter'),
        fraction: m ? scale(m[1], m[2]) / scale(m[3], m[4]) : null,
      };
    })()`);
    check(
      ctx.fraction !== null && ctx.meter === (ctx.fraction >= 0.02),
      "the context figure is a proportion of the window, and its bar appears only when that is visible",
      JSON.stringify(ctx),
    );

    const replyHtml = await cdp.eval(
      "document.querySelector('#transcript .blocks .text').innerHTML",
    );
    check(
      /browser-ok/.test(replyHtml),
      "the reply is rendered into the transcript",
      replyHtml.slice(0, 120),
    );
    check(
      (await cdp.eval("document.querySelectorAll('#transcript .exchange').length")) === 1,
      "the turn produced exactly one exchange",
    );
    // The streamed text lived in a throwaway container that the finished reply
    // replaces. Its absence is what distinguishes "settled into the final shape"
    // from "still showing whatever arrived".
    check(
      (await cdp.eval("document.querySelectorAll('[id^=streams-]').length")) === 0,
      "the streaming container was replaced by the rendered reply",
    );
    // The answer is the last thing the model wrote, and it sits outside the fold over the working —
    // otherwise the fold would be standing between the reader and the thing they came for. A direct
    // child is the assertion, not "present": the working contains text blocks too, and a fold that
    // swallowed the answer would still pass a `querySelector`.
    check(
      (await cdp.eval("document.querySelectorAll('#transcript .blocks > .text').length")) === 1,
      "the answer is a direct child of the exchange, not inside the fold",
    );
    // The figures line is the way into what the figures are made of: the numbers behind it were
    // already known and had nowhere to be read. It is the page's second disclosure — the reasoning
    // block while it streams is the first — and both go through one convention, so this checks the
    // convention rather than the one panel: a `[data-expands]` button names a target that exists,
    // clicking it opens that target, and the button says so.
    const disclosure = await cdp.eval(`(() => {
      const button = document.querySelector('#transcript .turn-stats [data-expands]');
      if (!button) return { error: 'no figures line to open' };
      const target = document.getElementById(button.dataset.expands);
      if (!target) return { error: 'the line names a target that is not on the page', id: button.dataset.expands };
      const before = getComputedStyle(target).display;
      button.click();
      return {
        before,
        after: getComputedStyle(target).display,
        rows: target.querySelectorAll('dt').length,
        aria: button.getAttribute('aria-expanded'),
      };
    })()`);
    check(!disclosure.error, "the figures line names a breakdown that is on the page", JSON.stringify(disclosure));
    check(
      disclosure.before === 'none' && disclosure.after !== 'none',
      "clicking the figures line opens the breakdown",
      JSON.stringify(disclosure),
    );
    check(
      disclosure.rows >= 2 && disclosure.aria === 'true',
      "the breakdown lists the numbers, and the line reports that it is open",
      JSON.stringify(disclosure),
    );

    console.log("\nstreaming blocks (a block must not be an empty box)");
    // The reader can open a reasoning or tool block while it is still being written. Batching
    // deltas by size alone meant the block appeared in the DOM on its first delta and stayed empty
    // until enough text had piled up — a quarter of a kilobyte, for reasoning — so opening one
    // mid-stream showed nothing at all. A flush timer bounds that, and this is the shape of the
    // requirement: the live container has text in it while the turn runs.
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = "Think it through carefully, then answer in one sentence: what is the most common cause of flaky tests? No tools.";
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelectorAll('[id^=streams-]').length >= 1`,
      "a live container to appear",
      60000,
    );
    await cdp.waitFor(
      `document.querySelector('[id^=streams-]').textContent.trim().length > 0`,
      "the live block to have text in it",
      2000,
    );
    check(true, "a block that is streaming has text, not an empty box");
    // And opening one shows that text: the detail the reader clicked for.
    const liveVisible = await cdp.eval(
      `(() => {
        const details = document.querySelector('[id^=streams-] details');
        if (!details) return 'no details yet';
        details.open = true;
        return details.textContent.trim().length > 0 ? 'has text' : 'empty';
      })()`,
    );
    check(
      liveVisible === 'has text' || liveVisible === 'no details yet',
      "expanding a live block shows its content",
      liveVisible,
    );
    // Reasoning while it is arriving has three states, which is one more than `<details>` has, so
    // it is not one: the newest few lines show, the header opens the rest, and the finished turn
    // folds it away entirely. What is asserted here is the part that cannot be asserted in a unit
    // test — that the clip keeps the *newest* lines. `overflow: hidden` alone would keep the oldest.
    const peek = await cdp.eval(`(() => {
      const block = document.querySelector('#transcript .thinking.live');
      // Not every model reasons; when none does there is nothing here to be wrong.
      if (!block) return { skipped: 'the model produced no reasoning this turn' };
      const body = block.querySelector('.body');
      const head = block.querySelector('.head');
      if (!body || !head) return { error: 'the live reasoning block is missing its parts' };
      const box = body.getBoundingClientRect();
      // The content's own height, not the box's. \`scrollHeight\` is the wrong instrument here: it is
      // an integer and a clipped flex column reports the *clipped* height through it, so it cannot
      // tell a box that is exactly full from one with a screenful hidden behind it — and comparing
      // it against a fractional height made this check fail on every turn whose reasoning happened
      // to be shorter than the clip.
      const range = document.createRange();
      range.selectNodeContents(body);
      const content = range.getBoundingClientRect().height;
      const lineHeight = parseFloat(getComputedStyle(body).lineHeight) || 0;
      const clip = {
        height: box.height,
        content,
        lineHeight,
        // Only worth judging what is on show once at least a whole line is hidden: clipping less
        // than that leaves the top of the box inside the *first* line, so "is this the newest of
        // it" has no answer to give either way.
        hidesAWholeLine: content > box.height + lineHeight + 2,
      };
      head.click();
      const opened = block.hasAttribute('data-expanded') && getComputedStyle(body).display !== 'flex';
      head.click();
      const closed = !block.hasAttribute('data-expanded');
      return {
        clip,
        // Anchoring the column to its end is what makes the overflow fall off the top. Where the
        // clipped box begins is the first *visible* character, so if that is not the start of the
        // text, the end is what is being shown.
        startsAtText: document.caretRangeFromPoint(box.left + 3, box.top + 1)?.startOffset === 0,
        opened,
        closed,
        aria: head.getAttribute('aria-expanded'),
      };
    })()`);
    check(!peek.error, "the live reasoning block is well formed", JSON.stringify(peek));
    if (!peek.skipped) {
      // The promise is a ceiling, not an exact size: a turn that thought for two lines shows two.
      check(
        peek.clip.lineHeight > 0 && peek.clip.height <= peek.clip.lineHeight * 3 + 2,
        "reasoning in flight is no taller than the three lines it promises",
        JSON.stringify(peek),
      );
      // And when there is more than fits, what is on show is the *newest* of it. This is the half
      // that a unit test cannot check, and the half that `overflow: hidden` alone would get wrong.
      check(
        !peek.clip.hidesAWholeLine || peek.startsAtText === false,
        "and the lines on show are the newest ones, not the oldest",
        JSON.stringify(peek),
      );
      check(peek.opened && peek.closed, "the reasoning header opens and closes it", JSON.stringify(peek));
      check(peek.aria === 'false', "and reports that it is shut again", JSON.stringify(peek));
    } else {
      console.log(`  --   reasoning peek not observed: ${peek.skipped}`);
    }
    await cdp.waitFor(
      `!/working…/.test(document.getElementById('status').textContent)`,
      "the turn to finish before the next section",
      120000,
    );

    console.log("\na tool that is running (shown from the start, folded when it is over)");
    // `read` finishes in milliseconds, so the running state is invisible on any tool that is
    // already fast. The only way to look at it is to run something slow, and the running state is
    // the whole point: a real `bash` call can take minutes, and those minutes are exactly when the
    // reader is asking whether anything is happening.
    //
    // Long enough to survive the reload below, which is the part of this that used to be broken.
    //
    // The figures are read before the prompt goes in, because what this turn does to them is the
    // other half of the wait: a model call is paid for the moment it answers, and the tool it asked
    // for then runs for 20 seconds with the bar still showing the *previous* turn's totals.
    const usageBefore = await cdp.eval(
      "document.getElementById('usage').textContent",
    );
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        // Two tools, not one, and both halves matter: the slow one is what makes the running state
        // observable (and survives the reload below), and the second one is what puts the first away
        // — a tool is filed when the *next* one starts, so a turn with one tool never shows a fold.
        input.value = "Use the bash tool to run exactly: /bin/sleep 20. Then use the bash tool again to run exactly: /bin/echo done. Then answer in one sentence.";
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelectorAll('#transcript [id^=live-tool].running').length >= 1`,
      "the tool's block to appear while the tool is still running",
      120000,
    );
    const liveTool = await cdp.eval(`(() => {
      const block = document.querySelector('#transcript [id^=live-tool].running');
      const time = block.querySelector('time');
      const args = block.querySelector('.args');
      const detail = block.querySelector('.pending');
      // What is inside, and in what order: the call, then the body. The finished block has the same
      // two things in the same places, which is the point — a block must not change shape when the
      // tool ends.
      return {
        id: block.id,
        open: block.hasAttribute('open'),
        hasTimer: !!time,
        before: time ? time.textContent : null,
        // Where the clock is. It sits on the running line — the line that says what is happening, so
        // "and for how long" belongs beside it — and the summary is left as the bare tool name, which
        // is what a finished block's summary says too.
        clockOnRunningLine: !!block.querySelector('.pending time'),
        clockInSummary: !!block.querySelector('summary time'),
        shape: [...block.children].map((c) => c.tagName.toLowerCase() + '.' + (c.className || '')),
        args: args ? args.textContent : null,
        detail: detail ? detail.textContent : '',
        // Open means it is readable without a click, which is the assertion: the block is shown from
        // the moment the tool starts, not from the moment it is over.
        visibleWithoutClick: args && args.checkVisibility ? args.checkVisibility() : true,
        // The clock and the call are shown together in the summary line and the body, and the
        // summary line must not be the only thing there is.
        bodyHeight: block.getBoundingClientRect().height,
      };
    })()`);
    check(
      liveTool.open && liveTool.visibleWithoutClick,
      "a tool that is running is shown open, with its call readable",
      JSON.stringify(liveTool),
    );
    check(
      liveTool.hasTimer && /^\d/.test(liveTool.before || ''),
      "and it is counting from when it started",
      JSON.stringify(liveTool),
    );
    check(
      liveTool.clockOnRunningLine && !liveTool.clockInSummary,
      "the clock is on the line that says what is happening, not in the heading",
      JSON.stringify(liveTool),
    );
    // The call itself, not a one-line paraphrase of it: the block a reader watches is the block they
    // will be left with, so it shows the same arguments the finished one does.
    check(
      /sleep 20/.test(liveTool.args || ''),
      "and it shows the call, not a summary of it",
      JSON.stringify(liveTool),
    );
    // The figures have already moved, twenty seconds before this turn ends. Each call's tokens,
    // cache reads and context are in the log as soon as it comes back, and the figures of a turn are
    // read while it runs — a turn whose tool round lasts minutes is the case that needs them, and it
    // is the case figures updated only at the end say nothing about.
    const usageDuring = await cdp.eval(
      "document.getElementById('usage').textContent",
    );
    check(
      usageDuring !== usageBefore,
      "the figures report the running turn's spend, not the last turn's",
      `${usageBefore} -> ${usageDuring}`,
    );
    check(
      /in \/ .* out/.test(usageDuring),
      "with the totals still readable",
      usageDuring,
    );
    check(
      liveTool.shape.length === 3 &&
        liveTool.shape[0] === "summary." &&
        liveTool.shape[2] === "div.pending",
      "with the same inside as a finished block: the summary, the call, then the body",
      JSON.stringify(liveTool.shape),
    );
    // The clock is the browser's, not a frame a second from the server — the whole reason `tick()`
    // and `data-since` exist. Reading it again after a second is the only way to see that it moves.
    await sleep(2200);
    const tickedText = await cdp.eval(
      `(() => {
        const time = document.getElementById(${JSON.stringify(liveTool.id)}).querySelector('time');
        return time ? time.textContent : null;
      })()`,
    );
    check(
      tickedText !== null && tickedText !== liveTool.before,
      "the count moves on its own",
      `${liveTool.before} -> ${tickedText}`,
    );

    // Now the case the whole arrangement exists for: the reader reloads while the tool is running.
    //
    // A patch whose target is missing is dropped in silence (`if (!node) return`), so if the
    // snapshot could not represent a tool that has started but not reported, the tool's output
    // would never appear — after a reload, and only after a reload, with nothing on the page to
    // say so. That is why the snapshot carries the running block at all.
    //
    // The marker is what makes this a reload rather than a no-op: `readyState === 'complete'` is
    // already true before the new document starts loading, so waiting on it alone reads the *old*
    // DOM and quietly verifies nothing.
    await sleep(2200);
    await cdp.eval("window.__reloadMarker = 'old-document'");
    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor(
      "document.readyState === 'complete' && typeof window.__reloadMarker === 'undefined'",
      "a genuinely new document",
      20000,
    );
    await cdp.waitFor(
      `document.querySelectorAll('#transcript [id^=live-tool].running').length >= 1`,
      "the running tool to be in the snapshot the new page is given",
      30000,
    );
    const afterReload = await cdp.eval(`(() => {
      const block = document.getElementById(${JSON.stringify(liveTool.id)});
      const time = block ? block.querySelector('time') : null;
      return {
        id: block ? block.id : null,
        open: block ? block.hasAttribute('open') : null,
        since: time ? time.dataset.since : null,
        // Seconds of the tool's life that had already elapsed when this snapshot was rendered. If
        // the snapshot used the moment of rendering instead of the tool's own start, this would be
        // near zero — and so would the clock the reader sees, which would reset on every refresh.
        elapsedMs: time ? Date.now() - Number(time.dataset.since) : null,
      };
    })()`);
    check(
      afterReload.id === liveTool.id && afterReload.open === true,
      "a reload mid-tool still shows the tool that is running",
      JSON.stringify(afterReload),
    );
    check(
      afterReload.elapsedMs > 3000,
      "and its clock carries on from the tool's real start rather than restarting with the page",
      JSON.stringify(afterReload),
    );

    // And the same block, folded, once the tool is over. One block per tool: the earlier shape
    // appended the result beside the running block, which left the running one — timer and all —
    // sitting there for the rest of the session.
    await cdp.waitFor(
      `document.querySelectorAll('#transcript .result').length >= 1`,
      "the tool's result to arrive",
      120000,
    );
    // Watched from inside the page rather than read at the right moment from out here. The block is
    // open for about a second, and a poll over the wire races that second — on a slow run it would
    // read the folded state and call the feature broken. The observer is kept on `window`, because a
    // MutationObserver with no reference can be collected and then simply never fires.
    //
    // What is asserted is the *visible* behaviour, not which mechanism did the folding. A turn that
    // finishes within the second ends by re-rendering the whole exchange (that is what a finished
    // turn does), and that folds the block anyway; demanding that the timer be the thing that folded
    // it would be asserting an implementation detail and would fail whenever the answer came back
    // quickly.
    await cdp.eval(`(() => {
      const id = ${JSON.stringify(liveTool.id)};
      window.__settle = { resultAt: null, goneAt: null, foldedAt: null, openWithResult: false };
      const look = () => {
        const block = document.getElementById(id);
        if (!block) {
          // The block is gone from under this id: the turn ended and re-rendered the exchange, so
          // there is no longer a live tool block to fold.
          if (window.__settle.resultAt !== null && window.__settle.goneAt === null) {
            window.__settle.goneAt = Date.now();
          }
          return;
        }
        const hasResult = !!block.querySelector('.result');
        if (!hasResult) return;
        if (window.__settle.resultAt === null) window.__settle.resultAt = Date.now();
        if (block.hasAttribute('open')) window.__settle.openWithResult = true;
        else if (window.__settle.foldedAt === null) window.__settle.foldedAt = Date.now();
      };
      window.__settleObs = new MutationObserver(look);
      // On the document element, not on the transcript. A region refresh replaces the transcript
      // outright (outerHTML = ...), which detaches an observer living on it — and that observer then
      // never fires again, so the wait below times out on a page where everything actually worked.
      // Nothing replaces the document element.
      window.__settleObs.observe(document.documentElement, {
        subtree: true, childList: true, attributes: true,
      });
      look();
      return true;
    })()`);
    // Polled rather than thrown: a timeout here is not "the page crashed", it is one of the states
    // below being false, and the checks should say which. Throwing would report a bare timeout and
    // throw away everything that was recorded.
    let settleSeen = false;
    for (let i = 0; i < 120 && !settleSeen; i++) {
      settleSeen = await cdp.eval(
        `!!(window.__settle && (window.__settle.foldedAt !== null || window.__settle.goneAt !== null))`,
      );
      if (!settleSeen) await sleep(250);
    }
    const settled = await cdp.eval(`(() => {
      const id = ${JSON.stringify(liveTool.id)};
      const block = document.getElementById(id);
      const withResult = [...document.querySelectorAll('#transcript details.tool')]
        .filter((b) => b.querySelector('.result'));
      return {
        ...window.__settle,
        // Whether the block is still there at all, so a report of "never saw a result" can say
        // whether the tool is still running or the block left without one.
        stillPresent: !!document.getElementById(id),
        // Counted through the id, because "one block, reused" is the claim: a second append would
        // show up here as two elements, or as the result landing in a block of its own.
        withId: document.querySelectorAll('#transcript [id="' + id + '"]').length,
        stillRunning: document.querySelectorAll('#transcript details.running').length,
        settleAttrsLeft: document.querySelectorAll('#transcript [data-settle]').length,
        blocksWithResult: withResult.length,
        anyOpenWithResult: withResult.some((b) => b.hasAttribute('open')),
        // The last one to have reported is the one allowed to be open; anything earlier is a block
        // that should have folded and did not.
        openIsNewest:
          withResult.filter((b) => b.hasAttribute('open')).pop() === withResult[withResult.length - 1],
      };
    })()`);
    check(
      settled.openWithResult === true,
      "the result is shown as it arrives rather than arriving already folded",
      JSON.stringify(settled),
    );
    // "A moment": long enough to read a line, not a blink. Below that the block was folded on the
    // same frame it was opened, which is the failure this is here to catch.
    const shownFor =
      settled.resultAt === null ? null : (settled.foldedAt ?? settled.goneAt) - settled.resultAt;
    check(
      shownFor !== null && shownFor >= 300,
      "and it stays open long enough to be read",
      `${settled.resultAt} -> ${settled.foldedAt ?? settled.goneAt} (${shownFor}ms)`,
    );
    check(
      settled.withId <= 1,
      "one block per tool, not a running one left beside a finished one",
      JSON.stringify(settled),
    );
    check(settled.blocksWithResult >= 1, "the tool's output is in the conversation", JSON.stringify(settled));
    // A finished tool may legitimately be open for the moment its result just landed. What must not
    // happen is an *older* one still hanging open — that is a block nobody folded.
    check(
      settled.anyOpenWithResult === false || settled.openIsNewest === true,
      "and no finished tool is left hanging open behind the newest one",
      JSON.stringify(settled),
    );
    check(
      settled.settleAttrsLeft === 0 && settled.stillRunning === 0,
      "nothing is left claiming to still be running or waiting to fold",
      JSON.stringify(settled),
    );

    console.log("\nthe fold (finished tools go in, the running one stays out)");
    // The second tool starting is what puts the first away. Waited for rather than read at once: the
    // browser does the moving a moment after the frame that asks for it, so a check that ran
    // immediately would sometimes catch the block still outside and call a working feature broken.
    await cdp.waitFor(
      `(() => {
        const fold = document.querySelector('#transcript [id^=live-work]');
        const block = document.getElementById(${JSON.stringify(liveTool.id)});
        return !!(fold && block && fold.contains(block));
      })()`,
      "the finished tool to be put away in the fold",
      120000,
    );
    const filed = await cdp.eval(`(() => {
      const fold = document.querySelector('#transcript [id^=live-work]');
      const root = document.querySelector('#transcript [id^=streams-]');
      return {
        label: fold.querySelector('summary').textContent,
        foldOpen: fold.hasAttribute('open'),
        inside: [...fold.querySelectorAll('details.tool')].map((b) => b.id),
        // What is left at the top level of the stream: the fold, and whatever has not been put in it.
        outside: [...root.children].map((c) => c.id + (c.classList.contains('running') ? ':running' : '')),
        outsideTools: root.querySelectorAll(':scope > details.tool').length,
        runningOutside: root.querySelectorAll(':scope > details.tool.running').length,
        // Everything the model said, inside the fold. Should be empty: the fold holds tool blocks.
        awayInside: fold.querySelectorAll('div.thinking, div.text').length,
        thinkingOutside: root.querySelectorAll(':scope > div.thinking').length,
      };
    })()`);
    check(
      filed.inside.includes(liveTool.id),
      "the tool that finished first is inside the fold",
      JSON.stringify(filed),
    );
    check(
      filed.label.includes("worked through 1 tool call"),
      "and the fold says how many tools are in it",
      JSON.stringify(filed.label),
    );
    check(
      filed.outsideTools <= 1,
      "no more than one tool block is left outside the fold",
      JSON.stringify(filed),
    );
    // What the fold must never swallow: the model explaining itself. A result is something the
    // reader asked for once and is done with; reasoning and the prose between tool calls have no
    // other home, so putting them away would leave a page showing nothing but a clock.
    check(
      filed.awayInside === 0,
      "and nothing the model said is put away with the tools",
      JSON.stringify(filed),
    );
    // Nothing the reader has to keep open: the fold is a summary, and a summary that is already
    // unfolded is just the page being tall again.
    check(filed.foldOpen === false, "the fold itself is closed", JSON.stringify(filed));
    await cdp.waitFor(
      `!/working…/.test(document.getElementById('status').textContent)`,
      "the tool turn to finish before the next section",
      120000,
    );

    console.log("\nsidebar (a new session, then going back to the old one)");
    const rowsBefore = await cdp.eval(
      "document.querySelectorAll('#sessions [data-session]').length",
    );
    check(
      (await cdp.eval("document.querySelectorAll('#sessions [data-new]').length")) === 1,
      "the open workspace offers a new session",
    );
    await cdp.eval(`document.querySelector('[data-new]').click()`);
    await cdp.waitFor(
      `document.querySelectorAll('#transcript .exchange').length === 0`,
      "a new session to clear the transcript",
      30000,
    );
    const rowsAfter = await cdp.eval(
      "document.querySelectorAll('#sessions [data-session]').length",
    );
    check(
      rowsAfter === rowsBefore,
      "a new session adds no sidebar row until it has something in it",
      `rows went from ${rowsBefore} to ${rowsAfter}: ${await cdp.eval(
        "JSON.stringify([...document.querySelectorAll('#sessions [data-session]')].map(r => r.textContent))",
      )}`,
    );
    // Which is the point of writing the file on the first entry: a store used for a
    // week should not be a list of sessions nobody ever typed into.
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = ${JSON.stringify("Reply with exactly: second-ok")};
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelectorAll('#sessions [data-session]').length === ${rowsBefore + 1}`,
      "the session to appear once it has a message",
      60000,
    );
    check(true, "the session shows up in the sidebar once it has content");
    const back = await cdp.eval(
      `(() => {
        const rows = [...document.querySelectorAll('#sessions [data-session]')];
        const row = rows.find(r => r.textContent.includes('browser-ok'));
        if (!row) return null;
        row.click();
        return row.dataset.session;
      })()`,
    );
    check(!!back, "the earlier session is listed by its first prompt", back ?? "not found");
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes(${JSON.stringify(prompt)})`,
      "clicking a row to bring the conversation back",
      30000,
    );
    check(true, "clicking a sidebar row opens that session");

    console.log("\nsession rows (one line each, with the actions under the pointer)");
    // Two rows with content, so "the current one" and "the others" are different rows.
    await cdp.waitFor(
      "document.querySelectorAll('#sessions li.session').length >= 2",
      "two session rows",
      30000,
    );
    const rows = await cdp.eval(`(() => {
      const list = [...document.querySelectorAll('#sessions li.session')];
      const box = (el) => { const r = el.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height) }; };
      const style = (el, p) => getComputedStyle(el).getPropertyValue(p);
      const current = list.filter(r => r.classList.contains('current'));
      return JSON.stringify({
        count: list.length,
        heights: [...new Set(list.map(r => Math.round(r.getBoundingClientRect().height)))],
        labels: list.map(r => r.querySelector('.label').textContent),
        ages: list.map(r => r.querySelector('.age').textContent),
        order: list.map(r => [...r.querySelector('.open').children].map(c => c.className)),
        // The two quiet controls, which is what the row offers without a hover.
        actsDisplay: list.map(r => style(r.querySelector('.acts'), 'display')),
        acts: [...document.querySelectorAll('#sessions .acts')].map(a =>
          [...a.children].map(b => ({ glyph: b.textContent, name: b.getAttribute('aria-label'), tag: b.dataset.rename !== undefined ? 'rename' : 'delete' }))),
        currentCount: current.length,
        currentFill: current[0] ? style(current[0], 'background-color') : null,
        plainFill: list.find(r => !r.classList.contains('current')) ? style(list.find(r => !r.classList.contains('current')), 'background-color') : null,
        // The bar is a pseudo-element, so it is invisible to every query but a computed style
        // asked for that pseudo-element.
        currentBar: current[0] ? getComputedStyle(current[0], '::before').width : null,
        plainBar: list.find(r => !r.classList.contains('current')) ? getComputedStyle(list.find(r => !r.classList.contains('current')), '::before').content : null,
        currentWeight: current[0] ? style(current[0].querySelector('.label'), 'font-weight') : null,
        labelWeight: list.find(r => !r.classList.contains('current')) ? style(list.find(r => !r.classList.contains('current')).querySelector('.label'), 'font-weight') : null,
        rowBox: (() => { const r = list.find(x => !x.classList.contains('current')).getBoundingClientRect(); return { x: Math.round(r.x + 30), y: Math.round(r.y + r.height / 2) }; })(),
      });
    })()`);
    const rowState = JSON.parse(rows);
    check(
      rowState.heights.length === 1 && rowState.heights[0] <= 34,
      "a session is one line, whatever it is called",
      JSON.stringify({ heights: rowState.heights, labels: rowState.labels }),
    );
    check(
      rowState.order.every((kids) => kids.includes('label') && kids.includes('age')),
      "the row is the label and the age, in that order",
      JSON.stringify(rowState.order),
    );
    check(
      rowState.ages.every((age) => /(now|\d+[mhd] ago)$/.test(age)),
      "every row says how long ago it was, in one unit",
      JSON.stringify(rowState.ages),
    );
    check(
      rowState.actsDisplay.every((d) => d === 'none'),
      "the rename and delete controls are out of the way until they are needed",
      JSON.stringify(rowState.actsDisplay),
    );
    check(
      rowState.acts.every((pair) => pair.every((b) => (b.name ?? '').length > 0)),
      "and each of them is named for the row it acts on, not just 'delete'",
      JSON.stringify(rowState.acts),
    );
    check(
      rowState.currentCount === 1 && rowState.currentFill !== rowState.plainFill,
      "the open session is the filled row",
      JSON.stringify(rowState),
    );
    check(
      rowState.currentBar === '2px' && rowState.plainBar !== '""',
      "with an accent bar beside it, which the others do not have",
      JSON.stringify({ currentBar: rowState.currentBar, plainBar: rowState.plainBar }),
    );
    check(
      rowState.currentWeight === '600' && rowState.labelWeight === '400',
      "and a heavier name",
      JSON.stringify({ currentWeight: rowState.currentWeight, labelWeight: rowState.labelWeight }),
    );

    await cdp.moveMouse(rowState.rowBox.x, rowState.rowBox.y);
    const hovered = JSON.parse(await cdp.eval(`(() => {
      const r = [...document.querySelectorAll('#sessions li.session')].find(x => !x.classList.contains('current'));
      return JSON.stringify({
        acts: getComputedStyle(r.querySelector('.acts')).display,
        age: getComputedStyle(r.querySelector('.age')).display,
        fill: getComputedStyle(r).backgroundColor,
      });
    })()`));
    check(
      hovered.acts === 'flex' && hovered.age === 'none',
      "hovering a row swaps the age for the actions, in the same place",
      JSON.stringify(hovered),
    );
    check(
      hovered.fill !== rowState.plainFill,
      "and the row being pointed at is filled",
      JSON.stringify({ hovered: hovered.fill, resting: rowState.plainFill }),
    );

    // Away from the list, then the keyboard's own route in: the actions must be laid out before
    // Tab looks for them, or they are unreachable without a mouse.
    await cdp.moveMouse(5, 5);
    const focused = JSON.parse(await cdp.eval(`(() => {
      const r = [...document.querySelectorAll('#sessions li.session')].find(x => !x.classList.contains('current'));
      r.querySelector('.open').focus();
      return JSON.stringify({
        acts: getComputedStyle(r.querySelector('.acts')).display,
        age: getComputedStyle(r.querySelector('.age')).display,
        outline: getComputedStyle(r.querySelector('.open')).outlineWidth,
        focused: document.activeElement === r.querySelector('.open'),
      });
    })()`));
    check(
      focused.focused && focused.acts === 'flex' && focused.age === 'none',
      "and focusing a row with the keyboard reveals them too",
      JSON.stringify(focused),
    );
    check(
      focused.outline !== '0px',
      "with a focus ring that is visible against the row it is on",
      JSON.stringify(focused),
    );

    console.log("\nworkspaces (a session from another directory)");
    // Seed a second workspace the server has never seen: its own directory and a
    // session file that says where the agent should work.
    // A sibling of the store, so the temporary directory that holds it is removed
    // with the rest.
    // Deliberately long: the sidebar has to ellipsise a workspace name rather than
    // overflow or push the transcript around.
    const otherCwd = `${store}-another-project-with-a-long-name`;
    mkdirSync(otherCwd, { recursive: true });
    writeFileSync(join(otherCwd, "marker-b.txt"), "MARKER-B-7f3a2c\n");
    // The encoding is a copy of the server's; check it against the directory the
    // server created for its own cwd, so a drift in either copy fails here.
    const ownDir = join(store, storeDirName(process.cwd()));
    check(
      existsSync(ownDir),
      "the store directory rule still matches the server's",
      `${ownDir} does not exist`,
    );
    const otherDir = join(store, storeDirName(otherCwd));
    mkdirSync(otherDir, { recursive: true });
    // Deliberately long: the scroll position is only observable on a conversation taller than the
    // window, and the reader's complaint was about exactly those.
    // Eleven sessions beside it, so this workspace holds twelve against a list that shows ten.
    // Written *before* the long one because the order is by mtime: the file a check is about has to
    // be the newest, or it is the one the cap hides and every check below is about a row that is
    // not on the page.
    for (let i = 0; i < 11; i++) {
      const older = sessionFile(otherCwd, `an older conversation ${i}`, 1);
      const at = `2019-01-${String(i + 1).padStart(2, "0")}T00-00-00.000Z`;
      writeFileSync(join(otherDir, `${at}_${older.id}.jsonl`), older.text);
    }
    const seeded = sessionFile(otherCwd, "seeded question from the other project", 24);
    writeFileSync(join(otherDir, `2020-01-01T00-00-00.000Z_${seeded.id}.jsonl`), seeded.text);

    // A reload, because the sidebar is only re-rendered on connect, on a switch and
    // after a turn — there is no polling, by design.
    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor("document.readyState === 'complete'", "page reload", 20000);
    await sleep(1500);
    check(
      (await cdp.eval("document.querySelectorAll('#sessions details.workspace').length")) === 2,
      "both workspaces are listed",
    );
    check(
      (await cdp.eval(
        `(() => {
          const open = document.querySelectorAll('#sessions details.workspace[open]');
          return open.length === 1 && open[0].querySelector('summary').title === ${JSON.stringify(process.cwd())};
        })()`,
      )) === true,
      "only the workspace being worked in is open",
    );

    // The workspace name is longer than the column. It has to be ellipsised, and it has to be the
    // *name* that gives: a `summary` is a list item, and text overflow only applies to the box the
    // text is in.
    const longName = JSON.parse(await cdp.eval(`(() => {
      const names = [...document.querySelectorAll('#sessions summary .name')];
      const name = names.find(n => n.textContent.length > 30);
      if (!name) return JSON.stringify({ found: false, names: names.map(n => n.textContent) });
      const sidebar = document.querySelector('.sidebar').getBoundingClientRect();
      const row = name.closest('summary').getBoundingClientRect();
      return JSON.stringify({
        found: true,
        clipped: name.scrollWidth > name.clientWidth,
        insideColumn: Math.round(row.right) <= Math.round(sidebar.right) + 1,
        sidebarWidth: Math.round(sidebar.width),
      });
    })()`));
    check(
      longName.found && longName.clipped && longName.insideColumn,
      "a workspace name too long for the column is ellipsised rather than pushing it wider",
      JSON.stringify(longName),
    );

    const switched = await cdp.eval(
      `(() => {
        const row = [...document.querySelectorAll('#sessions [data-session]')]
          .find(r => r.textContent.includes('other project'));
        if (!row) return null;
        row.click();
        return row.dataset.session;
      })()`,
    );
    check(!!switched, "the seeded session is listed under its own workspace", switched ?? "not found");
    // The status line no longer repeats the working directory — it is the first thing on the
    // workspace row, and a temp path with a hash in it was most of the line. What says the agent
    // moved is the transcript becoming that session, and the transcript says which session it is
    // showing in its own tag. Asserting on the conversation's *text* stopped working when long
    // sessions became a window over their newest turns: the seeded session's first question is
    // deliberately no longer rendered.
    await cdp.waitFor(
      `document.getElementById('transcript').dataset.shownSession === ${JSON.stringify(tagOf(switched))}`,
      "the agent to move into the other workspace",
      30000,
    );
    check(
      !/in \//.test(await cdp.eval("document.getElementById('status').textContent")),
      "the status line names what was opened, not where it lives",
      await cdp.eval("document.getElementById('status').textContent"),
    );
    check(
      (await cdp.eval(
        `(() => {
          const open = document.querySelectorAll('#sessions details.workspace[open]');
          return open.length === 1 && open[0].querySelector('summary').title === ${JSON.stringify(otherCwd)};
        })()`,
      )) === true,
      "the other workspace is the active one now",
    );

    // Opening a session lands at its end. Landing at the top of a long conversation means scrolling
    // past all of it before reading anything, which is what the reader complained about.
    const atBottom = async () =>
      await cdp.eval(
        "window.innerHeight + window.scrollY >= document.body.offsetHeight - 40",
      );
    check(await atBottom(), "opening a session lands at the newest content");
    check(
      (await cdp.eval("document.body.offsetHeight")) > (await cdp.eval("window.innerHeight")),
      "and the seeded session is long enough for that to mean something",
    );

    // A page load does the same: the first thing rendered is the end of the conversation.
    await cdp.eval("window.scrollTo(0, 0)");
    check(!(await atBottom()), "the check can scroll away from the bottom");
    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor("document.readyState === 'complete'", "page reload", 20000);
    await sleep(1500);
    await cdp.waitFor(
      `document.getElementById('transcript').dataset.shownSession === ${JSON.stringify(tagOf(switched))}`,
      "the long session to be on screen after the reload",
      20000,
    );
    check(await atBottom(), "a fresh page load lands at the newest content too");
    check(
      (await cdp.eval("document.querySelectorAll('#sessions .session.current').length")) === 1,
      "exactly one session is marked current",
    );

    // The cap, and the way past it. Twelve sessions in this workspace against a list that shows
    // ten, so two of them are reachable only through the offer.
    const capped = await cdp.eval(`(() => {
      const rows = [...document.querySelectorAll('#sessions details.workspace[open] li.session')];
      const more = document.querySelector('#sessions details.workspace[open] [data-more]');
      return JSON.stringify({
        rows: rows.length,
        label: more ? more.textContent : null,
        named: more ? more.getAttribute('aria-label') : null,
        // Nothing is dropped silently: the offer names the workspace it belongs to, because a
        // column of them would otherwise be a stack of identical buttons.
        above: more ? rows.includes(more.previousElementSibling.querySelector('li')) : null,
        lastInList: more ? more.previousElementSibling === rows[rows.length - 1].parentElement : null,
      });
    })()`);
    const capState = JSON.parse(capped);
    check(
      capState.rows === 10 && capState.label === 'Show 2 more',
      "a workspace that holds more sessions than the list shows offers the rest",
      JSON.stringify(capState),
    );
    check(
      /show 2 more sessions in /.test(capState.named ?? ''),
      "and says which workspace the rest are in",
      JSON.stringify(capState),
    );
    await cdp.eval("document.querySelector('#sessions details.workspace[open] [data-more]').click()");
    await cdp.waitFor(
      `document.querySelectorAll('#sessions details.workspace[open] li.session').length === 12`,
      "the rest of the workspace's sessions to arrive",
      20000,
    );
    check(true, "clicking it lists them, so nothing in the store is out of reach");
    check(
      (await cdp.eval("document.querySelectorAll('#sessions [data-more]').length")) === 0,
      "and the offer goes away once there is nothing left to offer",
    );

    // The point of a workspace: the tools run there. A relative path only resolves
    // if the read tool was given the new directory.
    const markerPrompt = "Use the read tool on marker-b.txt and reply with its contents.";
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = ${JSON.stringify(markerPrompt)};
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes('MARKER-B-7f3a2c')`,
      "the tool to read the file from the new workspace",
      120000,
    );
    check(true, "tools run in the workspace that was opened");

    console.log("\nreconnect (the server is restarted under the page)");
    server.kill("SIGKILL");
    await sleep(1500);
    server = startServer(store, home);
    await waitForServer();
    // EventSource backs off before retrying, so give the reconnection time to be
    // attempted and answered.
    await sleep(4000);
    check(
      (await cdp.eval("document.querySelectorAll('#transcript').length")) === 1 &&
        (await cdp.eval("document.querySelectorAll('#composer').length")) === 1,
      "the reconnected page still has exactly one of each region",
    );
    // The restarted process has no memory of which session was open, so it starts a
    // new one — that is the documented behaviour, not a failure. What matters is
    // that the page converges on it rather than keeping stale state.
    const statusAfter = await cdp.eval("document.getElementById('status').textContent");
    check(
      !/model call/.test(statusAfter),
      "the status line no longer advertises the pre-restart turn",
      statusAfter,
    );
    // Not `innerHTML.length === 0`: a fresh session now shows the welcome, which is what tells a
    // reader what the page is for. The requirement is that the *conversation* is gone — no exchange
    // left over from before the restart — and that what replaced it is the empty state.
    const afterRestart = await cdp.eval(`(() => {
      const t = document.getElementById('transcript');
      return {
        exchanges: t.querySelectorAll('.exchange').length,
        welcome: !!t.querySelector('.welcome'),
      };
    })()`);
    check(
      afterRestart.exchanges === 0 && afterRestart.welcome,
      "the page shows the new session the restarted server opened",
      JSON.stringify(afterRestart),
    );
    // The conversation is not lost: it is on disk, listed, and one click away.
    const restored = await cdp.eval(
      `(() => {
        const rows = [...document.querySelectorAll('#sessions [data-session]')];
        const row = rows.find(r => r.textContent.includes('browser-ok'));
        if (!row) return null;
        row.click();
        return row.dataset.session;
      })()`,
    );
    check(!!restored, "the conversation is still listed after the restart", restored ?? "not found");
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes(${JSON.stringify(prompt)})`,
      "the conversation to come back from the sidebar",
      30000,
    );
    check(true, "one click restores it");

    console.log("\nparallel turns (switching away must not stop anything)");
    // Two sessions, both with content, so each is identifiable by its first message.
    const openSession = async (label) =>
      await cdp.eval(
        `(() => {
          const row = [...document.querySelectorAll('#sessions [data-session]')]
            .find(r => r.textContent.includes(${JSON.stringify(label)}));
          if (!row) return null;
          row.click();
          return row.dataset.session;
        })()`,
      );
    const counter = async () => {
      const text = await cdp.eval("document.getElementById('status').textContent");
      const match = /(\d+) model call/.exec(text);
      return match ? Number(match[1]) : null;
    };

    // A prompt that keeps the model busy for minutes: the point is that the rest of the
    // checks can happen while it runs.
    const longPrompt =
      "Read every file in core/, then every file in html/, then every file in platform/, and summarise each in one sentence.";
    check(!!(await openSession("browser-ok")), "the first session is displayed");
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = ${JSON.stringify(longPrompt)};
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `/working….+tool call\\(s\\)/.test(document.getElementById('status').textContent)`,
      "the long turn to get under way",
      90000,
    );
    const before = await counter();
    check(before !== null && before >= 1, "the turn reports progress while it runs", `counter=${before}`);
    // The picker locks for the duration: a model change would append an entry off the running
    // turn's own leaf, which forks the log onto a branch nobody walks. The server refuses it too;
    // this is what stops the reader trying, and it has to come from a refresh, not from a reload.
    check(
      (await cdp.eval("document.getElementById('model-picker').disabled")) === true,
      "the model picker is locked while a turn runs",
    );

    // Away: the other session. Nothing about the running one may show up here.
    check(!!(await openSession("second-ok")), "the second session can be opened");
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes('second-ok')`,
      "the second session's own transcript",
      30000,
    );
    check(
      (await cdp.eval("document.querySelectorAll('#transcript [id^=live-tool]').length")) === 0,
      "no output from the hidden session leaked into the visible one",
    );
    check(
      (await cdp.eval("document.querySelectorAll('#sessions .dot').length")) >= 1,
      "the sidebar marks the session that is still working",
    );
    const shownStatus = await cdp.eval("document.getElementById('status').textContent");
    check(
      !/working… \d+ model call/.test(shownStatus),
      "the hidden turn's progress stays off the visible status line",
      shownStatus,
    );

    // Let it work while nobody is watching, then come back and see that it did.
    //
    // The model-call counter only moves when a *model call* completes, and one round is a model
    // call followed by however many tool calls it asked for. Reading every file in a directory is
    // a round with a lot of tool calls in it, so the gap between two model calls is not bounded by
    // anything this test can assume — a fixed sleep here was about one run in three short, which
    // made the whole check fail for a reason that had nothing to do with what it asserts.
    //
    // So the away time is spent working rather than waiting: come back and poll until either the
    // counter has moved or the turn has ended, both of which prove the turn kept going while
    // another session was on screen.
    await sleep(9000);
    check(!!(await openSession("browser-ok")), "the working session can be opened again");
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes(${JSON.stringify(longPrompt)})`,
      "the running exchange to be back on screen",
      30000,
    );
    const progressed = async () => {
      const now = await counter();
      // `null` means the status line no longer reports a running turn, which is the turn having
      // finished — proof of progress by itself.
      if (now === null) return "finished";
      return now > before ? "advanced" : null;
    };
    let outcome = null;
    const deadline = Date.now() + 45000;
    while (Date.now() < deadline && outcome === null) {
      outcome = await progressed();
      if (outcome === null) await sleep(500);
    }
    if (outcome === "finished") {
      const exchanges = await cdp.eval(
        "document.querySelectorAll('#transcript .exchange').length",
      );
      check(exchanges >= 2, "the turn completed while hidden");
    } else {
      check(
        outcome === "advanced",
        "the turn made progress while another session was displayed",
        `before=${before} after=${await counter()}`,
      );
    }
    check(
      (await cdp.eval("document.querySelectorAll('#transcript [id^=live-tool]').length")) >= 1 ||
        (await cdp.eval("document.querySelectorAll('#transcript .result').length")) >= 1,
      "the work done out of sight is on screen when the session comes back",
    );

    console.log("\nstopping a background turn from the panel");
    // The parallel section left a long turn running in the session it opened last.
    check(
      (await cdp.eval("document.querySelectorAll('#tasks .task').length")) >= 1,
      "the running turn is listed in the tasks panel",
    );
    check(
      /running |waiting for the model/.test(
        await cdp.eval("document.querySelector('#tasks .task .tool').textContent"),
      ),
      "the panel says what it is doing",
      await cdp.eval("document.querySelector('#tasks .task .tool').textContent"),
    );
    check(
      (await cdp.eval("document.querySelectorAll('#tasks [data-stop]').length")) >= 1,
      "the panel offers a way to stop it",
    );
    check(
      (await cdp.eval("document.querySelectorAll('#tasks [data-since]').length")) >= 1,
      "and how long it has been running",
    );
    const taskSession = await cdp.eval(
      "document.querySelector('#tasks [data-stop]').dataset.stop",
    );
    const beforeStop = await cdp.eval("document.getElementById('transcript').innerHTML.length");
    await cdp.eval("document.querySelector('#tasks [data-stop]').click()");
    await cdp.waitFor(
      `document.querySelectorAll('#tasks .task').length === 0`,
      "the stopped turn to leave the panel",
      30000,
    );
    check(true, "clicking Stop ends the background turn");
    check(
      (await cdp.eval("document.querySelectorAll('#sessions .dot').length")) === 0,
      "and the sidebar stops marking it as running",
    );
    check(
      (await cdp.eval("document.getElementById('transcript').innerHTML.length")) >= beforeStop,
      "the work it had already done is still on screen",
    );
    // Stopping one session must not touch another.
    check(
      !!(await openSession("second-ok")),
      "the other session is still there",
    );
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes('second-ok')`,
      "and still shows its own conversation",
      30000,
    );
    check(true, "stopping one session leaves the others alone");
    // And the picker is usable again, which is the other half of the lock: a refresh that only
    // ever disabled it would leave the reader unable to change the model at all.
    await cdp.waitFor(
      `document.getElementById('model-picker').disabled === false`,
      "the picker to unlock once the turn is over",
      30000,
    );
    check(true, "the model picker unlocks when the turn ends");
    void taskSession;

    console.log("\nnaming a session");
    // The name is an entry in the session log, so it has to be visible in both places the reader
    // looks, and it has to still be there after a reload — a name that only lives in the page would
    // be worse than no name.
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = "/name the browser check session";
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('title').textContent.includes('the browser check session')`,
      "the title to show the name",
      15000,
    );
    check(true, "the title names the session");
    // A bare /name reports rather than clearing.
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = "/name";
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('status').textContent.includes('name: the browser check session')`,
      "a bare /name to report the current name",
      15000,
    );
    check(true, "a bare /name reports instead of clearing");
    // Not a command: it must reach the model as a message rather than being eaten.
    check(
      (await cdp.eval(
        `document.getElementById('transcript').textContent.includes('the browser check session')`,
      )) === false,
      "the command itself is not shown as a message",
    );

    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor("document.readyState === 'complete'", "page reload", 20000);
    await sleep(1500);
    await cdp.waitFor(
      `document.getElementById('title').textContent.includes('the browser check session')`,
      "the name to survive a reload",
      20000,
    );
    check(true, "the name comes back after a reload, because it is in the log");
    check(
      (await cdp.eval(
        `[...document.querySelectorAll('#sessions [data-session]')]
           .some(r => r.textContent.includes('the browser check session'))`,
      )) === true,
      "and the sidebar lists the session by that name",
    );

    console.log("\nbackground jobs (work that outlives its tool call)");
    // A command that returns immediately and leaves a process behind: the case that gets
    // forgotten, and the one this whole panel exists for.
    await cdp.eval(
      `(() => {
        const input = document.getElementById('prompt');
        input.value = "Run this bash command exactly with the bash tool: /bin/sleep 300 & echo started. Do not wait for it, do not kill it.";
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelectorAll('#jobs .task').length >= 1`,
      "the background process to be listed",
      120000,
    );
    const jobText = await cdp.eval("document.getElementById('jobs').textContent");
    check(/running/.test(jobText), "the job is listed as running", jobText);
    check(
      (await cdp.eval("document.querySelectorAll('#jobs [data-kill]').length")) >= 1,
      "the job offers a way to stop it",
    );
    // The pids shown are the ones to check: a panel that says it killed something has to be
    // right about it.
    backgroundPids = (jobText.match(/(\d+)/g) ?? []).map(Number).filter((n) => n > 1000);
    const aliveBefore = backgroundPids.filter((pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    });
    check(
      aliveBefore.length >= 1,
      "the listed pids are real processes",
      `pids=${backgroundPids.join(",")}`,
    );

    await cdp.eval("document.querySelector('#jobs [data-kill]').click()");
    await cdp.waitFor(
      `document.querySelectorAll('#jobs [data-kill]').length === 0`,
      "the job to stop being listed as live",
      30000,
    );
    check(true, "killing it from the panel settles the job");
    await sleep(500);
    const aliveAfter = backgroundPids.filter((pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    });
    check(
      aliveAfter.length === 0,
      "and the processes are actually gone",
      `still alive: ${aliveAfter.join(",")}`,
    );
    backgroundPids = [];

    console.log("\nclicking inside the conversation");
    // A click in the transcript must not switch sessions. `[data-session]` means "open that" to the
    // sidebar's delegated handler, and it used to be on the transcript as well — so opening a block
    // (or just selecting text) asked the server to switch to the short id in that attribute, which
    // names no file: the server started a *new* session and the transcript went empty under the
    // reader.
    await cdp.waitFor(
      `document.querySelectorAll('#transcript details').length >= 1`,
      "a block to click in the transcript",
      60000,
    );
    const shownBefore = await cdp.eval(
      "document.getElementById('transcript').dataset.shownSession",
    );
    const sessionsBefore = await cdp.eval(
      "document.querySelectorAll('#sessions [data-session]').length",
    );
    const opened = await cdp.eval(
      `(() => {
        const details = document.querySelector('#transcript details');
        details.querySelector('summary').click();
        return { open: details.open, text: details.textContent.trim().length };
      })()`,
    );
    check(opened.open === true, "clicking a summary opens it");
    check(opened.text > 0, "and there is something inside", JSON.stringify(opened));
    await sleep(1200);
    check(
      (await cdp.eval("document.getElementById('transcript').dataset.shownSession")) ===
        shownBefore,
      "the click did not switch sessions",
    );
    check(
      (await cdp.eval("document.querySelectorAll('#sessions [data-session]').length")) ===
        sessionsBefore,
      "and no session was created by it",
    );

    console.log("\nworkspaces (adding a directory)");
    // A project directory the server has never seen, with nothing in it.
    const fresh = `${store}-added-project`;
    mkdirSync(fresh, { recursive: true });
    // The server canonicalises what it is given, so the workspace it lists is the resolved path:
    // on macOS that turns `/var/...` into `/private/var/...`.
    const freshCanonical = realpathSync(fresh);
    writeFileSync(join(fresh, "README.md"), "# added by the browser check\n");
    check(
      (await cdp.eval("document.querySelectorAll('#add-workspace').length")) === 1,
      "the sidebar offers a way to add a workspace",
    );
    // This run is `--no-picker`, so the row is the path field and only the path field. A host with
    // a dialog is covered by the unit tests; the dialog itself cannot be driven from here, because
    // it is a real OS window on the machine running the server.
    const pick = await cdp.eval(`(() => {
      const button = document.getElementById('workspace-pick');
      if (button) return 'offered';
      return document.getElementById('workspace-path') ? 'absent' : 'neither';
    })()`);
    check(
      pick === 'absent',
      "with no chooser the row is the path field, and not both at once",
      pick,
    );
    // A path that is not a directory is refused by name, not silently ignored.
    await cdp.eval(
      `(() => {
        document.getElementById('workspace-path').value = ${JSON.stringify(`${fresh}/nope`)}; 
        document.getElementById('add-workspace').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('status').textContent.includes('not a directory')`,
      "an unusable path to be reported",
      15000,
    );
    check(true, "a path that is not a directory says so");

    await cdp.eval(
      `(() => {
        document.getElementById('workspace-path').value = ${JSON.stringify(fresh)};
        document.getElementById('add-workspace').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `[...document.querySelectorAll('#sessions details.workspace')]
         .some(d => d.querySelector('summary').title === ${JSON.stringify(freshCanonical)})`,
      "the added workspace to be listed",
      30000,
    );
    check(true, "adding a workspace lists it");
    check(
      (await cdp.eval(
        `(() => {
          const open = [...document.querySelectorAll('#sessions details.workspace[open]')];
          return open.length === 1 && open[0].querySelector('summary').title === ${JSON.stringify(freshCanonical)};
        })()`,
      )) === true,
      "and opens it, so there is somewhere to type",
    );
    // Adding means working there: the agent's tools have to move too, which the title's tooltip
    // shows — the workspace a session works in is part of what names it.
    const addedTitle = await cdp.eval("document.querySelector('#title .name').title");
    check(
      addedTitle.includes(freshCanonical),
      "the display moved into the added workspace",
      addedTitle,
    );

    // Adding a second one proves the first add left the row working: the sidebar is replaced
    // whenever it refreshes, and a listener attached to the old form would be gone with it.
    const second = `${store}-added-second`;
    mkdirSync(second, { recursive: true });
    const secondCanonical = realpathSync(second);
    // Instructions of its own, written before the workspace is added so the panel the add renders
    // already has them. What the block does with this file is checked below.
    writeFileSync(
      join(second, "AGENTS.md"),
      "# browser check instructions\n\nOnly for this workspace.\n",
    );
    await cdp.eval(
      `(() => {
        document.getElementById('workspace-path').value = ${JSON.stringify(second)};
        document.getElementById('add-workspace').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `[...document.querySelectorAll('#sessions details.workspace')]
         .some(d => d.querySelector('summary').title === ${JSON.stringify(secondCanonical)})`,
      "a second workspace to be added",
      30000,
    );
    check(true, "the add row keeps working after the sidebar is replaced");
    check(
      (await cdp.eval("document.querySelectorAll('#sessions details.workspace').length")) >= 3,
      "all of the workspaces are listed",
    );
    // The workspace is written down, so a restarted server still knows it.
    check(
      existsSync(join(store, storeDirName(freshCanonical), "workspace.json")),
      "the added workspace is remembered in the store",
    );

    console.log("\nsettings (a modal, its navigation, its live facts and its one editable list)");
    // The control is a button, not a `<details>`: a modal is opened by script, and the browser
    // owns the ways out from there.
    check(
      (await cdp.eval("document.querySelectorAll('#settings').length")) === 1 &&
        (await cdp.eval("document.querySelectorAll('#settings-open').length")) === 1,
      "the settings dialog and its control are on the page exactly once",
    );
    check(
      (await cdp.eval("document.getElementById('settings').open === false")),
      "the dialog starts closed: a modal takes the whole surface, so it is asked for",
    );
    // The control is pinned to the corner and, crucially, outside every region a refresh replaces
    // and outside the sidebar's mobile fold — it is the only way in.
    const control = JSON.parse(
      await cdp.eval(
        `JSON.stringify((() => {
          const box = document.getElementById('settings-open').getBoundingClientRect();
          return { position: getComputedStyle(document.getElementById('settings-open')).position,
                   left: box.left, bottom: box.bottom, width: window.innerWidth, height: window.innerHeight };
        })())`,
      ),
    );
    check(control.position === "fixed", "the control is pinned", JSON.stringify(control));
    check(
      control.left >= 0 && control.left < control.width / 2 && control.height - control.bottom < 200,
      "the control sits in the bottom-left corner",
      JSON.stringify(control),
    );
    // Opening it: a real click on the real control, because the whole point is that the dialog is
    // opened by a listener rather than declaratively.
    await cdp.eval("document.getElementById('settings-open').click()");
    await cdp.waitFor("document.getElementById('settings').open === true", "the dialog to open", 5000);
    check(true, "clicking the control opens the dialog");
    // A modal, not a box: `showModal` is what puts it in the top layer and gives it focus trapping,
    // `Esc` and the backdrop. `open` alone would be true for a plain `<div>` too.
    check(
      (await cdp.eval("document.getElementById('settings').matches(':modal')")),
      "the dialog is modal, so the browser owns Esc and the backdrop",
    );
    const dialog = JSON.parse(
      await cdp.eval(
        `JSON.stringify((() => {
          const box = document.getElementById('settings').getBoundingClientRect();
          return { left: box.left, right: box.right, top: box.top, bottom: box.bottom,
                   width: window.innerWidth, height: window.innerHeight,
                   w: box.width, h: box.height };
        })())`,
      ),
    );
    check(
      dialog.left > 0 && dialog.right < dialog.width && dialog.top > 0 && dialog.bottom < dialog.height,
      "the dialog is centred, with an edge of the page still visible around it",
      JSON.stringify(dialog),
    );
    // Wider than the sidebar column it used to live in, and that was the point of the change.
    check(
      dialog.w > 640 && dialog.h > 400,
      "the dialog is substantially larger than the old anchored box",
      JSON.stringify(dialog),
    );
    // The navigation: one item per section, every one of which scrolls to a section that exists.
    const navCount = await cdp.eval("document.querySelectorAll('.settings-nav-item').length");
    const sectionCount = await cdp.eval(
      "document.querySelectorAll('#settings-body .settings-section').length",
    );
    check(
      navCount === sectionCount && navCount >= 4,
      "every section has a navigation anchor and every anchor has a section",
      `${navCount} nav / ${sectionCount} sections`,
    );
    // Clicking an anchor scrolls the body to that section and marks only that one.
    await cdp.eval(
      `(() => {
        const items = [...document.querySelectorAll('.settings-nav-item')];
        items[items.length - 1].click();
        return true;
      })()`,
    );
    await new Promise((r) => setTimeout(r, 600));
    const navState = JSON.parse(
      await cdp.eval(
        `JSON.stringify((() => {
          const body = document.getElementById('settings-body');
          const last = [...document.querySelectorAll('.settings-section')].pop();
          const marked = [...document.querySelectorAll('.settings-nav-item')]
            .filter(b => b.getAttribute('aria-current') === 'true')
            .map(b => b.dataset.section);
          return { scrollTop: body.scrollTop, markCount: marked.length, marked,
                   lastId: last.id, lastTop: last.offsetTop };
        })())`,
      ),
    );
    check(navState.scrollTop > 0, "clicking an anchor scrolls to the section", JSON.stringify(navState));
    check(
      navState.markCount === 1,
      "exactly one navigation item is marked current",
      JSON.stringify(navState),
    );
    // The mark has to be at the end of the list, not the start: the body cannot scroll far enough
    // to bring the last section's top to the top edge, so the deepest section in view is the last
    // one. A wrong-order navigation would mark something earlier, which is what this catches.
    check(
      navState.marked[0] === navState.lastId,
      "the marked item is the deepest section, which is where that click lands",
      JSON.stringify(navState),
    );
    const panel = await cdp.eval(
      "document.getElementById('settings-body').textContent",
    );
    check(
      panel.includes("deepseek-v4-flash") && panel.includes(store),
      "the panel reports the model actually in use and the store actually resolved",
      panel,
    );
    // The key it is using is shown as a fingerprint, never printed.
    const keyState = await cdp.eval(
      "document.querySelector('#settings-body .key-state').textContent",
    );
    check(
      !keyState.includes("sk-") || keyState.includes("…"),
      "the panel identifies the key rather than printing it",
      keyState,
    );
    // The dialog must not push the page around: it is in the top layer, so the title it used to sit
    // beside has not moved.
    const titleTop = await cdp.eval(
      "document.getElementById('title').getBoundingClientRect().top",
    );
    check(titleTop <= 4, "opening the dialog does not push the title down", String(titleTop));
    // Escape closes it — the browser's own way out, which is why a modal is worth it.
    await cdp.eval(
      `document.getElementById('settings').dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`,
    );
    await new Promise((r) => setTimeout(r, 200));
    if (await cdp.eval("document.getElementById('settings').open === true")) {
      // Browsers do not synthesize the cancel from a dispatched event, so fall back to the
      // button — what is being asserted either way is that there is a way out that is not a
      // page reload.
      await cdp.eval("document.getElementById('settings-close').click()");
      await cdp.waitFor(
        "document.getElementById('settings').open === false",
        "the dialog to close from its own button",
        5000,
      );
      check(true, "the close button closes the dialog");
    } else {
      check(true, "Escape closes the dialog");
    }
    // And it reopens with everything intact, because the check below applies a setting.
    await cdp.eval("document.getElementById('settings-open').click()");
    await cdp.waitFor("document.getElementById('settings').open === true", "the dialog to reopen", 5000);

    // The seeded skill is listed and on. The count is read rather than hardcoded: this machine may
    // have skills of its own under a root the check does not control, and what is being tested is
    // that the number tracks the boxes.
    const count = () =>
      cdp.eval("document.querySelector('#settings-body h3 .count').textContent");
    const onCount = async () => Number((await count()).split("/")[0].replace(/[^0-9]/g, ""));
    const skillsOn = await onCount();
    check(
      (await cdp.eval(
        `document.querySelector('#settings-body input[value="browser-demo"]')?.checked === true`,
      )),
      "a discovered skill is listed as on",
    );
    check(skillsOn > 0, "the panel counts the skills that are on", `${skillsOn}`);
    // Switch it off and apply. The form is posted by the page rather than navigated to, so this
    // also covers that the delegated submit listener is attached to a form that arrived in a
    // patch.
    await cdp.eval(
      `(() => {
        const box = document.querySelector('#settings-body input[value="browser-demo"]');
        box.checked = false;
        document.getElementById('skills-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('skill')",
      "the skill change to be applied",
      15000,
    );
    check(true, "toggling a skill posts and is acknowledged");
    await cdp.waitFor(
      `document.querySelector('#settings-body input[value="browser-demo"]')?.checked === false`,
      "the panel to come back with the skill off",
      15000,
    );
    // The body is what gets replaced, so the panel the reader had open is still open — and the
    // count agrees with the box.
    check(
      (await cdp.eval("document.getElementById('settings').open === true")),
      "applying a setting does not close the panel",
    );
    check(
      (await cdp.eval("document.querySelectorAll('#settings-body').length")) === 1 &&
        (await cdp.eval("document.querySelectorAll('#settings').length")) === 1,
      "refreshing the panel did not nest it in itself",
    );
    check(
      (await onCount()) === skillsOn - 1,
      "the panel reports the new state, not the submitted one",
      `${await count()}`,
    );
    const settingsFile = join(home, ".pi-mb/settings.json");
    check(
      existsSync(settingsFile) &&
        JSON.parse(readFileSync(settingsFile, "utf8")).disabled_skills.includes(
          "browser-demo",
        ),
      "the switch is written to the settings file",
    );
    // And it goes back on the same way: the form is the only way in, so the reverse direction has
    // to work through it too. (Whether the catalog the model actually receives lost the skill is
    // asserted in `ui/app_wbtest.mbt`, where the prompt can be inspected — a transcript never
    // contains the catalog.)
    await cdp.eval(
      `(() => {
        document.querySelector('#settings-body input[value="browser-demo"]').checked = true;
        document.getElementById('skills-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelector('#settings-body h3 .count').textContent === ${JSON.stringify(
        `${skillsOn}/${skillsOn} on`,
      )}`,
      "the skill to go back on",
      15000,
    );
    check(
      (await cdp.eval(
        `document.querySelector('#settings-body input[value="browser-demo"]')?.checked === true`,
      )),
      "switching it back on restores the count",
      `${await count()}`,
    );
    check(true, "a switched-off skill can be switched back on");

    // The tool mode: the one setting whose effect is on the next request rather than on the page,
    // so the round trip through the form is the only part a browser can check. What the mode does
    // to the prompt and the tool schema is asserted in `ui/app_wbtest.mbt`, where both are
    // readable; here it is that the form posts, is acknowledged, is written down, and can be put
    // back — the turn check below uses `bash`, which code mode replaces with `exec`.
    check(
      (await cdp.eval(
        `document.querySelector('#settings-body input[name="tool_mode"][value="tools"]')?.checked === true`,
      )),
      "the mode in force is shown as the chosen one",
    );
    await cdp.eval(
      `(() => {
        document.querySelector('#settings-body input[name="tool_mode"][value="code"]').checked = true;
        document.getElementById('mode-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('mode')",
      "the mode change to be applied",
      15000,
    );
    check(true, "choosing a mode posts and is acknowledged");
    check(
      JSON.parse(readFileSync(settingsFile, "utf8")).tool_mode === "code",
      "the mode is written to the settings file",
      readFileSync(settingsFile, "utf8"),
    );
    await cdp.waitFor(
      `document.querySelector('#settings-body input[name="tool_mode"][value="code"]')?.checked === true`,
      "the panel to come back with code mode chosen",
      15000,
    );
    check(true, "the panel renders the mode now in force rather than the one clicked from");
    // Back to the default, because the check further down runs a turn with `bash`.
    await cdp.eval(
      `(() => {
        document.querySelector('#settings-body input[name="tool_mode"][value="tools"]').checked = true;
        document.getElementById('mode-form').requestSubmit();
        return true;
      })()`,
    );
    // Awaited on the acknowledgement rather than on the radio: the radio was set by the script
    // above, so it is already checked when the request goes out and waiting on it would race the
    // write. The status line is the server saying the write happened.
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('tools mode')",
      "the change back to be acknowledged",
      15000,
    );
    check(
      JSON.parse(readFileSync(settingsFile, "utf8")).tool_mode === "tools",
      "switching the mode back is written down too",
    );
    await cdp.waitFor(
      `document.querySelector('#settings-body input[name="tool_mode"][value="tools"]')?.checked === true`,
      "the panel to come back with the tools chosen",
      15000,
    );

    // The limits: the guards a reader can move without a restart. Driven through the form the
    // page actually renders, because the interesting failure is a form that posts and changes
    // nothing — the value the next turn reads is what has to move.
    const limitsBefore = await cdp.eval(
      `document.querySelector('#limits-form input[name="max_rounds"]').value`,
    );
    check(
      limitsBefore === "" || /^[0-9.]+$/.test(limitsBefore),
      "the limit fields show a value or an empty box for the default",
      `${limitsBefore}`,
    );
    await cdp.eval(
      `(() => {
        document.querySelector('#limits-form input[name="max_rounds"]').value = '57';
        document.querySelector('#limits-form input[name="max_cost"]').value = '0.75';
        document.querySelector('#limits-form input[name="max_seconds"]').value = '900';
        document.getElementById('limits-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('limits saved')",
      "the limits to be saved",
      15000,
    );
    check(true, "saving a limit posts and is acknowledged");
    let settingsNow = JSON.parse(readFileSync(settingsFile, "utf8"));
    check(
      settingsNow.max_rounds === 57 && settingsNow.max_cost === 0.75 &&
        settingsNow.max_seconds === 900,
      "the limits are written to the settings file",
      JSON.stringify(settingsNow),
    );
    await cdp.waitFor(
      `document.querySelector('#limits-form input[name="max_rounds"]')?.value === "57"`,
      "the panel to come back showing the saved limits",
      15000,
    );
    check(true, "the panel renders the limits that are now in force rather than what was typed");
    // And the next turn really runs under them. This is what separates "a form that saved a
    // number" from "a bound the turn reads", and it is checked with the limit that stops a turn
    // deterministically: one model call, with a prompt that forces a tool round, so the turn has
    // somewhere to stop rather than settling on its first answer.
    await cdp.eval(
      `(() => {
        document.querySelector('#limits-form input[name="max_rounds"]').value = '1';
        document.querySelector('#limits-form input[name="max_cost"]').value = '';
        document.getElementById('limits-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelector('#limits-form input[name="max_rounds"]')?.value === "1"`,
      "the one-call limit to be saved",
      15000,
    );
    await cdp.eval(
      `(() => {
        document.getElementById('prompt').value = 'Use the bash tool to run exactly: /bin/echo limit-check';
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    // The status line says *that* a guard stopped the turn and which one; the footer under the
    // reply says how many model calls it took to get there. The count used to be in both places.
    await cdp.waitFor(
      `document.getElementById('status').textContent.includes('gave up')`,
      "the turn to stop at the saved call limit",
      120000,
    );
    check(
      !/model call/.test(await cdp.eval("document.getElementById('status').textContent")),
      "the guard is named without repeating the footer's counts",
      await cdp.eval("document.getElementById('status').textContent"),
    );
    check(true, "the saved call limit is the one the next turn runs under");
    // Put the limits back, so the checks after this one run the way they did before.
    await cdp.eval(
      `(() => {
        document.querySelector('#limits-form input[name="max_rounds"]').value = '';
        document.querySelector('#limits-form input[name="max_cost"]').value = '';
        document.querySelector('#limits-form input[name="max_seconds"]').value = '';
        document.getElementById('limits-form').requestSubmit();
        return true;
      })()`,
    );
    // Waiting on the *server's* answer, not on the field: the field is empty the moment this
    // script clears it, so waiting for that would be waiting for nothing. The rendered source
    // label only becomes `default` when the panel that came back from the server says so.
    await cdp.waitFor(
      `document.querySelector('#limits-form label.limit .source')?.textContent === "default"`,
      "the limits to go back to the defaults",
      15000,
    );
    settingsNow = JSON.parse(readFileSync(settingsFile, "utf8"));
    check(
      settingsNow.max_rounds === null && settingsNow.max_cost === null &&
        settingsNow.max_seconds === null,
      "clearing the fields records no opinion rather than a bound of zero",
      JSON.stringify(settingsNow),
    );

    // The instructions: the one setting where "saved" and "in force" are different questions,
    // and the whole reason the block shows a source line above a preview. The active workspace is
    // the second one added above, so this starts from a file it does not have.
    const instructionSource = () =>
      cdp.eval(
        "document.querySelector('#settings-body .instruction-source b')?.textContent",
      );
    const instructionPreview = () =>
      cdp.eval(
        "document.querySelector('#settings-body .instruction-preview')?.textContent ?? ''",
      );
    check(
      (await instructionSource()) === "AGENTS.md in this workspace",
      "a workspace with an AGENTS.md reports it as the instructions in force",
      `${await instructionSource()} / ${await instructionPreview()}`,
    );
    check(
      (await instructionPreview()).includes("# browser check instructions"),
      "the preview shows what the turn will actually send",
      await instructionPreview(),
    );
    // Saving a fallback posts through the form the page renders, and the status line has to say
    // the save landed *and* that it is not the text being sent — otherwise "I saved it and nothing
    // changed" reads as a bug rather than as the precedence working.
    await cdp.eval(
      `(() => {
        document.getElementById('agents-input').value = 'Prefer small diffs.';
        document.getElementById('agents-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('takes precedence')",
      "the fallback instructions to be saved",
      15000,
    );
    check(
      true,
      "saving fallback instructions is acknowledged as overruled by the workspace file",
    );
    check(
      JSON.parse(readFileSync(settingsFile, "utf8")).agents_md ===
        "Prefer small diffs.",
      "the fallback is written to the settings file",
    );
    check(
      (await cdp.eval("document.getElementById('agents-input').value")) ===
        "Prefer small diffs.",
      "the textarea keeps the text, which unlike a key the server does send back",
    );
    // Removing the file flips which source is in force, with no restart and no reload: the read
    // happens per turn and per render, so a cache here is the one thing this whole check is for.
    rmSync(join(second, "AGENTS.md"));
    await cdp.eval(
      `(() => {
        document.getElementById('agents-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.querySelector('#settings-body .instruction-source b')?.textContent === "saved in settings"`,
      "the panel to report the saved text now that the file is gone",
      15000,
    );
    check(
      (await instructionPreview()) === "Prefer small diffs.",
      "and to preview the saved text rather than the file it can no longer read",
      await instructionPreview(),
    );
    // Clearing it is the case the marker field exists for: an emptied textarea posts no field at
    // all, and without the marker the server could not tell it from a request the panel never
    // made.
    await cdp.eval(
      `(() => {
        document.getElementById('agents-input').value = '';
        document.getElementById('agents-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('cleared')",
      "the cleared fallback to be acknowledged",
      15000,
    );
    check(
      JSON.parse(readFileSync(settingsFile, "utf8")).agents_md === "",
      "an emptied textarea clears the setting rather than saving a blank one",
    );
    check(
      (await cdp.eval(
        "document.querySelector('#settings-body .instruction-source b')?.textContent",
      )) === "none",
      "and the panel says nothing is being sent rather than leaving the reader to guess",
    );

    // Finally the key, which is last because saving one changes what the next turn would send
    // and every turn check above has already run.
    const fakeKey = "sk-browser-check-0000000000000000";
    await cdp.eval(
      `(() => {
        document.getElementById('key-input').value = ${JSON.stringify(fakeKey)};
        document.getElementById('key-form').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      "document.getElementById('status').textContent.includes('key')",
      "the key to be saved",
      15000,
    );
    check(true, "saving a key posts and is acknowledged");
    check(
      JSON.parse(readFileSync(settingsFile, "utf8")).saved_api_key === fakeKey,
      "the key is written to the settings file",
    );
    // The credential never comes back to the browser, and the field the reader typed into is
    // cleared rather than left holding it.
    check(
      (await cdp.eval(
        "document.documentElement.outerHTML.includes('browser-check-0000')",
      )) === false,
      "the saved key is never rendered back into the page",
    );
    check(
      (await cdp.eval("document.getElementById('key-input').value")) === "",
      "the field does not keep the key after saving",
    );
    // Clearing it is the other half of the same control, and the one that would silently take the
    // wrong branch if the button's value were relied on: a submit button's name is not part of a
    // form's data, so the clear control has to carry a hidden field of its own.
    await cdp.waitFor(
      "document.getElementById('key-clear') !== null",
      "the clear control to appear once a key is saved",
      15000,
    );
    await cdp.eval(
      `(() => { document.getElementById('key-clear').requestSubmit(); return true; })()`,
    );
    await cdp.waitFor(
      `document.getElementById('status').textContent.includes('cleared')`,
      "the clear to be applied and reported as such",
      15000,
    );
    check(true, "clearing a key posts and says what is in use instead");
    check(
      JSON.parse(readFileSync(settingsFile, "utf8")).saved_api_key === "",
      "clearing removes the saved key from the file",
    );
    check(
      (await cdp.eval("document.getElementById('key-clear') === null")),
      "the clear control goes away once there is nothing to clear",
    );

    console.log("\nskill invocation (/skill:<name>)");
    // The expansion is the whole feature: the model must answer with a string that exists nowhere
    // except the skill's body, because its description only says the body exists.
    await cdp.eval(
      `(() => {
        document.getElementById('prompt').value = '/skill:browser-demo go';
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('transcript').textContent.includes('SKILL-BODY-OK-9f2c')`,
      "the skill body to reach the model and come back",
      120000,
    );
    check(true, "/skill:<name> expands the skill and the model answers from it");
    // The block the model saw is not in the transcript — it is the request, not the reply — so
    // assert on the rendering instead: the reader's message is what they typed, not the expansion.
    const exchange = await cdp.eval(
      `document.getElementById('transcript').textContent`,
    );
    check(
      !exchange.includes("References are relative to"),
      "the expansion is sent to the model without being echoed into the conversation",
    );
    // Let the turn settle before touching the picker: a model change is refused while a turn is
    // running, and neither the reply landing in the transcript nor the Send button re-enabling is
    // the same moment as the turn ending — the POST returns immediately, while the turn runs on.
    // Stop is the one thing that says a turn is over: it is live only while one is running, and it
    // goes back to disabled at the same moment the picker unlocks. (The status line used to be the
    // signal here; a turn that finishes normally now leaves it empty, which is the point.)
    await cdp.waitFor(
      `document.getElementById('stop').disabled === true`,
      "the skill turn to finish",
      120000,
    );

    console.log("\nmodel picker (per session, bottom-right of the composer)");
    const pickerState = () =>
      cdp.eval(
        `(() => {
          const s = document.getElementById('model-picker');
          return JSON.stringify({ count: document.querySelectorAll('#model-picker').length, value: s && s.selectedOptions[0].value, options: s ? s.options.length : 0 });
        })()`,
      );
    const pickerBefore = JSON.parse(await pickerState());
    check(
      pickerBefore.count === 1,
      "the composer has exactly one model picker",
      JSON.stringify(pickerBefore),
    );
    check(
      pickerBefore.options >= 3,
      "the picker offers the catalog",
      JSON.stringify(pickerBefore),
    );
    // Switching through the control the page actually renders.
    await cdp.eval(
      `(() => {
        const s = document.getElementById('model-picker');
        s.value = 'deepseek-v4-pro';
        s.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()`,
    );
    await cdp.waitFor(
      `document.getElementById('status').textContent.includes('V4 Pro')`,
      "the switch to be acknowledged",
      15000,
    );
    check(true, "the picker switches the session's model");
    await cdp.waitFor(
      `document.querySelector('#model-picker').selectedOptions[0].value === 'deepseek-v4-pro'`,
      "the picker to come back showing the new model",
      15000,
    );
    check(
      (await cdp.eval(
        "document.getElementById('model-picker').selectedOptions[0].textContent",
      )).includes("V4 Pro"),
      "the picker names the model the session is now on",
    );
    // A turn made on the new model, so the switch is not just a field: the reply is real and the
    // cost is billed at the new model's rates.
    await cdp.eval(
      `(() => {
        document.getElementById('prompt').value = 'Reply with the single word: ok';
        document.getElementById('composer').requestSubmit();
        return true;
      })()`,
    );
    await cdp.waitFor(
      `!document.getElementById('send').disabled`,
      "a turn on the newly chosen model",
      120000,
    );
    check(true, "a turn runs on the model the picker selected");
    // And it survived a restart: the choice is an entry in the session's log, so a reload — which
    // is what a restart looks like from the page — must find the same model selected.
    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor("document.readyState === 'complete'", "page reload", 20000);
    await sleep(1500);
    const pickerAfter = JSON.parse(await pickerState());
    check(
      pickerAfter.value === "deepseek-v4-pro",
      "the chosen model comes back after a reload, because it is in the log",
      JSON.stringify(pickerAfter),
    );

    console.log("\nno uncaught exceptions");
    check(
      cdp.exceptions.length === 0,
      "the page never threw",
      cdp.exceptions.join("\n       "),
    );
    if (cdp.consoleErrors.length) {
      note(`console errors seen: ${JSON.stringify(cdp.consoleErrors)}`);
    }

    const shot = KEEP
      ? join(process.cwd(), "_build/browser-check.png")
      : join(tmpdir(), "pws-browser-check.png");
    await cdp.screenshot(shot);
    console.log(`\nscreenshot: ${shot}`);
  } finally {
    // A failed check must not leave the process it started behind — that is precisely the
    // failure the check is about.
    for (const pid of backgroundPids) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        /* already gone */
      }
    }
    server.kill("SIGKILL");
    chrome?.kill("SIGKILL");
    if (!KEEP) {
      // Cleanup must not be able to fail the run: Chrome keeps writing to its profile
      // for a moment after being killed.
      const remove = (path) => {
        try {
          rmSync(path, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
        } catch {
          /* a temporary directory that outlives the run is not a failure */
        }
      };
      remove(store);
      remove(`${store}-another-project-with-a-long-name`);
      remove(profile);
    } else {
      console.log(`kept store ${store} and profile ${profile}`);
    }
  }

  for (const n of notes) console.log(`note: ${n}`);
  console.log(
    failures.length === 0
      ? "\nbrowser check passed"
      : `\nbrowser check FAILED (${failures.length}): ${failures.join(", ")}`,
  );
  process.exit(failures.length === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`browser check crashed: ${err.message}`);
  // Anything the page threw on the way, which is the usual reason a wait never becomes true. Without
  // this the crash says only *what* did not happen, and the exception — the thing that explains it —
  // is thrown away with the run.
  if (cdp && cdp.exceptions.length > 0) {
    console.error(`\nthe page threw ${cdp.exceptions.length} time(s):`);
    for (const e of cdp.exceptions.slice(0, 5)) console.error(`  - ${e}`);
  }
  if (cdp && cdp.consoleErrors.length > 0) {
    console.error(`\nthe page logged ${cdp.consoleErrors.length} error(s):`);
    for (const e of cdp.consoleErrors.slice(0, 5)) console.error(`  - ${e.slice(0, 400)}`);
  }
  process.exit(1);
});
