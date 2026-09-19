#!/usr/bin/env python3
"""Pull the model-visible conversation out of real session logs.

The output is one JSONL record per model-visible message, in conversation order,
with the fields the surface measurement needs. It re-derives the context the same
way `core/session_context.mbt::context_entries` does — newest compaction wins —
so the message stream here is the one a request would actually carry.

Reads `~/.wei/sessions` (or `--store`). Never writes there.
"""

import argparse
import glob
import json
import os
import sys


def load_entries(path):
    entries = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return entries


def walk_path(entries):
    """The conversation is a chain, not the file.

    `core/session_context.mbt::Session::path` walks parent links from the *last*
    entry, so a message that was edited away, or a branch the reader left, is in
    the file but never in a prompt. Reading the file in order instead would invent
    messages the provider never saw — and every prefix comparison downstream would
    be against a conversation that did not happen.
    """
    by_id = {e.get("id"): e for e in entries if e.get("id")}
    if not entries:
        return []
    current = entries[-1].get("id")
    seen = set()
    reversed_path = []
    while current is not None and current in by_id and current not in seen:
        seen.add(current)
        entry = by_id[current]
        reversed_path.append(entry)
        current = entry.get("parentId")
    reversed_path.reverse()
    return reversed_path


def context_entries(entries):
    """Newest compaction replaces everything before its kept entry."""
    cut_at = None
    for i in range(len(entries) - 1, -1, -1):
        if entries[i].get("type") == "compaction":
            cut_at = i
            break
    if cut_at is None:
        return entries
    compaction = entries[cut_at]
    first_kept = compaction.get("firstKeptEntryId")
    out = [compaction]
    keeping = False
    for i in range(cut_at):
        if entries[i].get("id") == first_kept:
            keeping = True
        if keeping:
            out.append(entries[i])
    out.extend(entries[cut_at + 1:])
    return out


def blocks_of(message):
    for block in message.get("content") or []:
        if isinstance(block, dict):
            yield block


def messages_of(session_id, entries):
    """One record per model-visible message, in order."""
    index = 0
    for entry in context_entries(walk_path(entries)):
        kind = entry.get("type")
        if kind == "message":
            message = entry.get("message") or {}
            role = message.get("role")
            text = "\n".join(
                b.get("text", "") for b in blocks_of(message) if b.get("type") == "text"
            )
            thinking = "\n".join(
                b.get("thinking", "")
                for b in blocks_of(message)
                if b.get("type") == "thinking"
            )
            calls = [
                {"id": b.get("id"), "name": b.get("name"), "arguments": b.get("arguments")}
                for b in blocks_of(message)
                if b.get("type") == "toolCall"
            ]
            yield {
                "session": session_id,
                "index": index,
                "entry_id": entry.get("id"),
                "role": role,
                "tool_name": message.get("toolName"),
                "tool_call_id": message.get("toolCallId"),
                "is_error": bool(message.get("isError")),
                "text": text,
                "text_bytes": len(text.encode("utf-8")),
                "thinking_bytes": len(thinking.encode("utf-8")),
                "thinking": thinking if thinking else None,
                "calls": calls or None,
                "cwd": message.get("cwd"),
                "usage": message.get("usage"),
            }
            index += 1
        elif kind == "compaction":
            summary = entry.get("summary") or ""
            yield {
                "session": session_id,
                "index": index,
                "entry_id": entry.get("id"),
                "role": "compactionSummary",
                "tool_name": None,
                "tool_call_id": None,
                "is_error": False,
                "text": summary,
                "text_bytes": len(summary.encode("utf-8")),
                "thinking_bytes": 0,
                "thinking": None,
                "calls": None,
                "cwd": None,
                "usage": None,
                "tokens_before": entry.get("tokensBefore"),
            }
            index += 1
        # model_change / thinking_level_change / custom: not conversation.


# The threshold above which a result is a compression candidate, from
# core/trim.mbt::TrimPolicy::default().tool_result_limit. Below it the marker
# would cost more than the bytes saved, so nothing is done there either by
# trimming or by a model.
CANDIDATE_FLOOR = 1024

# A hard ceiling on what one call is given, because the local model's session is
# small (4,096 tokens on Apple's on-device model). Longer inputs are cut here
# rather than by the model, so the truncation is a fact in the record instead of
# a silent effect of the window.
CANDIDATE_CEILING = 6 * 1024


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", default=os.path.expanduser("~/.wei/sessions"))
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "data"))
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    files = sorted(glob.glob(os.path.join(args.store, "**", "*.jsonl"), recursive=True))
    if not files:
        sys.exit("no session files under %s" % args.store)

    target = os.path.join(args.out, "messages.jsonl")
    candidates = os.path.join(args.out, "candidates.jsonl")
    sessions = 0
    records = 0
    chosen = 0
    chosen_bytes = 0
    with open(target, "w") as out, open(candidates, "w") as cand:
        for path in files:
            entries = load_entries(path)
            if not entries:
                continue
            sessions += 1
            session_id = os.path.splitext(os.path.basename(path))[0]
            for record in messages_of(session_id, entries):
                out.write(json.dumps(record) + "\n")
                records += 1
                if record["role"] != "toolResult":
                    continue
                size = record["text_bytes"]
                if size < CANDIDATE_FLOOR or not record["text"].strip():
                    continue
                body = record["text"]
                if len(body.encode("utf-8")) > CANDIDATE_CEILING:
                    # Cut on a line boundary, and say so.
                    body = body.encode("utf-8")[:CANDIDATE_CEILING].decode("utf-8", "ignore")
                    body = body.rsplit("\n", 1)[0]
                cand.write(json.dumps({
                    "id": "%s#%d" % (record["session"], record["index"]),
                    "session": record["session"],
                    "index": record["index"],
                    "tool": record["tool_name"],
                    "is_error": record["is_error"],
                    "bytes": size,
                    "truncated": size > CANDIDATE_CEILING,
                    "text": body,
                }) + "\n")
                chosen += 1
                chosen_bytes += size
    print("sessions: %d" % sessions)
    print("messages: %d -> %s" % (records, target))
    print("candidates: %d (%d bytes over %d) -> %s" % (
        chosen, chosen_bytes, CANDIDATE_FLOOR, candidates,
    ))


if __name__ == "__main__":
    main()
