/**
 * pi-web-shell — serve the rabbita Web UI and bridge it to pi.
 *
 * The browser never talks to pi directly: this extension owns an HTTP server
 * (static assets) plus a WebSocket endpoint, translates pi's session events
 * into one normalized `turn` shape, and forwards prompts back into the agent.
 *
 * Two lifecycle facts shape this file, both learned the hard way:
 *
 * 1. Switching workspaces replaces the session, and pi then RE-CREATES this
 *    extension instance — which also resets this module's scope. Anything the
 *    server needs to keep across a switch therefore lives on `globalThis`, not
 *    in module-level `let`s.
 * 2. Session contexts and the `ExtensionAPI` object are session-bound. After a
 *    switch, touching the old ones throws and pi treats it as fatal, so every
 *    access goes through the current binding and is guarded.
 */
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { WebSocketServer, type WebSocket } from "ws";

/// Port search range. Every pi process loads this extension globally, so they
/// all want a server; rather than letting the losers fail silently, each one
/// walks upward to the first free port.
const PORT_BASE = 7801;
const PORT_TRIES = 20;
const WS_PATH = "/pi";

/// Compiled rabbita bundle, shipped next to this extension so a global install
/// does not depend on any project directory.
const DIST = path.resolve(__dirname, "dist");

const DEBUG_LOG = "/tmp/piweb-debug.log";

/// Registry of live servers. Ports are released by the OS when a process dies,
/// but a pi left behind by a dead screen/terminal keeps holding one, so the
/// list is pruned against real process liveness on every read.
const REGISTRY = path.join(os.homedir(), ".pi/agent/pi-web-shell/instances.json");

type Instance = { pid: number; cwd: string; port: number; startedAt: number };

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".map": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
};

/// A renderable unit of assistant output. Thinking and tool blocks are
/// collapsed by default in the UI; only `text` renders expanded.
type Block =
  | { kind: "thinking"; text: string }
  | { kind: "text"; text: string }
  | {
      kind: "tool";
      name: string;
      args: string;
      result: string | null;
      isError: boolean;
    };

/// One unit of work sent to the browser. `user` is non-null only when the
/// message opens a new exchange, which is what the UI anchors per turn.
type TurnMsg = { user: string | null; blocks: Block[] };

/// A workspace is a directory that has at least one saved session.
type WorkspaceInfo = {
  cwd: string;
  name: string;
  active: boolean;
  sessionCount: number;
  lastSession: string;
  lastModified: number;
  preview: string;
};

/// Process-lifetime state. Survives the module reload that accompanies a
/// workspace switch, which is what lets one long-lived HTTP server serve every
/// session in this process.
type Shell = {
  server: http.Server | null;
  wss: WebSocketServer | null;
  ctx: ExtensionContext | null;
  api: ExtensionAPI | null;
  /// Actual bound port; null until the listener is up.
  port: number | null;
  generation: number;
};

const GLOBAL_KEY = "__piWebShellShell";

function shell(): Shell {
  const g = globalThis as any;
  g[GLOBAL_KEY] ??= {
    server: null,
    wss: null,
    ctx: null,
    api: null,
    port: null,
    generation: 0,
  } satisfies Shell;
  return g[GLOBAL_KEY] as Shell;
}

function readRegistry(): Instance[] {
  try {
    const raw = JSON.parse(fs.readFileSync(REGISTRY, "utf8"));
    const list = Array.isArray(raw?.instances) ? raw.instances : [];
    return list.filter((i: any) => typeof i?.pid === "number");
  } catch {
    return [];
  }
}

function writeRegistry(instances: Instance[]): void {
  try {
    fs.mkdirSync(path.dirname(REGISTRY), { recursive: true });
    fs.writeFileSync(REGISTRY, JSON.stringify({ instances }, null, 2));
  } catch {
    /* the registry is a convenience, never a hard dependency */
  }
}

/// Signal 0 tests for existence without delivering anything.
function isAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

/// Live instances only, dropping entries whose process is gone. Also sweeps
/// stale entries left by a crashed predecessor so the file cannot grow.
function liveInstances(): Instance[] {
  const live = readRegistry().filter((i) => i.pid === process.pid || isAlive(i.pid));
  return live;
}

function registerSelf(cwd: string, port: number): void {
  const others = liveInstances().filter((i) => i.pid !== process.pid);
  writeRegistry([...others, { pid: process.pid, cwd, port, startedAt: Date.now() }]);
}

function unregisterSelf(): void {
  writeRegistry(liveInstances().filter((i) => i.pid !== process.pid));
}

/// Keep the recorded cwd in step with the active session.
/// Live servers with this process flagged, for the UI's instance list.
function instanceList(): unknown[] {
  return liveInstances()
    .map((i) => ({ ...i, current: i.pid === process.pid }))
    .sort((a, b) => a.port - b.port);
}

