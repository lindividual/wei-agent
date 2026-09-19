#!/usr/bin/env python3
"""The risk nobody has measured: is a trimmed result *recoverable*?

`regret.py` measured whether dropped middle lines ever came back. It did not ask the
question that decides whether coming back is even possible. The marker we leave behind
says one thing for every tool:

    … N of M lines omitted, re-read the file if you need them …

That is true for `read`. It is **false for `bash`**: the output was never in a file, so
there is nothing to re-read. A trimmed command result is gone unless the command is run
again -- and a re-run is not a read: it may not be idempotent, may cost money, may be
slow, and may not reproduce at all (`git status`, a timestamp, a flaky test).

So the exposure of #0 is not one number. It splits by recoverability:

    recoverable      `read`: the model can ask for the same bytes again
    re-run only      `bash` / `exec` / `script`: only a *fresh* execution can help

This splits the middle bytes #0 drops early by tool, and totals the two. Pure log
analysis; no model, no network.
"""

import argparse
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from regret import cutoff, split_kept_dropped, load, SHIPPED_WINDOW, SHIPPED_STEP, \
    TARGET_WINDOW, TARGET_STEP, TOOL_RESULT_LIMIT

# Results that live in a file the model can read again.
RECOVERABLE = {"read"}
# Results that were the output of a one-off process: a re-run may differ.
RERUN_ONLY = {"bash", "exec", "script", "grep", "glob"}


def middle_bytes_by_tool(records, window, step):
    """Bytes dropped per request, keyed by tool, for one session under one policy.

    A result at index `i` contributes its middles once per request `k` where
    `i < cutoff(k)`, which is what the bill sees: it is re-sent, trimmed, on every one.
    """
    by_tool = collections.Counter()
    sizes = {}
    for k in range(1, len(records) + 1):
        cut = cutoff(k, window, step)
        for i in range(cut):
            record = records[i]
            if record["role"] != "toolResult":
                continue
            if record["text_bytes"] <= TOOL_RESULT_LIMIT:
                continue
            if i not in sizes:
                _, dropped = split_kept_dropped(record["text"])
                sizes[i] = len(dropped.encode("utf-8"))
            by_tool[record["tool_name"]] += sizes[i]
    return by_tool


def report(sessions, window, step, label):
    by_tool = collections.Counter()
    for records in sessions.values():
        by_tool.update(middle_bytes_by_tool(records, window, step))
    total = sum(by_tool.values())
    print("%s — middle bytes dropped, summed over requests: %s" % (
        label, format(total, ",")))
    print("    %-10s %16s %7s  %s" % ("tool", "bytes", "share", "recovery"))
    for tool, v in by_tool.most_common(10):
        recovery = ("re-read" if tool in RECOVERABLE else
                    "re-run only" if tool in RERUN_ONLY else "—")
        print("    %-10s %16s %6.1f%%  %s" % (
            tool, format(v, ","), 100.0 * v / total if total else 0, recovery))
    rec = sum(v for t, v in by_tool.items() if t in RECOVERABLE)
    run = sum(v for t, v in by_tool.items() if t in RERUN_ONLY)
    print("    ── re-read (same bytes available again):   %6.1f%%" % (
        100.0 * rec / total if total else 0))
    print("    ── re-run only (a *new* execution needed): %6.1f%%" % (
        100.0 * run / total if total else 0))
    print("    ── neither (note, image, unknown):         %6.1f%%" % (
        100.0 * (total - rec - run) / total if total else 0))
    print()
    return by_tool


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.path.join(
        os.path.dirname(__file__), "data", "messages.jsonl"))
    args = parser.parse_args()

    sessions = load(args.data)
    print("sessions %d, messages %d" % (
        len(sessions), sum(len(v) for v in sessions.values())))
    print()
    shipped = report(sessions, SHIPPED_WINDOW, SHIPPED_STEP, "shipped (20/8)")
    band = report(sessions, TARGET_WINDOW, TARGET_STEP, "#0 (2/1)")

    print("The delta #0 creates, by tool (bytes that stop being verbatim a request earlier):")
    delta = collections.Counter()
    for tool in set(shipped) | set(band):
        d = band[tool] - shipped[tool]
        if d:
            delta[tool] = d
    total = sum(delta.values())
    for tool, d in delta.most_common(10):
        recovery = ("re-read" if tool in RECOVERABLE else
                    "re-run only" if tool in RERUN_ONLY else "—")
        print("    %-10s %16s %6.1f%%  %s" % (
            tool, format(d, ","), 100.0 * d / total if total else 0, recovery))
    rec = sum(v for t, v in delta.items() if t in RECOVERABLE)
    run = sum(v for t, v in delta.items() if t in RERUN_ONLY)
    print("    ── of which re-read:     %6.1f%%" % (
        100.0 * rec / total if total else 0))
    print("    ── of which re-run only: %6.1f%%" % (
        100.0 * run / total if total else 0))
    print()
    print("A re-run is not a read. The marker says \"re-read the file if you need them\"")
    print("for both, and for a bash result there is no file -- only running it again,")
    print("which may cost money, be slow, or return something else entirely.")


if __name__ == "__main__":
    main()
