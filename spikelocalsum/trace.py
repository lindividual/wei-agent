#!/usr/bin/env python3
"""A per-request trace of what the trim boundary costs, to show *why* it costs.

`rig` prints one line per policy for a whole session. This prints one line per
**request**, which is the only view in which the mechanism is visible: a single
boundary move breaks the provider's byte prefix, and every byte after the break is
billed again at the fresh-input rate.

The two policies are the shipped one and #0:

    shipped   recent_window 20, advance_step 8
    #0        recent_window  2, advance_step 1

`cutoff(n) = max(0, n - window) // step * step`, from `core/trim.mbt::trim_cutoff`.
A message at index `i` is carried verbatim in a request of length `k` iff
`i >= cutoff(k)`; before that, a tool result over 4 KB is cut to its first 40 and
last 20 lines and old reasoning is blanked.

Bytes are the JSON encoding of the message array, which is how the driver builds the
body. That is an approximation of the wire bytes (key order, escaping), so the
absolute tokens here are not the bill -- the **shape** is: which request pays fresh
and how many bytes, and the ratio between the two policies. `--check` prints the
per-session totals next to what `rig` reports for the same session, so the model
behind the illustration can be audited rather than believed.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regret import cutoff, split_kept_dropped, SHIPPED_WINDOW, SHIPPED_STEP, \
    TARGET_WINDOW, TARGET_STEP, TOOL_RESULT_LIMIT, HEAD_LINES, TAIL_LINES

INPUT = 0.14 / 1e6
CACHE = 0.0028 / 1e6


def walk_path(entries):
    """The conversation is the parent chain from the last entry, not the file order.

    Same rule as `core/session_context.mbt::Session::path`, and the same one
    `corpus.py` uses -- reading the file in order would invent messages the provider
    never saw.
    """
    by_id = {}
    for e in entries:
        eid = e.get("id")
        if eid:
            by_id[eid] = e
    if not by_id:
        return []
    path = []
    cursor = entries[-1].get("id")
    seen = set()
    while cursor and cursor in by_id and cursor not in seen:
        seen.add(cursor)
        path.append(by_id[cursor])
        cursor = by_id[cursor].get("parentId")
    path.reverse()
    return path


def load_session(path):
    entries = []
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return walk_path(entries)


def message_of(entry):
    """(role, text, is_tool_result, thinking_bytes) as the provider would see it."""
    kind = entry.get("type") or entry.get("kind") or ""
    message = entry.get("message") or {}
    role = message.get("role") or entry.get("role")
    blocks = message.get("content")
    text = ""
    if isinstance(blocks, list):
        for b in blocks:
            if isinstance(b, dict):
                if b.get("type") in ("text", "thinking"):
                    text += b.get("text") or ""
            elif isinstance(b, str):
                text += b
    elif isinstance(blocks, str):
        text = blocks
    if not text:
        text = entry.get("summary") or ""
    omp = entry.get("omp") or entry.get("data") or {}
    if isinstance(omp, dict) and omp.get("text") and not text:
        text = omp["text"]
    return {
        "role": role,
        "text": text,
        "tool": role == "toolResult" or entry.get("type") == "toolResult",
        "thinking_bytes": len(text.encode("utf-8")) if role == "assistant" else 0,
    }


def trim_tool_result(text):
    """`core/trim.mbt::trim_text`, exactly: head + omission line + tail."""
    raw = text.split("\n")
    if raw and raw[-1] == "":
        raw = raw[:-1]
    total = len(raw)
    kept = HEAD_LINES + TAIL_LINES
    if total <= kept + 1:
        return text
    omitted = total - kept
    out = "\n".join(raw[:HEAD_LINES])
    out += "\n… %d of %d lines omitted, re-read the file if you need them …\n" % (
        omitted, total)
    out += "\n".join(raw[total - TAIL_LINES:])
    return out


def body_for(messages, window, step, upto):
    """The message array a request of length `upto` would carry under a policy."""
    cut = cutoff(upto, window, step)
    out = []
    for i in range(upto):
        m = messages[i]
        text = m["text"]
        if i < cut:
            if m["tool"] and len(text.encode("utf-8")) > TOOL_RESULT_LIMIT:
                text = trim_tool_result(text)
            elif m["role"] == "assistant":
                text = ""  # drop_old_thinking
        out.append({"role": m["role"], "content": text})
    return json.dumps(out, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def common_prefix(a, b):
    n = min(len(a), len(b))
    if a[:n] == b[:n]:
        return n
    lo, hi = 0, n
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if a[:mid] == b[:mid]:
            lo = mid
        else:
            hi = mid - 1
    return lo


def request_points(messages):
    """The `upto` index of every request, in order.

    A request is sent before each assistant message and carries everything before it,
    which is how `rig` counts and how the provider billed: it is the number of
    assistant messages in the chain, not the number of messages.
    """
    return [i for i, m in enumerate(messages) if m["role"] == "assistant"]


def trace(messages, window, step, label, limit):
    points = request_points(messages)
    print("── %s: recent_window %d, advance_step %d" % (label, window, step))
    print("%5s %6s %8s %9s %9s %8s %8s %10s" % (
        "req", "cutoff", "body KB", "reused KB", "fresh tok", "moved",
        "$ this", "$ total"))
    previous = b""
    prev_cut = None
    total = 0.0
    rows = []
    for n, upto in enumerate(points):
        k = n + 1
        cut = cutoff(upto, window, step)
        body = body_for(messages, window, step, upto)
        prefix = 0 if k == 1 else common_prefix(body, previous)
        fresh = (len(body) - prefix) / 4.0
        cache = prefix / 4.0
        cost = fresh * INPUT + cache * CACHE
        total += cost
        # The boundary moved iff the cutoff advanced: that is the only way a message
        # that was carried verbatim becomes a trimmed one.
        moved = prev_cut is not None and cut > prev_cut
        rows.append((k, cut, len(body), prefix, fresh, cost, total, moved))
        previous = body
        prev_cut = cut
    shown = rows[:4] + [r for r in rows[4:] if r[7]][:limit] + rows[-2:]
    seen = set()
    for row in shown:
        k, cut, size, prefix, fresh, cost, tot, moved = row
        if k in seen:
            continue
        seen.add(k)
        print("%5d %6d %8.1f %9.1f %9.0f %8s %8.5f %10.4f%s" % (
            k, cut, size / 1024, prefix / 1024, fresh,
            "yes" if moved else "no", cost, tot, "  *" if moved else ""))
    print("%5s %6s %8s %9s %9s %8s %8s %10.4f" % (
        "", "", "", "", "", "", "TOTAL", total))
    bodies = [r[2] for r in rows]
    moves = sum(1 for r in rows if r[7])
    fresh_total = sum(r[4] for r in rows)
    print("    body %.1f KB/request | fresh %.0f tok/request | %d boundary moves | %s fresh tok total"
          % (sum(bodies) / len(bodies) / 1024, fresh_total / len(rows), moves,
             format(int(fresh_total), ",")))
    print()
    return total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("session")
    parser.add_argument("--rows", type=int, default=14,
                        help="how many rewriting requests to show")
    parser.add_argument("--check", action="store_true",
                        help="totals only, for comparing against rig")
    args = parser.parse_args()

    entries = load_session(args.session)
    messages = [message_of(e) for e in entries]
    messages = [m for m in messages if m["role"]]
    print("%s" % os.path.basename(args.session))
    print("%d messages in the chain, %d KB of it tool output" % (
        len(messages),
        sum(len(m["text"].encode("utf-8")) for m in messages if m["tool"]) // 1024))
    print()

    a = trace(messages, SHIPPED_WINDOW, SHIPPED_STEP, "shipped", args.rows)
    b = trace(messages, TARGET_WINDOW, TARGET_STEP, "#0", args.rows)

    print("shipped $%.4f   #0 $%.4f   #0 saves %.1f%%" % (
        a, b, 100 * (a - b) / a if a else 0))
    if args.check:
        print("(rig reports the same session in its own table; compare the ratios)")


if __name__ == "__main__":
    main()
