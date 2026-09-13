#!/usr/bin/env node
/**
 * Measure what is on screen, rather than looking at it.
 *
 * The audit needs hard numbers for things usually judged by eye: which element is the most
 * prominent, what sits above the fold, how much of the width the sidebar takes, whether text has
 * enough contrast, and how big the click targets are. A screenshot answers none of those
 * precisely; computed style and bounding boxes answer all of them.
 *
 *   node harness/ux-measure.mjs            > _build/ux/measure.json
 *   node harness/ux-measure.mjs --empty    (start from an empty store)
 *
 * Prints one JSON document: every visible element with its geometry, type, and colour, plus a
 * summary block for the things worth looking at first.
 */
import { spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  writeFileSync,
} from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const UI_BIN = "_build/native/debug/build/ui/ui.exe";
const EMPTY = process.argv.includes("--empty");
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
    ws.addEventListener("message", (e) => {
      const m = JSON.parse(e.data);
      if (m.id === undefined) return;
      const w = this.pending.get(m.id);
      if (w) {
        this.pending.delete(m.id);
        m.error ? w.reject(new Error(JSON.stringify(m.error))) : w.resolve(m.result);
      }
    });
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
    const r = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description);
    return r.result.value;
  }
}

function storeDirName(cwd) {
  const body = (cwd.startsWith("/") ? cwd.slice(1) : cwd).replace(/[/\\:]/g, "-");
  return `--${body}--`;
}

function sessionFile(cwd, label, turns = 1) {
  const id = Math.random().toString(16).slice(2, 10);
  const at = new Date(1700000000000).toISOString();
  const line = (o) => JSON.stringify(o);
  const out = [line({ type: "session", version: 3, id, timestamp: at, cwd })];
  for (let n = 1; n <= turns; n++) {
    out.push(
      line({
        type: "message",
        id: `u${n}`,
        parentId: n === 1 ? null : `a${n - 1}`,
        timestamp: at,
        message: {
          role: "user",
          content: [{ type: "text", text: n === 1 ? label : `follow-up ${n}` }],
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
          content: [{ type: "text", text: `Answer ${n}. One paragraph of prose, then another.\n\nSecond paragraph here.` }],
          api: "openai-completions",
          provider: "deepseek",
          model: "deepseek-v4-flash",
          usage: { input: 1200, output: 90, cacheRead: 0, cacheWrite: 0, totalTokens: 1290,
                   cost: { input: 0.000168, output: 0.0000252, cacheRead: 0, cacheWrite: 0, total: 0.0001932 } },
          stopReason: "stop",
          timestamp: 1700000000000,
        },
      }),
    );
  }
  return { id, text: out.join("\n") + "\n" };
}

