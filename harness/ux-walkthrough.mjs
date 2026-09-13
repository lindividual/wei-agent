#!/usr/bin/env node
/**
 * A walkthrough, not a check.
 *
 * `ui-browser-check.mjs` asserts things it already knows. This one does the opposite: it drives the
 * page the way a person would, and writes down what is on screen at each step so the result can be
 * looked at. No assertions, no pass/fail — the output is evidence.
 *
 *   node harness/ux-walkthrough.mjs            # writes _build/ux/NN-name.png + .txt
 *   node harness/ux-walkthrough.mjs --fast     # skip the real model turns
 *
 * The screenshots and text dumps land in `_build/ux/`, which the repository already ignores.
 */
import { spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const UI_BIN = "_build/native/debug/build/ui/ui.exe";
const FAST = process.argv.includes("--fast");
const OUT = "_build/ux";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

class Session {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
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
    }
  }
  send(method, params = {}) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      setTimeout(() => {
        if (this.pending.delete(id)) reject(new Error(`${method} timed out`));
      }, 60000);
    });
  }
  async eval(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (result.exceptionDetails) {
      throw new Error(`${expression} threw: ${result.exceptionDetails.exception?.description}`);
    }
    return result.result.value;
  }
  async waitFor(expression, label, timeoutMs = 120000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (await this.eval(expression)) return true;
      await sleep(250);
    }
    console.log(`  (timed out waiting for ${label})`);
    return false;
  }
  async shot(path) {
    const result = await this.send("Page.captureScreenshot", { format: "png" });
    writeFileSync(path, Buffer.from(result.data, "base64"));
  }
}

let step = 0;
async function observe(cdp, name, note) {
  step += 1;
  const n = String(step).padStart(2, "0");
  const base = join(OUT, `${n}-${name}`);
  await cdp.shot(`${base}.png`);
  // innerText respects display:none, so this is what a sighted user can actually read.
  const text = await cdp.eval("document.body.innerText");
  // Everything the page offers to click or type into, as it presents itself.
  const affordances = await cdp.eval(
    `JSON.stringify([...document.querySelectorAll('button, a, input, textarea, select, summary, [data-session], [data-new], [data-continue], [data-kill], [data-stop], [data-dismiss]')]
      .map(el => ({
        tag: el.tagName.toLowerCase(),
        label: (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || el.title || '').trim().slice(0, 60),
        disabled: el.disabled === true,
        visible: el.offsetParent !== null || el.tagName === 'SUMMARY',
      }))
      .filter(e => e.label !== '' || e.tag === 'input' || e.tag === 'select'))`,
    );
  writeFileSync(
    `${base}.txt`,
    [
      `# ${name}`,
      note ? `\n${note}\n` : "",
      "── visible text ──",
      text,
      "",
      "── affordances (what the page offers to click/type) ──",
      JSON.stringify(JSON.parse(affordances), null, 1),
      "",
    ].join("\n"),
  );
  console.log(`  ${n}-${name}`);
}

function scratchHome() {
  const home = mkdtempSync(join(tmpdir(), "ux-home-"));
  const auth = join(homedir(), ".pi/agent/auth.json");
  if (existsSync(auth)) {
    mkdirSync(join(home, ".pi/agent"), { recursive: true });
    copyFileSync(auth, join(home, ".pi/agent/auth.json"));
  }
  const skill = join(home, ".pi/agent/skills/report-writer");
  mkdirSync(skill, { recursive: true });
  writeFileSync(
    join(skill, "SKILL.md"),
    "---\nname: report-writer\ndescription: Writes a status report from a git log.\n---\n\n# report-writer\n\nBody.\n",
  );
  writeFileSync(
    join(home, ".pi-mb-settings-placeholder"),
    "",
  );
  return home;
}

