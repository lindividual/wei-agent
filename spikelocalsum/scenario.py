#!/usr/bin/env python3
"""What is left after the free reductions, and is a model worth spending on it?

`surface.py` shows trimming already removes half the context for nothing. This one
asks the follow-up question, which is the only one that matters for a local model:
**of the bytes trimming leaves, how much is a model the only way to get at, and what
does the answer depend on?**

The split it computes is by whether a rule can already reach the bytes:

  in-window        inside `recent_window`, so trimming is not allowed to touch it.
                   Not reachable by trimming at any setting; only by making the
                   window smaller, which costs correctness rather than money.
  under-threshold  a result smaller than the 4 KB limit. Trimming ignores these
                   entirely — the marker would cost more than the bytes — so this
                   is the only population where a reduction is *purely* new.
  head-and-tail    the part of an over-threshold result that trimming already
                   keeps. A digest would replace it with less.

The economics follow from the split, and they are not what "compress the context"
suggests. Ship the model and the marginal saving is the under-threshold population
plus whatever a digest drops out of the head and tail. Everything else trimming
already took for free.

The costs are then two, and neither is dollars:

  latency   one local inference per compressed result, on the tool path
  risk      the bytes are gone from the prompt after the digest replaces them, and
            `recent_window` is only 20 messages. Regret is unavoidable; the only
            question is whether the compressed bytes are ever needed again.

`--regret-probability` parameterises the second, because it cannot be measured from
logs alone — a session that would have failed is not in the corpus. What can be
measured is the *size* of the exposure, and that is what this file reports.
"""

import argparse
import collections
import json
import os

# core/trim.mbt::TrimPolicy::default()
RECENT_WINDOW = 20
ADVANCE_STEP = 8
TOOL_RESULT_LIMIT = 4 * 1024

# The floor the rig's `freeze-*` policies use, so the two agree on what a
# compression candidate is.
DIGEST_FLOOR = 1024

# The difference calibration measured by `spikelocalsum/rig`: the recorded bill is
# this many tokens per token the bytes/4 estimator predicts. Below 1 would mean the
# estimator over-counts; it does not.
TOKENS_PER_ESTIMATE = 1.07

# core/model_catalog.mbt, USD per million tokens.
INPUT = 0.14
CACHE_READ = 0.0028


def cutoff(length):
    released = max(0, length - RECENT_WINDOW)
    return released // ADVANCE_STEP * ADVANCE_STEP


def load(path):
    sessions = collections.OrderedDict()
    with open(path) as fh:
        for line in fh:
            record = json.loads(line)
            sessions.setdefault(record["session"], []).append(record)
    return sessions