async function main() {
  const store = mkdtempSync(join(tmpdir(), "uxm-store-"));
  const home = mkdtempSync(join(tmpdir(), "uxm-home-"));
  const auth = join(homedir(), ".pi/agent/auth.json");
  if (existsSync(auth)) {
    mkdirSync(join(home, ".pi/agent"), { recursive: true });
    copyFileSync(auth, join(home, ".pi/agent/auth.json"));
  }
  const profile = mkdtempSync(join(tmpdir(), "uxm-chrome-"));
  mkdirSync(join(profile, "Default"), { recursive: true });

  if (!EMPTY) {
    const other = `${store}-project`;
    mkdirSync(other, { recursive: true });
    const dir = join(store, storeDirName(other));
    mkdirSync(dir, { recursive: true });
    const s = sessionFile(other, "why is the deploy failing on fridays", 24);
    writeFileSync(join(dir, `2020-01-01T00-00-00.000Z_${s.id}.jsonl`), s.text);
  }

  const port = await freePort();
  const debugPort = await freePort();
  const URL = `http://127.0.0.1:${port}/`;
  const server = spawn(UI_BIN, ["--port", String(port), "--store", store], {
    stdio: ["ignore", "ignore", "ignore"],
    env: { ...process.env, HOME: home },
  });
  for (let i = 0; i < 60; i++) {
    try { if ((await fetch(URL)).ok) break; } catch {}
    await sleep(250);
  }
  const chrome = spawn(CHROME, [
    "--headless=new", `--remote-debugging-port=${debugPort}`,
    `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check",
    "--disable-gpu", "--window-size=1280,900", "about:blank",
  ], { stdio: ["ignore", "ignore", "ignore"] });

  let targets;
  for (let i = 0; i < 40; i++) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${debugPort}/json/list`)).json();
      if (targets.length) break;
    } catch {}
    await sleep(250);
  }
  const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.addEventListener("open", res);
    ws.addEventListener("error", rej);
  });
  const cdp = new Session(ws);
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");
  await cdp.send("Page.navigate", { url: URL });
  await sleep(2000);
  // Open the seeded conversation: an empty transcript says nothing about reading.
  await cdp.eval(`(() => {
    const row = [...document.querySelectorAll('#sessions [data-session]')]
      .find(r => r.textContent.includes('deploy failing'));
    if (row) row.click();
    return true;
  })()`);
  await sleep(2500);

  const probe = `JSON.stringify((() => {
    const lum = (c) => {
      const m = c.match(/[\\d.]+/g);
      if (!m) return null;
      const [r, g, b] = m.slice(0, 3).map(Number).map(v => {
        v /= 255;
        return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
      });
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };
    const bgOf = (el) => {
      let n = el;
      while (n) {
        const bg = getComputedStyle(n).backgroundColor;
        if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') return bg;
        n = n.parentElement;
      }
      return 'rgb(255,255,255)';
    };
    const ratio = (a, b) => {
      const [x, y] = [lum(a), lum(b)];
      if (x === null || y === null) return null;
      const [hi, lo] = x > y ? [x, y] : [y, x];
      return Math.round(((hi + 0.05) / (lo + 0.05)) * 100) / 100;
    };
    const out = [];
    for (const el of document.querySelectorAll('body *')) {
      const cs = getComputedStyle(el);
      if (cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity) === 0) continue;
      // offsetParent does not notice a closed <details>: its content keeps a layout box. Chrome's
      // own check does, which is why visibility is asked of the browser rather than inferred.
      if (el.checkVisibility && !el.checkVisibility({ contentVisibilityAuto: true, opacityProperty: true, visibilityProperty: true })) continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) continue;
      const own = [...el.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent.trim()).join(' ').trim();
      out.push({
        tag: el.tagName.toLowerCase(),
        id: el.id || null,
        cls: el.className && typeof el.className === 'string' ? el.className : null,
        text: own.slice(0, 70),
        rect: [Math.round(r.x), Math.round(r.y + window.scrollY), Math.round(r.width), Math.round(r.height)],
        font: cs.fontSize + '/' + cs.fontWeight,
        color: cs.color,
        bg: bgOf(el),
        contrast: own ? ratio(cs.color, bgOf(el)) : null,
        role: el.getAttribute('role') || null,
        tabbable: el.tabIndex >= 0 && !el.disabled && cs.display !== 'none',
      });
    }
    const visible = out.filter(e => e.rect[3] > 0);
    const txt = visible.filter(e => e.text);
    const bySize = [...txt].sort((a, b) => parseFloat(b.font) - parseFloat(a.font)).slice(0, 12);
    const fold = window.innerHeight;
    return {
      viewport: [window.innerWidth, window.innerHeight],
      counts: { elements: visible.length, withText: txt.length },
      // The most prominent text on the page, by font size — this is what the eye lands on first.
      mostProminent: bySize.map(e => ({ text: e.text.slice(0, 40), font: e.font, rect: e.rect, cls: e.cls })),
      // Text a reader can read without scrolling.
      aboveFold: txt.filter(e => e.rect[1] < fold).map(e => e.text.slice(0, 60)),
      belowFoldCount: txt.filter(e => e.rect[1] >= fold).length,
      // Contrast, worst first, for anything with text in it.
      lowContrast: txt.map(e => ({ text: e.text.slice(0, 40), contrast: e.contrast, color: e.color, bg: e.bg, cls: e.cls }))
        .filter(e => e.contrast !== null && e.contrast < 4.5)
        .sort((a, b) => a.contrast - b.contrast),
      // Click and tap targets under the usual 24px minimum.
      smallTargets: visible
        .filter(e => ['button', 'select', 'summary', 'input', 'a'].includes(e.tag))
        .filter(e => e.rect[3] < 24 || e.rect[2] < 24)
        .map(e => ({ tag: e.tag, text: e.text.slice(0, 30), rect: e.rect })),
      // How the width is spent, and how far down the page the content starts.
      regions: visible.filter(e => ['bar', 'sidebar', 'transcript', 'composer', 'status'].includes(e.id))
        .map(e => ({ id: e.id, rect: e.rect })),
      // How much text fits on a line where the reading actually happens. 45-90 characters is the
      // usual comfortable range; outside it, the eye loses the line.
      reading: (() => {
        const p = [...document.querySelectorAll('#transcript p')].find(x => x.innerText.length > 40);
        if (!p) return null;
        const cs = getComputedStyle(p);
        const size = parseFloat(cs.fontSize);
        const width = p.getBoundingClientRect().width;
        return { widthOfLine: Math.round(width), fontSize: size, approxChars: Math.round(width / (size * 0.5)) };
      })(),
      // How the viewport's height is spent: chrome (bar + composer + status) versus conversation.
      heightBudget: (() => {
        const h = window.innerHeight;
        const bar = document.getElementById('bar')?.getBoundingClientRect().height ?? 0;
        const composer = document.getElementById('composer')?.getBoundingClientRect().height ?? 0;
        const status = document.getElementById('status')?.getBoundingClientRect().height ?? 0;
        return { viewport: h, bar: Math.round(bar), composer: Math.round(composer),
                 status: Math.round(status), chrome: Math.round(bar + composer + status),
                 chromePercent: Math.round(((bar + composer + status) / h) * 100) };
      })(),
      // What the status line is saying, and how loud it is.
      statusLine: (() => {
        const el = document.getElementById('status');
        if (!el) return null;
        const cs = getComputedStyle(el);
        return { text: el.innerText.trim(), fontSize: cs.fontSize, color: cs.color, align: cs.textAlign };
      })(),
      settingsOpen: document.getElementById('settings')?.open ?? null,
      settingsBodyVisible: (() => {
        const b = document.getElementById('settings-body');
        if (!b) return null;
        const r = b.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      })(),
      sidebarShows: [...document.querySelectorAll('#sessions button, #sessions .meta')].map(e => e.innerText.trim().slice(0, 50)),
      elements: out,
    };
  })())`;

  const result = await cdp.eval(probe);
  process.stdout.write(JSON.stringify(JSON.parse(result), null, 1));

  server.kill("SIGKILL");
  chrome.kill("SIGKILL");
}

await main();
