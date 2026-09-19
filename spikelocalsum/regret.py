#!/usr/bin/env python3
"""What the window actually costs -- the number `scenario.py` says no log can supply.

`scenario.py` parameterises the regret probability (`--regret-probability`, default
0.05) with the honest note that it "cannot be measured from logs alone -- a session
that would have failed is not in the corpus." That is true of the *failure*. It is
not true of the *need*: the corpus contains every place where the model went back for
bytes it had already been shown. This file measures three things about that, from the
logs only, with no model in the loop.

  A  the extra exposure    what `recent_window: 20 -> 2` additionally drops, in
                           prompt-bytes x requests, so the size of #0's bet is a number.
  B  the observed regret   for results the *shipped* policy already trims, do the dropped
                           middle lines ever turn up again in a later message? This is
                           regret as it actually happened, not as a parameter.
  C  the observable need   unchanged re-reads: a read of a path that was read earlier and
                           not modified since. Splitting those by whether the earlier bytes
                           were still inside the window at that moment is the cost of
                           shrinking the window, and it is measurable.

Everything is derived from `data/messages.jsonl` (`corpus.py`), whose conversation order
is the parent chain the provider actually saw -- not file order. The trim rule is
`core/trim.mbt`'s, copied rather than imported:

    cutoff(n) = max(0, n - recent_window) // advance_step * advance_step

A message at index `i` is verbatim in a request of length `k` iff `i >= cutoff(k)`;
under the shipped policy `recent_window=20, advance_step=8`, under #0 `2, 1`.

What this still cannot answer: a line that was dropped, needed, and never re-obtained
leaves no trace, so every figure here is a *lower* bound on the need. The direction of
the bias is known and is stated with each number.
"""

import argparse
import collections
import json
import os
import re
import statistics

# core/trim.mbt::TrimPolicy::default()
SHIPPED_WINDOW = 20
SHIPPED_STEP = 8
# ...and what #0 would change them to. See docs/system-one-jev.md section 11, row 0.
TARGET_WINDOW = 2
TARGET_STEP = 1
TOOL_RESULT_LIMIT = 4 * 1024
HEAD_LINES = 40
TAIL_LINES = 20


def cutoff(length, window, step):
    released = max(0, length - window)
    if step <= 1:
        return released
    return released // step * step


def load(path):
    sessions = collections.OrderedDict()
    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            sessions.setdefault(record["session"], []).append(record)
    return sessions


# ---------------------------------------------------------------- text plumbing

WS = re.compile(r"\s+")
# A line worth remembering: long enough not to be boilerplate, and not a shell
# fragment. Shorter lines ("---", "}", "PASS") reappear by chance and would make
# every rate meaningless.
MIN_LINE = 16
# The token form, for a hit the strict line test would miss: the model quoting a path
# or a symbol from the dropped region inside its own prose rather than reproducing the
# line. Ten characters is long enough that a match is not a coincidence.
MIN_TOKEN = 10
TOKEN = re.compile(r"[A-Za-z0-9_./:-]{%d,}" % MIN_TOKEN)


def norm(text):
    return WS.sub(" ", text or "").strip()


def lines_of(text):
    for raw in (text or "").split("\n"):
        n = norm(raw)
        if len(n) >= MIN_LINE:
            yield n


def tokens_of(text):
    return set(TOKEN.findall(text or ""))


def split_kept_dropped(text):
    """The head and tail trimming keeps, and the middle it drops.

    `core/trim.mbt::trim_text`: fewer than `head + tail + 1` lines means the size is in
    line *length*, not count, so nothing is dropped at all.
    """
    raw = (text or "").split("\n")
    if raw and raw[-1] == "":
        raw = raw[:-1]
    total = len(raw)
    kept = HEAD_LINES + TAIL_LINES
    if total <= kept + 1:
        return "", ""
    head = "\n".join(raw[:HEAD_LINES])
    tail = "\n".join(raw[total - TAIL_LINES:])
    middle = "\n".join(raw[HEAD_LINES:total - TAIL_LINES])
    return head + "\n" + tail, middle


def first_trimmed_at(records, index, window, step):
    """The first request length at which `index` falls outside the window.

    Requests are counted the way `scenario.py` counts them: one before each assistant
    message, carrying everything before it.
    """
    for k in range(index + 1, len(records) + 1):
        if index < cutoff(k, window, step):
            return k
    return None


def later_text(records, pos, cache):
    """Every line and long token in the messages after `pos`, memoised.

    Strict: a whole normalized line, or a long token, seen verbatim later. Both are
    lower bounds -- a paraphrase does not count, and neither does a line the model
    remembered without writing down.
    """
    if pos in cache:
        return cache[pos]
    lines = set()
    tokens = set()
    for record in records[pos:]:
        lines.update(lines_of(record["text"]))
        tokens.update(tokens_of(record["text"]))
    cache[pos] = (lines, tokens)
    return cache[pos]


