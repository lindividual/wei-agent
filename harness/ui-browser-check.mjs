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
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const UI_BIN = "_build/native/debug/build/ui/ui.exe";
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

/// A session file the server will accept: a header, then two entries.
function sessionFile(cwd, label) {
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

function startServer(store) {
  const child = spawn(UI_BIN, ["--port", String(PORT), "--store", store], {
    stdio: ["ignore", "pipe", "pipe"],
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
  if (!existsSync(UI_BIN)) {
    console.error(`missing ${UI_BIN} — run: moon build --target native`);
    process.exit(2);
  }
  const store = mkdtempSync(join(tmpdir(), "pws-browser-"));
  const profile = mkdtempSync(join(tmpdir(), "pws-chrome-"));
  mkdirSync(join(profile, "Default"), { recursive: true });

  let server = startServer(store);
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
  const cdp = new Session(ws);
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
      `/model call/.test(document.getElementById('status').textContent)`,
      "the status line to report the turn",
      90000,
    );
    const status = await cdp.eval("document.getElementById('status').textContent");
    check(/\$\d/.test(status), "the status line reports a cost", status);
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
        input.value = ${JSON.stringify("Reply with exactly: browser-ok")};
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
    const seeded = sessionFile(otherCwd, "seeded question from the other project");
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
    await cdp.waitFor(
      `document.getElementById('status').textContent.includes(${JSON.stringify(`in ${otherCwd}`)})`,
      "the agent to move into the other workspace",
      30000,
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
    check(
      (await cdp.eval("document.querySelectorAll('#sessions .session.current').length")) === 1,
      "exactly one session is marked current",
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
    server = startServer(store);
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
    check(
      (await cdp.eval("document.getElementById('transcript').innerHTML.length")) === 0,
      "the page shows the new session the restarted server opened",
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
  process.exit(1);
});