function touchSelf(cwd: string): void {
  const s = shell();
  if (s.port === null) return;
  const others = liveInstances().filter((i) => i.pid !== process.pid);
  writeRegistry([...others, { pid: process.pid, cwd, port: s.port, startedAt: Date.now() }]);
}

function dbg(line: string): void {
  try {
    fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${line}\n`);
  } catch {
    /* diagnostics are best-effort */
  }
}

// ── message helpers ────────────────────────────────────────────────────────

/// Join every text part of a message's content.
function textOf(msg: any): string {
  const content = msg?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((c: any) => (c?.type === "text" ? String(c.text ?? "") : ""))
    .filter(Boolean)
    .join("\n");
}

/// Convert one assistant message plus its paired tool results into blocks.
/// Tool calls are matched to results by `toolCallId`, so nothing is guessed
/// from ordering.
function blocksFromAssistant(msg: any, toolResults: any[]): Block[] {
  const out: Block[] = [];
  for (const b of msg?.content ?? []) {
    if (b?.type === "thinking") {
      const text = String(b.thinking ?? "").trim();
      if (text) out.push({ kind: "thinking", text });
    } else if (b?.type === "text") {
      const text = String(b.text ?? "").trim();
      if (text) out.push({ kind: "text", text });
    } else if (b?.type === "toolCall") {
      const tr = (toolResults ?? []).find((r: any) => r?.toolCallId === b.id);
      out.push({
        kind: "tool",
        name: String(b.name ?? "tool"),
        args: JSON.stringify(b.arguments ?? {}, null, 2),
        result: tr ? textOf(tr) : null,
        isError: Boolean(tr?.isError),
      });
    }
  }
  return out;
}

/// Rebuild the same `TurnMsg` stream from persisted session entries so a
/// fresh browser tab reproduces what a live connection would have seen.
function historyFromEntries(entries: any[]): TurnMsg[] {
  const out: TurnMsg[] = [];
  let i = 0;
  while (i < entries.length) {
    const msg = entries[i]?.message ?? entries[i];
    if (!msg || typeof msg !== "object") {
      i++;
      continue;
    }
    if (msg.role === "user") {
      const text = textOf(msg).trim();
      // pi injects non-conversational user turns (custom context); skip them
      // so the anchor numbering matches what the user actually typed.
      if (text) out.push({ user: text, blocks: [] });
      i++;
    } else if (msg.role === "assistant") {
      const results: any[] = [];
      let j = i + 1;
      while (j < entries.length) {
        const next = entries[j]?.message ?? entries[j];
        if (next?.role !== "toolResult") break;
        results.push(next);
        j++;
      }
      const blocks = blocksFromAssistant(msg, results);
      const last = out[out.length - 1];
      if (last) last.blocks.push(...blocks);
      else out.push({ user: null, blocks });
      i = j;
    } else {
      i++;
    }
  }
  return out;
}

/// Group saved sessions by working directory, newest first. This is what the
/// browser shows as the workspace list.
async function listWorkspaces(activeCwd: string): Promise<WorkspaceInfo[]> {
  const all = await SessionManager.listAll();
  const byCwd = new Map<string, any[]>();
  for (const s of all) {
    if (!s.cwd) continue;
    const bucket = byCwd.get(s.cwd);
    if (bucket) bucket.push(s);
    else byCwd.set(s.cwd, [s]);
  }
  const out: WorkspaceInfo[] = [];
  for (const [cwd, sessions] of byCwd) {
    sessions.sort((a, b) => +new Date(b.modified) - +new Date(a.modified));
    const newest = sessions[0];
    out.push({
      cwd,
      name: cwd.split("/").filter(Boolean).pop() ?? cwd,
      active: cwd === activeCwd,
      sessionCount: sessions.length,
      lastSession: newest.path,
      lastModified: +new Date(newest.modified),
      preview: String(newest.firstMessage ?? "").slice(0, 90),
    });
  }
  return out.sort((a, b) => b.lastModified - a.lastModified);
}

// ── HTTP ───────────────────────────────────────────────────────────────────

/// True when `full` is inside `root` (a bare prefix check would let
/// `/dist-evil` pass for root `/dist`).
function followsFrom(root: string, full: string): boolean {
  const prefix = root.endsWith(path.sep) ? root : root + path.sep;
  return full === root || full.startsWith(prefix);
}

/// Serve one static asset from DIST, refusing anything that escapes it.
function serveStatic(url: string, res: http.ServerResponse): void {
  const rel = url === "/"
    ? "index.html"
    : decodeURIComponent(url.split("?")[0]).replace(/^\/+/, "");
  const full = path.resolve(DIST, rel);
  if (!followsFrom(DIST, full)) {
    res.writeHead(403).end("forbidden");
    return;
  }
  fs.readFile(full, (err, body) => {
    if (err) {
      res.writeHead(404, { "Content-Type": "text/plain" }).end("not found");
      return;
    }
    res.writeHead(200, {
      "Content-Type": MIME[path.extname(full)] ?? "application/octet-stream",
      // Rebuilds are frequent while iterating on the frontend; a stale cached
      // bundle is more confusing than the extra read.
      "Cache-Control": "no-store",
    });
    res.end(body);
  });
}

// ── broadcast ──────────────────────────────────────────────────────────────

function broadcast(payload: unknown): void {
  const wss = shell().wss;
  if (!wss) return;
  const text = JSON.stringify(payload);
  for (const client of wss.clients) {
    if (client.readyState === 1) client.send(text);
  }
}

/// Session contexts are invalidated by session replacement, and pi treats any
/// access to a stale one as a hard error that kills the process. Every UI call
/// is therefore best-effort: a missing hint must never take the server down.
function notify(message: string, type: "info" | "error" = "info"): void {
  try {
    shell().ctx?.ui.notify(message, type);
  } catch {
    /* stale context — the hint is optional */
  }
}

/// Everything a newly connected browser needs to render itself. Returns null
/// when no usable session context is bound right now.
async function snapshot(): Promise<unknown | null> {
  const ctx = shell().ctx;
  if (!ctx) return null;
  try {
    const cwd = ctx.cwd;
    return {
      kind: "history",
      cwd,
      turns: historyFromEntries(ctx.sessionManager.getBranch() as any[]),
      running: !ctx.isIdle(),
      workspaces: await listWorkspaces(cwd),
      instances: instanceList(),
    };
  } catch {
    return null;
  }
}

// ── sending ────────────────────────────────────────────────────────────────

/// Send a prompt into whichever session is currently bound.
///
/// The `ExtensionAPI` object is session-bound: after a workspace switch its
/// `sendUserMessage` targets a stale session. The context pi hands to
/// `session_start` is the authoritative binding, so prefer it when it exposes
/// its own sender.
async function sendPrompt(text: string): Promise<void> {
  const s = shell();
  const ctx: any = s.ctx;
  const api = s.api;
  if (!ctx && !api) throw new Error("no live session context");

  let idle = false;
  try {
    idle = ctx ? ctx.isIdle() : true;
  } catch {
    idle = true;
  }
  const options = idle ? undefined : { deliverAs: "steer" as const };

  if (ctx && typeof ctx.sendUserMessage === "function") {
    await ctx.sendUserMessage(text, options);
    return;
  }
  api!.sendUserMessage(text, options);
}

// ── WebSocket handling ─────────────────────────────────────────────────────

async function onClientMessage(raw: unknown): Promise<void> {
  let msg: any;
  try {
    msg = JSON.parse(String(raw));
  } catch {
    return;
  }
  const s = shell();
  if (!s.ctx && !s.api) {
    dbg(`dropped ${msg?.kind}: no live context`);
    return;
  }

  switch (msg?.kind) {
    case "prompt": {
      const text = String(msg.text ?? "").trim();
      if (!text) return;
      try {
        await sendPrompt(text);
        dbg("prompt delivered");
      } catch (err) {
        dbg(`prompt FAILED: ${(err as Error).message}`);
        broadcast({ kind: "error", message: `发送失败: ${(err as Error).message}` });
      }
      return;
    }
    case "workspaces": {
      try {
        broadcast({
          kind: "workspaces",
          workspaces: await listWorkspaces(s.ctx?.cwd ?? ""),
        });
      } catch {
        /* stale or unreadable session list */
      }
      return;
    }
    case "switch": {
      const session = String(msg.session ?? "");
      if (!session) return;
      // `switchSession` only exists on a command context, so dispatch through
      // the extension command registered below.
      try {
        s.api?.sendUserMessage(`/web-switch ${session}`, {
          expandPromptTemplates: true,
        });
        dbg(`switch dispatched -> ${session}`);
      } catch (err) {
        dbg(`switch FAILED: ${(err as Error).message}`);
      }
      return;
    }
  }
}

/// Create the server once per process, on first use.
function ensureServer(): http.Server {
  const s = shell();
  if (s.server) return s.server;

  const server = http.createServer((req, res) => serveStatic(req.url ?? "/", res));

  const wss = new WebSocketServer({ server, path: WS_PATH });
  wss.on("connection", (ws: WebSocket) => {
    dbg("browser connected");
    snapshot().then((snap) => {
      if (snap && ws.readyState === 1) ws.send(JSON.stringify(snap));
    });
    ws.on("message", (raw) => {
      void onClientMessage(raw).catch(() => {
        /* a stale context must not crash the process */
      });
    });
  });

  // A permanent handler: any 'error' event on a listening server that nobody
  // consumes takes the whole pi process down.
  server.on("error", (err: NodeJS.ErrnoException) => {
    dbg(`server error: ${err.message}`);
    notify(`pi-web-shell: ${err.message}`, "error");
    s.server = null;
    s.wss = null;
    s.port = null;
  });

  s.server = server;
  s.wss = wss;

  findFreePort()
    .then((port) => {
      server.listen(port, "127.0.0.1", () => {
        s.port = port;
        registerSelf(s.ctx?.cwd ?? "", port);
        dbg(`listening on ${port}`);
        notify(`pi-web-shell → http://127.0.0.1:${port}`);
      });
    })
    .catch((err: Error) => {
      const busy = liveInstances()
        .map((i) => `  ${i.port}  pid ${i.pid}  ${i.cwd}`)
        .join("\n");
      dbg(`bind failed: ${err.message}`);
      notify(
        `pi-web-shell 无法启动: ${err.message}` +
          (busy ? `\n当前占用:\n${busy}` : ""),
        "error",
      );
      s.server = null;
      s.wss = null;
    });

  return server;
}