# ------------------------------------------------------------------- the measures


def exposure(sessions):
    """A: what #0 additionally drops, in prompt-bytes x requests.

    A result at index `i` is dropped by a request of length `k` iff `i < cutoff(k)`. #0
    drops it at a smaller `k` than the shipped policy does, so the *extra* exposure is
    the band `cutoff_shipped(k) <= i < cutoff_target(k)` -- requests that used to carry
    the bytes verbatim and now carry the middle dropped.
    """
    total_prompt_bytes = 0
    extra_bytes = 0
    shipped_bytes_dropped = 0
    extra_results = set()
    at_target = set()
    for name, records in sessions.items():
        n = len(records)
        for k in range(1, n + 1):
            shipped = cutoff(k, SHIPPED_WINDOW, SHIPPED_STEP)
            target = cutoff(k, TARGET_WINDOW, TARGET_STEP)
            for i in range(k):
                record = records[i]
                size = record["text_bytes"] + (
                    record["thinking_bytes"] if record["role"] == "assistant" else 0)
                total_prompt_bytes += size
                if record["role"] != "toolResult":
                    continue
                if record["text_bytes"] <= TOOL_RESULT_LIMIT:
                    continue
                _, dropped = split_kept_dropped(record["text"])
                if not dropped:
                    continue
                db = len(dropped.encode("utf-8"))
                if i < shipped:
                    # Both policies still carry it verbatim.
                    continue
                shipped_bytes_dropped += db
                if i >= target:
                    continue
                extra_bytes += db
                extra_results.add((name, i))
            at_target.add((name, cutoff(k, TARGET_WINDOW, TARGET_STEP) - 1))
    return {
        "total_prompt_bytes": total_prompt_bytes,
        "shipped_bytes_dropped": shipped_bytes_dropped,
        "extra_bytes": extra_bytes,
        "extra_results": len(extra_results),
    }


def observed_regret(sessions):
    """B: did dropped middle lines come back? Paired against the lines trimming keeps.

    Two populations, and each carries its own control measured at the *same* position:
    the same result's head and tail. That is the point of the pairing -- a kept line
    reappears whenever the file is re-read or the output quoted, which is exactly the
    confound the dropped lines are exposed to. If dropped and kept lines come back at
    the same rate, the middle is not special; if the middle comes back far less, that
    is the middle being dead weight.

    `already`  the first request at which *today's* policy drops the middle
    `band`     the first request at which #0 drops it, when that is earlier
    """
    out = collections.defaultdict(lambda: {
        "results": 0, "dropped_lines": 0, "kept_lines": 0,
        "dropped_line_hits": 0, "kept_line_hits": 0,
        "res_dropped_line": 0, "res_kept_line": 0,
        "res_dropped_token": 0, "res_kept_token": 0,
    })
    for name, records in sessions.items():
        # population -> position -> list of (index, dropped_lines, kept_lines)
        cands = collections.defaultdict(lambda: collections.defaultdict(list))
        for i, record in enumerate(records):
            if record["role"] != "toolResult":
                continue
            if record["text_bytes"] <= TOOL_RESULT_LIMIT:
                continue
            kept, dropped = split_kept_dropped(record["text"])
            if not dropped:
                continue
            t_target = first_trimmed_at(records, i, TARGET_WINDOW, TARGET_STEP)
            t_shipped = first_trimmed_at(records, i, SHIPPED_WINDOW, SHIPPED_STEP)
            if t_shipped is None:
                # Never leaves today's window in this session, so today never drops it.
                if t_target is not None:
                    cands["band"][t_target].append(
                        (i, list(lines_of(dropped)), list(lines_of(kept))))
                continue
            cands["already"][t_shipped].append(
                (i, list(lines_of(dropped)), list(lines_of(kept))))
            if t_target is not None and t_target < t_shipped:
                cands["band"][t_target].append(
                    (i, list(lines_of(dropped)), list(lines_of(kept))))
        cache = {}
        for kind, by_pos in cands.items():
            bucket = out[kind]
            for pos, entries in by_pos.items():
                seen_lines, seen_tokens = later_text(records, pos, cache)
                for _i, dropped_lines, kept_lines in entries:
                    bucket["results"] += 1
                    bucket["dropped_lines"] += len(dropped_lines)
                    bucket["kept_lines"] += len(kept_lines)
                    bucket["dropped_line_hits"] += sum(
                        1 for l in dropped_lines if l in seen_lines)
                    bucket["kept_line_hits"] += sum(
                        1 for l in kept_lines if l in seen_lines)
                    bucket["res_dropped_line"] += any(
                        l in seen_lines for l in dropped_lines)
                    bucket["res_kept_line"] += any(
                        l in seen_lines for l in kept_lines)
                    bucket["res_dropped_token"] += any(
                        tokens_of(l) & seen_tokens for l in dropped_lines)
                    bucket["res_kept_token"] += any(
                        tokens_of(l) & seen_tokens for l in kept_lines)
    return out


