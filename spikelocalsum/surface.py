#!/usr/bin/env python3
"""How much context is there to compress, and how much of it survives trimming?

This is the measurement that decides whether a local model has anything to bite
on, and it needs no model. It re-implements the trimming in `core/trim.mbt`
faithfully — same thresholds, same quantized boundary, same line keep budget —
and reports four things:

  1. where the mass is, by role
  2. what trimming already removes for free
  3. what is left for a model to compress, broken down by tool result size
  4. how much of what is left is literal repetition, which a rule can catch

Token figures use the repository's own heuristic (bytes / 4), because the point is
to compare policies against each other, not to predict a bill.
"""

import argparse
import collections
import json
import os

# core/trim.mbt::TrimPolicy::default()
RECENT_WINDOW = 20
ADVANCE_STEP = 8
TOOL_RESULT_LIMIT = 4 * 1024
HEAD_LINES = 40
TAIL_LINES = 20


def trim_cutoff(length):
    released = max(0, length - RECENT_WINDOW)
    if ADVANCE_STEP <= 1:
        return released
    return released // ADVANCE_STEP * ADVANCE_STEP


def trim_text(text):
    """core/trim.mbt::trim_text, in bytes rather than UTF-8 code units."""
    if len(text.encode("utf-8")) <= TOOL_RESULT_LIMIT:
        return text
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    total = len(lines)
    kept = HEAD_LINES + TAIL_LINES
    if total <= kept + 1:
        return text
    omitted = total - kept
    kb = len(text.encode("utf-8")) // 1024
    marker = "\n… %d of %d lines omitted (%d KB total), re-read the file if you need them …\n\n" % (
        omitted, total, kb,
    )
    return "\n".join(lines[:HEAD_LINES]) + marker + "\n".join(lines[total - TAIL_LINES:]) + "\n"


def load(path):
    by_session = collections.OrderedDict()
    with open(path) as fh:
        for line in fh:
            record = json.loads(line)
            by_session.setdefault(record["session"], []).append(record)
    return by_session


def mb(n):
    return "%.2f MB" % (n / 1e6)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data", "messages.jsonl"))
    args = parser.parse_args()

    sessions = load(args.data)
    print("sessions: %d, messages: %d\n" % (len(sessions), sum(len(v) for v in sessions.values())))

    # ---- 1. where the mass is, before trimming -------------------------------
    raw = collections.Counter()
    raw_bytes = collections.Counter()
    for records in sessions.values():
        for r in records:
            key = "thinking" if r["role"] == "assistant" and r["thinking_bytes"] else r["role"]
            raw[key] += 1
            raw_bytes[key] += r["thinking_bytes"] if key == "thinking" else r["text_bytes"]
    total_raw = sum(raw_bytes.values())
    print("1. mass before trimming")
    for key, n in raw.most_common():
        b = raw_bytes[key]
        print("   %-14s %6d msgs  %10s  %5.1f%%" % (key, n, mb(b), 100 * b / total_raw))
    print("   %-14s %6s        %10s" % ("total", "", mb(total_raw)))

    # ---- 2. what trimming removes for free -----------------------------------
    before = collections.Counter()
    after = collections.Counter()
    for records in sessions.values():
        cutoff = trim_cutoff(len(records))
        for i, r in enumerate(records):
            trimmed = i < cutoff
            role = r["role"]
            if role == "toolResult":
                before["toolResult"] += r["text_bytes"]
                after["toolResult"] += len(trim_text(r["text"]).encode("utf-8")) if trimmed else r["text_bytes"]
            elif role == "assistant":
                before["thinking"] += r["thinking_bytes"]
                after["thinking"] += 0 if trimmed else r["thinking_bytes"]
                before["assistant text"] += r["text_bytes"]
                after["assistant text"] += r["text_bytes"]
            else:
                before[role] += r["text_bytes"]
                after[role] += r["text_bytes"]
    total_after = sum(after.values())
    print("\n2. after trimming (policy as shipped)")
    for key in before:
        b, a = before[key], after[key]
        saved = 100 * (1 - a / b) if b else 0
        print("   %-14s %10s -> %10s   (-%.0f%%)" % (key, mb(b), mb(a), saved))
    print("   %-14s %10s -> %10s   (-%.0f%%)" % (
        "total", mb(sum(before.values())), mb(total_after),
        100 * (1 - total_after / sum(before.values())),
    ))

    # ---- 3. what is left, by tool result size --------------------------------
    # The size buckets matter because trimming's threshold is what decides whether
    # a result is touched at all: anything under 4 KB is sent verbatim forever.
    buckets = [(0, 1024), (1024, 4096), (4096, 16384), (16384, 65536), (65536, 1 << 30)]
    labels = ["< 1 KB", "1-4 KB", "4-16 KB", "16-64 KB", "> 64 KB"]
    count = [0] * len(buckets)
    mass = [0] * len(buckets)
    surviving = [0] * len(buckets)
    recent_mass = 0
    for records in sessions.values():
        cutoff = trim_cutoff(len(records))
        for i, r in enumerate(records):
            if r["role"] != "toolResult":
                continue
            size = r["text_bytes"]
            for b, (lo, hi) in enumerate(buckets):
                if lo <= size < hi:
                    count[b] += 1
                    mass[b] += size
                    surviving[b] += len(trim_text(r["text"]).encode("utf-8")) if i < cutoff else size
                    break
            if i >= cutoff:
                recent_mass += size
    print("\n3. tool results by size (bytes that survive trimming)")
    print("   %-9s %8s %12s %14s %8s" % ("bucket", "count", "total", "after trim", "kept%"))
    for b, label in enumerate(labels):
        kept = 100 * surviving[b] / mass[b] if mass[b] else 0
        print("   %-9s %8d %12s %14s %7.0f%%" % (label, count[b], mb(mass[b]), mb(surviving[b]), kept))
    tool_after = sum(surviving)
    print("   %-9s %8s %12s %14s" % ("all", "", mb(sum(mass)), mb(tool_after)))
    print("\n   tool output still in the prompt: %s of %s total (%.1f%%)" % (
        mb(tool_after), mb(total_after), 100 * tool_after / total_after,
    ))
    print("   of that, inside the untouched recent window: %s (%.0f%%)" % (
        mb(recent_mass), 100 * recent_mass / tool_after,
    ))

    # ---- 4. how much of what is left is literal repetition -------------------
    # An exact repeat is provably removable without a model, so it brackets what a
    # model could add on this axis.
    repeat_bytes = 0
    repeat_count = 0
    for records in sessions.values():
        seen = {}
        for r in records:
            if r["role"] != "toolResult" or not r["text"]:
                continue
            digest = hash(r["text"])
            if digest in seen:
                repeat_bytes += r["text_bytes"]
                repeat_count += 1
            else:
                seen[digest] = True
    print("\n4. literal repetition within a session")
    print("   repeated tool results: %d, %s (%.1f%% of surviving tool output)" % (
        repeat_count, mb(repeat_bytes), 100 * repeat_bytes / tool_after if tool_after else 0,
    ))

    # ---- 5. what a request actually looks like --------------------------------
    sizes = sorted(
        sum(
            (r["text_bytes"] + (0 if r["role"] == "assistant" and r["thinking_bytes"] else 0))
            for r in records
        )
        for records in sessions.values()
    )
    if sizes:
        middle = sizes[len(sizes) // 2]
        print("\n5. conversation size (bytes/4 as tokens, per session)")
        print("   min %s  median %s  max %s" % (
            mb(sizes[0]), mb(middle), mb(sizes[-1]),
        ))


if __name__ == "__main__":
    main()
