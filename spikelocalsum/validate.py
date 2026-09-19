#!/usr/bin/env python3
"""Replay one session's requests against what the provider actually billed.

The point is to find out whether the simulation in `policies.py` is describing the
same requests the logs record. A per-request table shows where they part company:
if the simulated prompt is a steady fraction of the billed one, the estimator is
off by a constant; if it diverges over the session, the context projection is
wrong.
"""

import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from policies import cutoff, make_policies, OVERHEAD_TOKENS  # noqa: E402


def load(path):
    sessions = collections.OrderedDict()
    with open(path) as fh:
        for line in fh:
            record = json.loads(line)
            sessions.setdefault(record["session"], []).append(record)
    return sessions


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data", "messages.jsonl"))
    parser.add_argument("--session", default=None)
    parser.add_argument("--rows", type=int, default=12)
    args = parser.parse_args()

    sessions = load(args.data)
    if args.session:
        session = sessions[args.session]
    else:
        session = max(sessions.values(), key=len)
    name = args.session or max(sessions, key=lambda k: len(sessions[k]))
    print("session %s, %d messages\n" % (name, len(session)))

    policy = make_policies()[1]  # shipped
    n = len(session)
    verbatim, reduced, changed = [], [], []
    for record in session:
        size = len(record["text"].encode("utf-8"))
        if record["role"] == "assistant":
            size += record["thinking_bytes"]
        out = policy.reduce(record)
        verbatim.append(size)
        reduced.append(len(out.encode("utf-8")))
        changed.append(out != record["text"] or record["thinking_bytes"] > 0)
    pre_v = [0] * (n + 1)
    pre_r = [0] * (n + 1)
    for i in range(n):
        pre_v[i + 1] = pre_v[i] + verbatim[i]
        pre_r[i + 1] = pre_r[i] + reduced[i]

    def prompt_bytes(k, c):
        c = min(c, k)
        return pre_r[c] + (pre_v[k] - pre_v[c])

    print("%6s %10s %10s %10s %12s %12s %7s" % (
        "k", "cut", "billed-in", "billed-cache", "billed total", "sim prompt", "ratio",
    ))
    shown = 0
    totals = collections.Counter()
    for k, record in enumerate(session):
        if record["role"] != "assistant":
            continue
        usage = record["usage"]
        if not usage:
            continue
        billed = usage["input"] + usage.get("cacheRead", 0) + usage.get("cacheWrite", 0)
        c = min(cutoff(k), k)
        sim = (prompt_bytes(k, c) + 3) // 4 + OVERHEAD_TOKENS
        totals["billed"] += billed
        totals["sim"] += sim
        if shown < args.rows:
            shown += 1
            print("%6d %10d %10d %10d %12d %12d %7.2f" % (
                k, c, usage["input"], usage.get("cacheRead", 0), billed, sim,
                sim / billed if billed else 0,
            ))
    print("\ntotals: billed %s, simulated %s, ratio %.2f" % (
        "{:,}".format(totals["billed"]), "{:,}".format(totals["sim"]),
        totals["sim"] / totals["billed"] if totals["billed"] else 0,
    ))

    # Where the bytes are in the prompt the last request carried.
    last_k = max(
        k for k, r in enumerate(session) if r["role"] == "assistant" and r.get("usage")
    )
    per_role = collections.Counter()
    for i in range(last_k):
        r = session[i]
        if r["role"] == "assistant" and r["thinking_bytes"]:
            per_role["thinking"] += r["thinking_bytes"]
        else:
            per_role[r["role"]] += r["text_bytes"]
    print("\nlast prompt (k=%d), by role, as written:" % last_k)
    for role, size in per_role.most_common():
        print("  %-14s %10s" % (role, "%.2f MB" % (size / 1e6)))


if __name__ == "__main__":
    main()