def observable_need(sessions):
    """C: unchanged re-reads, whether the bytes were still in the window, and the cost.

    A read of a path that was read before, with no `edit`/`write` to that path in
    between. Under the shipped window the earlier bytes may still have been verbatim
    when the model went back for them; the split says whether they were. The ones that
    were *outside* today's window are needs older than 20 messages -- the hazard rate
    that no parameter has to be assumed for. The ones inside it but outside #0's
    2-message window are the reads #0 additionally forces, and their charge is read
    from the log: the whole call that carried the re-read, which over-charges it.
    """
    stat = collections.Counter()
    gaps = {"out": [], "free": [], "forced": []}
    for name, records in sessions.items():
        last_read = {}
        modified = collections.defaultdict(int)
        for j, record in enumerate(records):
            for call in record.get("calls") or []:
                args = call.get("arguments") or {}
                if not isinstance(args, dict):
                    continue
                path = args.get("path")
                tool = call["name"]
                if tool in ("edit", "write") and isinstance(path, str):
                    modified[path] += 1
                    continue
                if tool != "read" or not isinstance(path, str):
                    continue
                range_key = (args.get("offset"), args.get("limit"))
                stat["reads"] += 1
                prev = last_read.get(path)
                last_read[path] = (j, modified[path], range_key)
                if prev is None:
                    stat["first_read"] += 1
                    continue
                i, mods_at_read, prev_key = prev
                if modified[path] != mods_at_read:
                    stat["reread_after_edit"] += 1
                    continue
                stat["reread_unchanged"] += 1
                same_range = prev_key == range_key
                stat["identical_range" if same_range else "other_range"] += 1
                gap = j - i
                cost = ((record.get("usage") or {}).get("cost") or {}).get("total") or 0.0
                stat["cost_reread"] += int(round(cost * 1e6))
                shipped = cutoff(j, SHIPPED_WINDOW, SHIPPED_STEP)
                target = cutoff(j, TARGET_WINDOW, TARGET_STEP)
                if i < shipped:
                    stat["was_outside_w20"] += 1
                    gaps["out"].append(gap)
                    continue
                stat["was_inside_w20"] += 1
                if i >= target:
                    # Still verbatim under #0's two-message window: this re-read is free.
                    stat["free_under_0"] += 1
                    gaps["free"].append(gap)
                else:
                    stat["forced_by_0"] += 1
                    stat["cost_forced"] += int(round(cost * 1e6))
                    gaps["forced"].append(gap)
    return stat, gaps["out"], gaps["free"], gaps["forced"]


def repeat_bash(sessions):
    """C': the same bash command, run again in one session. Same measurement, wider net.

    `read` is 2,065 calls against 13,056 for `bash`, so path-based re-reads see only a
    slice of the model going back for something. An identical command string is the
    same event with the file work hidden inside the shell.
    """
    stat = collections.Counter()
    gaps = []
    for name, records in sessions.items():
        last = {}
        for j, record in enumerate(records):
            for call in record.get("calls") or []:
                if call["name"] not in ("bash", "exec"):
                    continue
                args = call.get("arguments") or {}
                if not isinstance(args, dict):
                    continue
                command = args.get("command") or args.get("bash")
                if not isinstance(command, str):
                    continue
                key = norm(command)
                stat["commands"] += 1
                if key in last:
                    stat["repeat"] += 1
                    gap = j - last[key][0]
                    gaps.append(gap)
                    last[key] = (j, True)
                else:
                    last[key] = (j, False)
    return stat, gaps


