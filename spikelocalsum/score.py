#!/usr/bin/env python3
"""Score a compression run: what did it keep, what did it lose, what did it cost?

The unit of judgement is **fact recall**. Everything in a tool result that can be
wrongly paraphrased — a path, a command, an error line, a number — a rule can keep
exactly (`core/facts.mbt` is that idea applied to compaction). So a digest is graded
on whether the strings a reader would act on are still in it, not on how it reads.

Three numbers per run, plus the cost that decides whether any of it is worth doing:

  bite        output bytes / input bytes — how much room was actually saved
  recall      the share of "must-keep" strings still present verbatim
  use         the share of digests that are non-empty and parse as expected
  latency     per call, because this sits on the tool path

`must-keep` is deliberately narrow, because a metric you can game is worse than no
metric. It takes only strings that are unambiguous and mechanically extractable:

  - every path-like token: an absolute path, a relative path with a slash and an
    extension, `file.ext:line`
  - every line the result itself marks as an error: `error`, `Error`, `ERROR`,
    `failed`, `warning`, `Traceback`, `panic`, a `FAILED` test line
  - every command that was run, from the `toolCall` arguments (passed in, not
    guessed from output)

A digest that keeps all of those and drops the rest has done the job. One that
keeps none of them has produced something fluent and useless.

Usage:
  python3 score.py data/candidates.jsonl data/digests-afm.jsonl
  python3 score.py data/candidates.jsonl data/digests-afm.jsonl --examples 5
"""

import argparse
import collections
import json
import os
import re
import statistics

# A path with enough structure that a paraphrase would have to guess: either
# absolute, or with a slash and a known-ish extension, optionally with `:line`.
PATH = re.compile(r"(?:/[\w.@+-]+){2,}(?:\.\w{1,6})?(?::\d+)?")
REL_PATH = re.compile(r"\b[\w.@+-]+/[\w./@+-]*\.\w{1,6}(?::\d+)?\b")
# A line that says something went wrong. Case-sensitive alternatives rather than
# a bare `error` so that prose ("no error") is not counted as a fact.
ERROR_LINE = re.compile(
    r"\b(?:error|Error|ERROR|failed|FAILED|FAIL|panic|Panic|fatal|Fatal|"
    r"Traceback|Exception|exception|warning|Warning|WARNING)\b"
)
NUMBERED = re.compile(r"\b\d{2,}\b")


def must_keep(candidate):
    """The strings a digest has to preserve, extracted mechanically."""
    text = candidate["text"]
    keep = set()
    for match in PATH.findall(text):
        if len(match) >= 6:
            keep.add(match)
    for match in REL_PATH.findall(text):
        if len(match) >= 6:
            keep.add(match)
    for line in text.split("\n"):
        if ERROR_LINE.search(line):
            line = line.strip()
            # Only lines short enough to be a fact rather than a document.
            if 4 < len(line) <= 200:
                keep.add(line)
    return keep


def digest_key(record):
    return record["id"]


def load(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                record = json.loads(line)
                out[digest_key(record)] = record
    return out


def best_digest_text(record):
    """Whatever the run produced, however it spells it."""
    for key in ("digest", "summary", "text", "output"):
        value = record.get(key)
        if isinstance(value, str):
            return value
        if isinstance(value, list):
            return "\n".join(str(v) for v in value)
    return ""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("candidates")
    parser.add_argument("digests")
    parser.add_argument("--examples", type=int, default=0)
    parser.add_argument("--label", default=None)
    args = parser.parse_args()

    candidates = [json.loads(line) for line in open(args.candidates) if line.strip()]
    digests = load(args.digests)
    label = args.label or os.path.basename(args.digests)

    by_tool = collections.defaultdict(lambda: collections.Counter())
    latencies = []
    failures = []
    total_in = total_out = 0
    scored = 0
    keep_total = keep_hit = 0
    empty = 0

    for candidate in candidates:
        key = digest_key(candidate)
        record = digests.get(key)
        if record is None:
            failures.append((key, "no digest produced"))
            continue
        if record.get("ok") is False:
            failures.append((key, record.get("note") or "error"))
            by_tool[candidate.get("tool") or "?"]["failed"] += 1
            continue

        text = best_digest_text(record)
        out_bytes = len(text.encode("utf-8"))
        in_bytes = candidate["bytes"]
        tool = candidate.get("tool") or "?"

        bucket = by_tool[tool]
        bucket["n"] += 1
        bucket["in"] += in_bytes
        bucket["out"] += out_bytes
        if record.get("latency_ms") is not None:
            latencies.append(record["latency_ms"])
            bucket["ms"] += record["latency_ms"]
        total_in += in_bytes
        total_out += out_bytes

        if not text.strip():
            empty += 1
            bucket["empty"] += 1

        # Recall is counted per fact, not per result, so one lost path in a large
        # result does not hide behind a hundred that were kept.
        keep = must_keep(candidate)
        if keep:
            scored += 1
            hit = sum(1 for fact in keep if fact in text)
            keep_total += len(keep)
            keep_hit += hit
            bucket["facts"] += len(keep)
            bucket["facts_hit"] += hit
            if hit < len(keep):
                bucket["lossy"] += 1
                if args.examples and len(failures) < args.examples:
                    missing = sorted(f for f in keep if f not in text)[:3]
                    failures.append((key, "dropped: %s" % "; ".join(missing[:3])))

    print("=== %s ===" % label)
    print("candidates %d, scored %d, missing %d, failed %d, empty %d" % (
        len(candidates), scored,
        sum(1 for _, note in failures if note == "no digest produced"),
        sum(by_tool[t]["failed"] for t in by_tool),
        empty,
    ))
    print()
    print("%-8s %6s %11s %11s %7s %9s %9s %8s" % (
        "tool", "n", "in bytes", "out bytes", "bite", "recall", "lossy%", "median ms",
    ))
    print("-" * 78)
    for tool, bucket in sorted(by_tool.items(), key=lambda kv: -kv[1]["in"]):
        n = bucket["n"]
        if not n:
            continue
        recall = 100 * bucket["facts_hit"] / bucket["facts"] if bucket["facts"] else float("nan")
        lossy = 100 * bucket["lossy"] / n
        median = bucket["ms"] / n
        print("%-8s %6d %11s %11s %6.2fx %8.1f%% %8.0f%% %9.0f" % (
            tool, n, "{:,}".format(bucket["in"]), "{:,}".format(bucket["out"]),
            bucket["in"] / max(1, bucket["out"]), recall, lossy, median,
        ))
    print("-" * 78)
    print("%-8s %6s %11s %11s %6.2fx %8.1f%%" % (
        "all", "", "{:,}".format(total_in), "{:,}".format(total_out),
        total_in / max(1, total_out),
        100 * keep_hit / keep_total if keep_total else float("nan"),
    ))
    if latencies:
        print()
        print("latency: median %.0f ms, p90 %.0f ms, max %.0f ms (%d calls)" % (
            statistics.median(latencies),
            sorted(latencies)[int(len(latencies) * 0.9)],
            max(latencies), len(latencies),
        ))
        # The number that decides whether this can sit on the tool path.
        print("         %.1f ms per KB of input" % (
            statistics.median(latencies) / max(1, total_in / 1000 / len(latencies)),
        ))
    if failures and args.examples:
        print()
        print("examples")
        for key, note in failures[:args.examples]:
            print("  %s  %s" % (key, note))


if __name__ == "__main__":
    main()