/// A session file the server accepts, with `turns` exchanges, so the walks can start from a store
/// that already has history in it.
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
        content: [
          {
            type: "text",
            text:
              n === 1
                ? label
                : `follow-up question number ${n}, about the same thing as before`,
          },
        ],
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
        content: [
          { type: "text", text: `Answer ${n}. A paragraph long enough to read as prose.\n\nAnd a second paragraph.` },
        ],
        api: "openai-completions",
        provider: "deepseek",
        model: "deepseek-v4-flash",
        usage: {
          input: 1200,
          output: 90,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 1290,
          cost: { input: 0.000168, output: 0.0000252, cacheRead: 0, cacheWrite: 0, total: 0.0001932 },
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

function storeDirName(cwd) {
  const start = cwd.startsWith("/") ? 1 : 0;
  const body = cwd.slice(start).replace(/[/\\:]/g, "-");
  return `--${body}--`;
}

async function main() {
  if (!existsSync(UI_BIN)) {
    console.error(`missing ${UI_BIN} — run: moon build --target native`);
    process.exit(2);
  }
  rmSync(OUT, { recursive: true, force: true });
  mkdirSync(OUT, { recursive: true });

  const store = mkdtempSync(join(tmpdir(), "ux-store-"));
  const home = scratchHome();
  const profile = mkdtempSync(join(tmpdir(), "ux-chrome-"));
  mkdirSync(join(profile, "Default"), { recursive: true });
  const port = await freePort();
  const debugPort = await freePort();
  const URL = `http://127.0.0.1:${port}/`;

  const server = spawn(UI_BIN, ["--port", String(port), "--store", store], {
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, HOME: home },
  });
  server.stderr.on("data", (d) => {
    const s = String(d);
    if (s.includes("failed") || s.includes("error")) process.stdout.write(`  [ui] ${s}`);
  });

  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(URL)).ok) break;
    } catch {}
    await sleep(250);
  }

  const chrome = spawn(
    CHROME,
    [
      "--headless=new",
      `--remote-debugging-port=${debugPort}`,
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-gpu",
      "--window-size=1280,900",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  let targets;
  for (let i = 0; i < 40; i++) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
      if (targets.length) break;
    } catch {}
    await sleep(250);
  }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve);
    ws.addEventListener("error", reject);
  });
  const cdp = new Session(ws);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");

  const load = async () => {
    await cdp.send("Page.navigate", { url: URL });
    await cdp.waitFor("document.readyState === 'complete'", "load", 20000);
    await sleep(1500);
  };
  const type = async (text) => {
    await cdp.eval(
      `(() => { const i = document.getElementById('prompt'); i.value = ${JSON.stringify(text)}; document.getElementById('composer').requestSubmit(); return true; })()`,
    );
  };

  console.log(`walking ${URL}`);

  // ── 1. First contact: an empty store. What is on screen, and does it say what to do? ──
  await load();
  await observe(cdp, "landing-empty", "A brand-new user, empty store. Nothing has ever been asked.");

  // ── 2. The core loop. Ask something and watch it happen. ──
  if (!FAST) {
    await type("In one sentence: what is a monad?");
    await cdp.waitFor(
      `/working/.test(document.getElementById('status').textContent)`,
      "work to start",
      30000,
    );
    await observe(cdp, "mid-turn", "A turn is running: this is what 'working' looks like.");
    await cdp.waitFor(
      `!document.getElementById('status').textContent.includes('working') && /model call/.test(document.getElementById('status').textContent)`,
      "turn to finish",
      180000,
    );
    await sleep(500);
    await observe(cdp, "after-turn", "The turn finished. What does the reader have now?");
  }

  // ── 3. A refusal: try to do something the UI will not allow. ──
  if (!FAST) {
    await type("Use the bash tool to run exactly: /bin/sleep 25");
    await cdp.waitFor(
      `/working/.test(document.getElementById('status').textContent)`,
      "long turn",
      30000,
    );
    await cdp.eval(
      `(() => { const s = document.getElementById('model-picker'); s.value = 'deepseek-v4-pro'; s.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`,
    );
    await sleep(800);
    await observe(cdp, "refusal-mid-turn", "The reader tried to change the model while a turn runs. This is how the refusal appears.");
    await cdp.eval(
      `(() => { const s = document.getElementById('model-picker'); return s.disabled; })()`,
    );
  }

  // ── 4. Discoverability: what does the page tell a reader they can do? ──
  await observe(cdp, "discoverability", "No interaction — just: what does the page offer?");

  // ── 5. The settings panel, opened the way a reader would. ──
  await cdp.eval(
    `(() => { const d = document.getElementById('settings'); if (d) d.open = true; return true; })()`,
  );
  await sleep(300);
  await observe(cdp, "settings-open", "The settings panel, opened.");

  // ── 6. A store with history: what does returning look like? ──
  const other = `${store}-project`;
  mkdirSync(other, { recursive: true });
  const dir = join(store, storeDirName(other));
  mkdirSync(dir, { recursive: true });
  // Thirteen sessions, written oldest first so that the long one is the *newest*: the list is
  // ordered by mtime, and a fixture whose subject is the row the cap hides observes nothing.
  const seeded = sessionFile(other, "why is the deploy failing on fridays", 30);
  for (let k = 0; k < 12; k++) {
    const s = sessionFile(other, `another session number ${k}`, 2);
    writeFileSync(join(dir, `2020-01-${String(k + 1).padStart(2, "0")}T00-00-00.000Z_${s.id}.jsonl`), s.text);
  }
  writeFileSync(join(dir, `2030-01-01T00-00-00.000Z_${seeded.id}.jsonl`), seeded.text);
  await load();
  // The workspace holding them is not the one being worked in, so it arrives folded — and a folded
  // workspace shows no sessions at all. Opening it is part of setting up the state being observed.
  const opened = await cdp.eval(
    `(() => {
      const list = [...document.querySelectorAll('#sessions details.workspace')];
      const target = list.find(d => d.querySelector('summary').title === ${JSON.stringify(other)});
      if (!target) return false;
      target.open = true;
      return true;
    })()`,
  );
  await sleep(300);
  console.log(`  (the seeded workspace is ${opened ? "open" : "MISSING"})`);
  await observe(cdp, "returning-many-sessions", "A returning reader: 13 sessions in one workspace, one of them 30 turns long.");

  // ── 7. The long conversation, opened. Past the cap, which is where the offer comes in. ──
  await cdp.eval(
    `(() => {
      const more = document.querySelector('#sessions [data-more]');
      if (more) more.click();
      return true;
    })()`,
  );
  await sleep(800);
  const clicked = await cdp.eval(
    `(() => {
      const row = [...document.querySelectorAll('#sessions [data-session]')].find(r => r.textContent.includes('deploy failing'));
      if (!row) return false;
      row.click();
      return true;
    })()`,
  );
  await sleep(2500);
  console.log(`  (the long session is ${clicked ? "on screen" : "MISSING"})`);
  await observe(cdp, "long-conversation", "The 30-turn conversation, opened.");

  console.log(`\nwrote ${step} observations to ${OUT}/`);
  server.kill("SIGKILL");
  chrome.kill("SIGKILL");
  rm_quiet(profile);
}

///
/// Remove a scratch directory, and never let that be the reason a run fails.
///
/// Chrome is killed with SIGKILL, and its helper processes can still be holding files in the
/// profile for a moment afterwards, so a recursive remove races with them and throws ENOTEMPTY.
/// That is what this used to do: five observations written, then a non-zero exit — a successful
/// run reported as a failure, which is worse than a failure, because the exit code is the one
/// thing a caller looks at. A leftover directory in the system temp area costs nothing.
function rm_quiet(path) {
  try {
    rmSync(path, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  } catch {}
}

await main();
