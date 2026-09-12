/**
 * pi-web-shell — serve the rabbita Web UI and bridge it to this pi session.
 *
 * The browser never talks to pi directly: this extension owns an HTTP server
 * (static assets) plus a WebSocket endpoint, translates pi's session events
 * into one normalized `turn` shape, and forwards prompts back into the agent.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { WebSocketServer, type WebSocket } from "ws";

/// Port and WebSocket path. The path must stay in sync with `WS_ID` in
/// `web/main.mbt`: rabbita's `@websocket.listen` derives `ws://<host>/<id>`.
const PORT = 7801;
const WS_PATH = "/pi";

/// Directory of the compiled rabbita bundle, relative to this extension.
const DIST = path.resolve(__dirname, "../../../dist");

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

/// Serve one static asset from DIST, refusing anything that escapes it.
function serveStatic(url: string, res: http.ServerResponse): void {
  const rel = url === "/"
    ? "index.html"
    : decodeURIComponent(url.split("?")[0]).replace(/^\/+/, "");
  const full = path.resolve(DIST, rel);
  if (!full.startsWith(DIST)) {
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
    });
    res.end(body);
  });
}

/// Every session event the browser mirrors, plus the status transitions that
/// drive the UI's running indicator.
const FORWARDED = ["message_end", "turn_end", "agent_start", "agent_end"] as const;

export default function (pi: ExtensionAPI) {
  let server: http.Server | null = null;
  let wss: WebSocketServer | null = null;

  const broadcast = (payload: unknown): void => {
    if (!wss) return;
    const text = JSON.stringify(payload);
    for (const client of wss.clients) {
      if (client.readyState === 1) client.send(text);
    }
  };

  // Background resources start here, not in the factory: the factory also
  // runs for invocations that never open a session.
  pi.on("session_start", async (_event, ctx) => {
    if (server) return;

    server = http.createServer((req, res) => serveStatic(req.url ?? "/", res));

    wss = new WebSocketServer({ server, path: WS_PATH });
    wss.on("connection", (ws: WebSocket) => {
      ws.send(
        JSON.stringify({
          kind: "history",
          turns: historyFromEntries(ctx.sessionManager.getBranch() as any[]),
          running: !ctx.isIdle(),
        }),
      );
      ws.on("message", (raw) => {
        let msg: any;
        try {
          msg = JSON.parse(raw.toString());
        } catch {
          return;
        }
        if (msg?.kind === "prompt" && typeof msg.text === "string") {
          const text = msg.text.trim();
          if (!text) return;
          // A prompt that arrives mid-run must declare a delivery mode.
          if (ctx.isIdle()) pi.sendUserMessage(text);
          else pi.sendUserMessage(text, { deliverAs: "steer" });
        }
      });
    });

    server.on("error", (err: NodeJS.ErrnoException) => {
      ctx.ui.notify(`pi-web-shell: ${err.message}`, "error");
      server = null;
      wss = null;
    });

    server.listen(PORT, "127.0.0.1", () => {
      ctx.ui.notify(`pi-web-shell → http://127.0.0.1:${PORT}`, "info");
    });
  });

  pi.on("session_shutdown", async () => {
    for (const client of wss?.clients ?? []) client.terminate();
    wss?.close();
    server?.close();
    wss = null;
    server = null;
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
