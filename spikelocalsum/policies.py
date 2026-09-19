#!/usr/bin/env python3
"""The economics of compressing tool output, under the prefix cache.

Whether a local model's digests are *good* is a separate question from whether
rewriting the prompt is *affordable*, and the second one is arithmetic. This file
answers only the second, so it needs no model.

The request model is the repository's own: the prompt is the conversation so far,
and the provider bills the part that matches the previous request's byte prefix
at the cache rate and the rest at the fresh input rate. So the only thing that
matters about a compression policy is **when a message's bytes change after they
have already been sent**.

Each message therefore has two variants — as written, and reduced — and each
request picks one per message. Trimming's rule is `index < cutoff`, and because
the cutoff moves as the conversation grows, a message can be sent one way and
then the other. A policy that reduces a message once, as it is written, has no
such transitions, and that difference is what this measures.

Usage: python3 policies.py        (after corpus.py has written data/)
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

# core/model_catalog.mbt: (input, output, cache_read) USD per million tokens.
PRICING = {
    "deepseek-v4-flash": (0.14, 0.28, 0.0028),
    "deepseek-flash": (0.3, 1.2, 0.006),
    "deepseek-v4-pro": (1.32, 3.96, 0.044),
}
PRICING_USED = "deepseek-v4-flash"

# core/context_pressure.mbt::request_overhead_tokens — system prompt plus tool
# schemas, which every request carries. README puts the measured figure at 1,314.
OVERHEAD_TOKENS = 1314


# --- reductions ---------------------------------------------------------------


def trim_reduce(text):
    """core/trim.mbt::trim_text — keep a head and a tail, drop the middle."""
    if len(text.encode("utf-8")) <= TOOL_RESULT_LIMIT:
        return text
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    total = len(lines)
    if total <= HEAD_LINES + TAIL_LINES + 1:
        return text
    omitted = total - HEAD_LINES - TAIL_LINES
    kb = len(text.encode("utf-8")) // 1024
    marker = "\n… %d of %d lines omitted (%d KB total), re-read the file if you need them …\n\n" % (
        omitted, total, kb,
    )
    return "\n".join(lines[:HEAD_LINES]) + marker + "\n".join(lines[total - TAIL_LINES:]) + "\n"


def line_frac_reduce(text, fraction, floor_bytes=1024):
    """A stand-in for what a model would return: the same shape, thinned out.

    Deterministic on purpose, so the economics can be settled before anyone argues
    about the model's quality. It keeps a head and a tail of lines and drops from
    the middle, which is roughly the shape an extractive digest has.
    """
    size = len(text.encode("utf-8"))
    if size <= floor_bytes:
        return text
    lines = text.split("\n")
    half = max(1, int(len(lines) * fraction / 2))
    if len(lines) <= 2 * half + 1:
        return text
    marker = "\n… %d lines elided by digest …\n" % (len(lines) - 2 * half)
    return "\n".join(lines[:half]) + marker + "\n".join(lines[len(lines) - half:])


def marker_reduce(text, floor_bytes=1024):
    """The floor: what dropping a result entirely would leave behind."""
    if len(text.encode("utf-8")) <= floor_bytes:
        return text
    return "… tool output elided (%d bytes, %d lines) …" % (
        len(text.encode("utf-8")), text.count("\n") + 1,
    )


# --- policies -----------------------------------------------------------------


def cutoff(length, window=RECENT_WINDOW, step=ADVANCE_STEP):
    released = max(0, length - window)
    if step <= 1:
        return released
    return released // step * step


class Policy:
    """A reduction for one message, and a rule for when it is used.

    `reduce(message) -> str` is variant B. `cutoff(prompt_length) -> int` says
    that messages below that index take variant B and the rest variant A; a
    frozen policy returns the prompt length, so every message is reduced.
    """

    def __init__(self, name, reduce, cutoff_of_length, note):
        self.name = name
        self.reduce = reduce
        self.cutoff_of_length = cutoff_of_length
        self.note = note


def tool_only(fn):
    def reduce(record):
        if record["role"] == "toolResult":
            return fn(record["text"])
        return record["text"]
    return reduce


def trim_reduce_message(record):
    if record["role"] == "toolResult":
        return trim_reduce(record["text"])
    return record["text"]  # an assistant message's thinking is dropped by the split


def make_policies():
    shipped_cutoff = lambda length: cutoff(length)
    step1_cutoff = lambda length: cutoff(length, step=1)
    frozen_cutoff = lambda length: length
    nothing_cutoff = lambda _length: 0

    return [
        Policy("raw", lambda r: r["text"], nothing_cutoff,
               "no trimming at all — the shape the bill would have without it"),
        Policy("shipped", trim_reduce_message, shipped_cutoff,
               "core/trim.mbt as it stands: reduce everything before the quantized cutoff"),
        Policy("shipped-step1", trim_reduce_message, step1_cutoff,
               "the same, with the cut moving every message — why advance_step exists"),
        Policy("freeze-trim", trim_reduce_message, frozen_cutoff,
               "the same reduction, applied once when the result is written"),
        Policy("freeze-digest-50", tool_only(lambda t: line_frac_reduce(t, 0.50)), frozen_cutoff,
               "digest everything over 1 KB to half its bytes, once"),
        Policy("freeze-digest-25", tool_only(lambda t: line_frac_reduce(t, 0.25)), frozen_cutoff,
               "digest everything over 1 KB to a quarter, once"),
        Policy("freeze-drop", tool_only(marker_reduce), frozen_cutoff,
               "the floor: anything over 1 KB becomes a marker, once"),
    ]


# --- replay -------------------------------------------------------------------


def measure(session, policy, pricing):
    """Walk one session's requests, totalling bytes, cache hits and dollars.

    A request happens before each assistant message and carries every message up
    to it. Only sizes are needed, never the bytes: whether two variants of a
    message differ, and how much the prompt costs with the cutoff at c, are both
    prefix sums.
    """
    n = len(session)
    verbatim = []
    reduced = []
    changed = []
    for record in session:
        text = record["text"]
        as_written = len(text.encode("utf-8"))
        if record["role"] == "assistant":
            as_written += record["thinking_bytes"]
        out = policy.reduce(record)
        out_bytes = len(out.encode("utf-8"))
        if record["role"] == "assistant":
            is_changed = record["thinking_bytes"] > 0 or out != text
        else:
            is_changed = out != text
        verbatim.append(as_written)
        reduced.append(out_bytes)
        changed.append(is_changed)

    pre_v = [0] * (n + 1)
    pre_r = [0] * (n + 1)
    for i in range(n):
        pre_v[i + 1] = pre_v[i] + verbatim[i]
        pre_r[i + 1] = pre_r[i] + reduced[i]

    # The first index at or after i whose two variants differ.
    nxt = [n] * (n + 1)
    for i in range(n - 1, -1, -1):
        nxt[i] = i if changed[i] else nxt[i + 1]

    def prompt_bytes(k, c):
        """Bytes of the first k messages, with the cutoff at c."""
        c = min(c, k)
        return pre_r[c] + (pre_v[k] - pre_v[c])

    raw_bytes = 0
    prompt_bytes_total = 0
    prompt_tokens_total = 0
    cache_read = 0
    fresh = 0
    requests = 0
    rewritten = 0
    prev = None
    for k, record in enumerate(session):
        if record["role"] != "assistant":
            continue
        c = min(policy.cutoff_of_length(k), k)
        nbytes = prompt_bytes(k, c)
        ptokens = (nbytes + 3) // 4 + OVERHEAD_TOKENS

        if prev is None:
            hit = 0
        else:
            prev_k, prev_c, prev_tokens = prev
            # Cutoffs never move backwards, so the only place the two requests can
            # disagree is [prev_c, c), which is also where a reduction actually
            # changed the bytes.
            j = nxt[prev_c] if prev_c < n else n
            if j >= min(c, prev_k):
                j = prev_k  # everything the previous request sent is unchanged
            hit_bytes = prompt_bytes(j, min(c, j))
            hit = min((hit_bytes + 3) // 4, prev_tokens)
            if j < prev_k:
                rewritten += 1

        fresh += ptokens - hit
        cache_read += hit
        prompt_tokens_total += ptokens
        raw_bytes += pre_v[k]
        prev = (k, c, ptokens)
        requests += 1

    p_in, _p_out, p_cache = pricing
    return {
        "requests": requests,
        "raw_bytes": raw_bytes,
        "prompt_tokens": prompt_tokens_total,
        "cache_read": cache_read,
        "fresh": fresh,
        "cost": fresh / 1e6 * p_in + cache_read / 1e6 * p_cache,
        "rewritten": rewritten,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.path.join(os.path.dirname(__file__), "data", "messages.jsonl"))
    args = parser.parse_args()

    sessions = collections.OrderedDict()
    with open(args.data) as fh:
        for line in fh:
            record = json.loads(line)
            sessions.setdefault(record["session"], []).append(record)

    total_messages = sum(len(v) for v in sessions.values())
    print("replaying %d sessions, %d messages\n" % (len(sessions), total_messages))
    print("prices: %s  (input %.2f, cache read %.4f USD/M)\n" % (
        PRICING_USED, PRICING[PRICING_USED][0], PRICING[PRICING_USED][2],
    ))

    policies = make_policies()
    results = []
    for policy in policies:
        totals = collections.Counter()
        for session in sessions.values():
            m = measure(session, policy, PRICING[PRICING_USED])
            for key in ("requests", "raw_bytes", "prompt_tokens", "cache_read", "fresh", "cost", "rewritten"):
                totals[key] += m[key]
        results.append((policy, totals))

    shipped = dict(results[1][1])
    header = "%-19s %11s %11s %11s %9s %8s %9s" % (
        "policy", "prompt tok", "cache-read", "fresh in", "USD", "rewrit%", "vs ship",
    )
    print(header)
    print("-" * len(header))
    for policy, t in results:
        delta = t["cost"] - shipped["cost"]
        print("%-19s %11s %11s %11s %9.2f %7.1f%% %+9.2f" % (
            policy.name,
            "{:,}".format(t["prompt_tokens"]),
            "{:,}".format(t["cache_read"]),
            "{:,}".format(t["fresh"]),
            t["cost"],
            100 * t["rewritten"] / t["requests"],
            delta,
        ))

    print("\nnotes")
    for policy, _ in results:
        print("  %-19s %s" % (policy.name, policy.note))

    real_input = real_cache = 0
    for session in sessions.values():
        for record in session:
            usage = record.get("usage")
            if usage:
                real_input += usage.get("input", 0)
                real_cache += usage.get("cacheRead", 0)
    raw = results[0][1]
    print("\nrecorded in the logs: %s fresh input, %s cache read, %d requests" % (
        "{:,}".format(real_input), "{:,}".format(real_cache), raw["requests"],
    ))
    print("simulated 'raw':      %s fresh input, %s cache read" % (
        "{:,}".format(raw["fresh"]), "{:,}".format(raw["cache_read"]),
    ))


if __name__ == "__main__":
    main()