def buckets():
    return collections.Counter()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data", "messages.jsonl"))
    parser.add_argument("--regret-probability", type=float, default=0.05,
                        help="chance a compressed-away result is needed again before it leaves the window")
    parser.add_argument("--latency-ms", type=float, default=0.0,
                        help="measured per-call latency, from score.py")
    args = parser.parse_args()

    sessions = load(args.data)

    # Byte mass of every tool result, by whether a free rule already reaches it.
    mass = buckets()
    count = buckets()
    # What each request would carry after trimming, and after a hypothetical perfect
    # compression of the under-threshold population.
    requests = 0
    trimmed_bytes = 0
    perfect_bytes = 0
    # The bytes a model would have to read to produce those digests: the unit of work.
    model_input = 0
    model_calls = 0

    for records in sessions.values():
        n = len(records)
        cut = cutoff(n)
        for i, record in enumerate(records):
            if record["role"] != "toolResult":
                continue
            size = record["text_bytes"]
            where = "in-window" if i >= cut else (
                "under-threshold" if size <= TOOL_RESULT_LIMIT else "head-and-tail")
            mass[where] += size
            count[where] += 1

        # A request happens before each assistant message and carries everything
        # before it, with the boundary where trimming would put it at that length.
        for k, record in enumerate(records):
            if record["role"] != "assistant":
                continue
            here = cutoff(k)
            requests += 1
            carried = 0
            carried_perfect = 0
            for i in range(k):
                r = records[i]
                size = r["text_bytes"] + (
                    r["thinking_bytes"] if r["role"] == "assistant" else 0)
                if i < here:
                    # Trimmed: thinking blanked, an over-threshold result cut to its
                    # marker plus head and tail. The marker and the kept lines are
                    # small; the estimate here is a fifth of the original, which is
                    # what `surface.py` measured for the surviving share.
                    if r["role"] == "assistant":
                        size = 0
                    elif size > TOOL_RESULT_LIMIT:
                        size = size // 5
                carried += size
                # A perfect digest of the under-threshold population only.
                if r["role"] == "toolResult" and i < here and size <= TOOL_RESULT_LIMIT:
                    carried_perfect += 64
                else:
                    carried_perfect += size
            trimmed_bytes += carried
            perfect_bytes += carried_perfect

    total = sum(mass.values())
    print("tool result bytes: %s over %d results\n" % (
        "{:,}".format(total), sum(count.values())))
    print("%-18s %8s %14s %8s" % ("reachable by", "count", "bytes", "share"))
    print("-" * 52)
    for where in ("in-window", "under-threshold", "head-and-tail"):
        print("%-18s %8d %14s %7.1f%%" % (
            where, count[where], "{:,}".format(mass[where]),
            100 * mass[where] / total if total else 0,
        ))

    print()
    print("which is to say, of the bytes trimming leaves in the prompt:")
    freed = 100 * (1 - trimmed_bytes / (trimmed_bytes + sum(
        m for w, m in mass.items() if w != "in-window"))) if trimmed_bytes else 0
    ignore = freed  # reported by surface.py, kept here only for the reader

    for where in ("under-threshold", "head-and-tail", "in-window"):
        print("  %-18s %6.1f%%  %s" % (
            where, 100 * mass[where] / total if total else 0,
            {
                "under-threshold": "only a model can reach it; trimming never touches these",
                "head-and-tail": "trimming already keeps these lines; a digest would replace them",
                "in-window": "trimming is not allowed here; only a smaller window reaches it",
            }[where],
        ))

    # The unit of work, and the size of the exposure.
    for records in sessions.values():
        for record in records:
            if record["role"] == "toolResult" and record["text_bytes"] > DIGEST_FLOOR:
                model_calls += 1
                model_input += min(record["text_bytes"], 6 * 1024)

    print()
    print("the work a model would be given")
    print("  calls                 %s results over %d KB" % (
        "{:,}".format(model_calls), model_input // 1024))
    if args.latency_ms:
        total_ms = model_calls * args.latency_ms
        print("  latency               %.1f s at %.0f ms/call, spread over the session" % (
            total_ms / 1000, args.latency_ms))
        print("  on the tool path      a turn that fires k of these waits k x %.0f ms" % args.latency_ms)

    # The exposure: bytes that would be dropped and could later be wanted.
    dropped = sum(
        record["text_bytes"]
        for records in sessions.values()
        for i, record in enumerate(records)
        if record["role"] == "toolResult"
        and record["text_bytes"] > TOOL_RESULT_LIMIT
        and i < cutoff(len(records))
    )
    print()
    print("the exposure")
    print("  bytes dropped by a marker-level digest: %s" % "{:,}".format(dropped))
    print("  probability a dropped result is needed again before it leaves the window")
    print("  is the one number no log can supply — a session that would have failed is")
    print("  not in the corpus. At p=%.2f the expected re-acquisition is %s bytes, each" % (
        args.regret_probability,
        "{:,}".format(int(dropped * args.regret_probability))))
    print("  of which comes back as a fresh read at the input rate, not the cache rate.")
    # The breakeven, stated as a ratio rather than a dollar figure: the dropped bytes
    # were going to be re-sent on every remaining request at the cache rate, so the
    # saving is (requests remaining) x bytes x CACHE_READ, and the regret is
    # (probability) x bytes x INPUT once. With INPUT 50x CACHE_READ, the digest wins
    # as long as p x 50 is less than the number of requests the result would have
    # survived — which, with a 20-message window on a conversation that makes 380
    # requests, is comfortably true. That is the argument for a marker-level digest,
    # not against it.
    ratio = INPUT / CACHE_READ
    print()
    print("  breakeven: a re-read costs %.0fx what the dropped bytes cost per request," % ratio)
    print("  and a result in the prompt is re-sent once per remaining request. A digest")
    print("  therefore pays whenever it saves more than %.1f requests' worth of the bytes" % (ratio / 100),
    )
    print("  it drops — true for any result that survives more than a few turns.")


if __name__ == "__main__":
    main()