/// Is `port` bindable right now?
///
/// Probed on a throwaway listener rather than by retrying `listen` on the real
/// server: a failed listen there emits an 'error' that is easy to leave
/// unhandled, and re-listening on the same instance is fiddly.
function probeFree(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const probe = net.createServer();
    probe.once("error", () => resolve(false));
    probe.once("listening", () => probe.close(() => resolve(true)));
    probe.listen(port, "127.0.0.1");
  });
}

/// First free port in the range. A second pi process in another directory must
/// not lose its UI just because the first one holds the base port.
async function findFreePort(): Promise<number> {
  for (let port = PORT_BASE; port < PORT_BASE + PORT_TRIES; port++) {
    if (await probeFree(port)) return port;
  }
  throw new Error(`在 ${PORT_BASE}..${PORT_BASE + PORT_TRIES - 1} 内没有空闲端口`);
}

export default function (pi: ExtensionAPI) {
  const s = shell();

  // Runs once per process even though the factory may run again after a
  // workspace switch; `once` keeps it from stacking handlers.
  process.once("exit", unregisterSelf);
  s.generation += 1;
  s.api = pi;
  dbg(`FACTORY called generation=${s.generation}`);

  // A command is the only place pi hands out a command context, which is what
  // carries the session-control methods.
  pi.registerCommand("web-switch", {
    description: "Internal: switch the web shell to another workspace session",
    handler: async (args, ctx) => {
      const sessionPath = args.trim();
      if (!sessionPath) return;
      const result = await ctx.switchSession(sessionPath, {
        withSession: async (next) => {
          // Belt and braces: the replacement instance also receives
          // session_start, but rebinding here closes the gap immediately.
          shell().ctx = next as unknown as ExtensionContext;
          touchSelf(next.cwd);
          dbg(`withSession rebound cwd=${next.cwd}`);
        },
      });
      if (result.cancelled) broadcast({ kind: "error", message: "切换工作区被取消" });
    },
  });

  pi.on("session_start", async (event, ctx) => {
    const sh = shell();
    sh.ctx = ctx;
    dbg(
      `session_start reason=${(event as any).reason} cwd=${ctx.cwd} ` +
        `serverExists=${!!sh.server} gen=${sh.generation}`,
    );

    const firstConnect = !sh.server;
    ensureServer();
    touchSelf(ctx.cwd);

    if (!firstConnect) {
      // A workspace switch: push the new session to everyone already watching.
      const snap = await snapshot();
      const workspaces = await listWorkspaces(ctx.cwd).catch(() => []);
      broadcast({
        kind: "workspace_changed",
        cwd: ctx.cwd,
        ...(snap as any),
        workspaces,
        instances: instanceList(),
      });
    }
  });

  // Deliberately neither closes the server nor clears the context: a workspace
  // switch fires this, and the replacement binding only arrives afterwards.
  pi.on("session_shutdown", async (event) => {
    dbg(`session_shutdown reason=${(event as any).reason}`);
  });

  pi.on("message_end", async (event) => {
    const msg: any = (event as any).message;
    if (msg?.role !== "user") return;
    const text = textOf(msg).trim();
    if (text) broadcast({ kind: "turn", user: text, blocks: [] });
  });

  pi.on("turn_end", async (event) => {
    const ev: any = event;
    const blocks = blocksFromAssistant(ev.message, ev.toolResults ?? []);
    if (blocks.length) broadcast({ kind: "turn", user: null, blocks });
  });

  pi.on("agent_start", async () => broadcast({ kind: "status", running: true }));
  pi.on("agent_end", async () => broadcast({ kind: "status", running: false }));
}