def summarize_gaps(label, gaps):
    if not gaps:
        print("    %-34s none" % label)
        return
    gaps = sorted(gaps)
    med = statistics.median(gaps)
    p90 = gaps[int(0.9 * (len(gaps) - 1))]
    print("    %-34s n=%d  median %s  p90 %s  max %s  (<=2: %.0f%%)" % (
        label, len(gaps), med, p90, gaps[-1],
        100 * sum(1 for g in gaps if g <= 2) / len(gaps)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default=os.path.join(
        os.path.dirname(__file__), "data", "messages.jsonl"))
    args = parser.parse_args()

    sessions = load(args.data)
    print("sessions %d, messages %d" % (
        len(sessions), sum(len(v) for v in sessions.values())))
    print()

    # ── A ────────────────────────────────────────────────────────────────────
    print("A. the extra exposure of recent_window 20 -> 2")
    ex = exposure(sessions)
    total = ex["total_prompt_bytes"]
    print("   prompt bytes x requests, whole corpus        %s" % format(total, ","))
    print("   middle bytes dropped by the shipped policy   %s  (%.1f%%)" % (
        format(ex["shipped_bytes_dropped"], ","),
        100 * ex["shipped_bytes_dropped"] / total if total else 0))
    print("   of which #0 drops *earlier*                  %s  (%.1f%%)" % (
        format(ex["extra_bytes"], ","),
        100 * ex["extra_bytes"] / total if total else 0))
    print("   distinct results in the #0 band              %d" % ex["extra_results"])
    print()

    # ── B ────────────────────────────────────────────────────────────────────
    print("B. did the dropped lines come back?  paired against the head/tail it keeps")
    regret = observed_regret(sessions)
    print("   %-9s %6s %9s %9s %9s %9s" % (
        "", "res", "lines", "line-hit%", "res>line%", "res>token%"))
    print("   %-9s %6s %9s %9s %9s %9s" % (
        "", "", "", "drop/keep", "drop/keep", "drop/keep"))
    print("   " + "-" * 56)
    for kind in ("already", "band"):
        b = regret.get(kind)
        if not b or not b["results"]:
            continue
        def pct(hit, n):
            return 100 * hit / n if n else 0
        print("   %-9s %6d %4d/%-4d %4.1f/%4.1f %4.1f/%4.1f %4.1f/%4.1f" % (
            kind, b["results"], b["dropped_lines"], b["kept_lines"],
            pct(b["dropped_line_hits"], b["dropped_lines"]),
            pct(b["kept_line_hits"], b["kept_lines"]),
            pct(b["res_dropped_line"], b["results"]),
            pct(b["res_kept_line"], b["results"]),
            pct(b["res_dropped_token"], b["results"]),
            pct(b["res_kept_token"], b["results"]),
        ))
    print("   `already` = dropped by today's policy; `band` = dropped by #0 only.")
    print()

    # ── C ────────────────────────────────────────────────────────────────────
    print("C. unchanged re-reads: bytes gone back for that were read before and not edited")
    stat, gaps_out, gaps_free, gaps_forced = observable_need(sessions)
    reads = stat["reads"]
    print("   read calls                                    %d" % reads)
    print("   first read of that path                       %d" % stat["first_read"])
    print("   re-read after an edit (content had changed)   %d" % stat["reread_after_edit"])
    print("   re-read of an unchanged path                  %d  (%.1f%% of reads)"
          % (stat["reread_unchanged"],
             100 * stat["reread_unchanged"] / reads if reads else 0))
    print("     ... the same range asked for again          %d    (the model could already see it)"
          % stat["identical_range"])
    print("     ... a different range of the same file      %d    (plausibly wanting more of it)"
          % stat["other_range"])
    print("     earlier bytes already outside the w20 window %d  <- a need older than 20 messages"
          % stat["was_outside_w20"])
    print("     still inside w20: %d" % stat["was_inside_w20"])
    print("       still inside 2 messages (free under #0)     %d" % stat["free_under_0"])
    print("       outside 2 messages  <- what #0 forces       %d" % stat["forced_by_0"])
    print()
    print("   gap in messages between the two reads:")
    summarize_gaps("outside w20 (needed again anyway)", gaps_out)
    summarize_gaps("inside w20, inside w2 (free)", gaps_free)
    summarize_gaps("inside w20, outside w2 (forced)", gaps_forced)
    print()
    print("   what an unchanged re-read costs: the call that carried it, from the log")
    print("     whole call, all %d unchanged re-reads         $%.3f" % (
        stat["reread_unchanged"], stat["cost_reread"] / 1e6))
    print("     the #0-forced subset (%d)                   $%.3f" % (
        stat["forced_by_0"], stat["cost_forced"] / 1e6))
    print("     (an upper bound: the whole call is charged to the re-read, even when the")
    print("      model did other things in it)")
    print()

    # ── C' ───────────────────────────────────────────────────────────────────
    print("C'. same measurement over bash, where the file work is hidden in the shell")
    bstat, bgaps = repeat_bash(sessions)
    print("   bash/exec calls                               %d" % bstat["commands"])
    print("   identical command run again in a session      %d  (%.1f%%)"
          % (bstat["repeat"], 100 * bstat["repeat"] / bstat["commands"]
             if bstat["commands"] else 0))
    summarize_gaps("repeat gap (messages)", bgaps)
    print()
    print("Read a gap as the useful life of a result: a repeat at gap 2 is free under #0,")
    print("a repeat at gap 12 is a call the smaller window forces. Every number here is a")
    print("lower bound -- a need that was never re-obtained leaves no trace in a log.")


if __name__ == "__main__":
    main()
