#!/usr/bin/env python3
"""The bar to beat: the deterministic reductions, scored the way a model's would be.

A digest is graded by `score.py` on bite, fact recall and latency. The reductions
that already exist have no latency and are reproducible, so running them through
the same scorer does two jobs:

  - it produces the numbers a local model has to beat, on the real corpus, rather
    than a comparison that only exists in prose;
  - it checks the scorer itself. If the shipped 40+20 rule — which by construction
    keeps the first 40 and last 20 lines of every result, verbatim — does not score
    near-perfect recall, the recall metric is measuring the wrong thing.

`trim` here is `core/trim.mbt::trim_text` transcribed into `policies.py`, so this is
the shipped behaviour and not an approximation of it.

Usage: python3 baseline.py          # writes data/digests-trim.jsonl, data/digests-marker.jsonl
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from policies import marker_reduce, trim_reduce  # noqa: E402

HERE = os.path.dirname(__file__)


def emit(name, reduce):
    source = os.path.join(HERE, "data", "candidates.jsonl")
    target = os.path.join(HERE, "data", "digests-%s.jsonl" % name)
    count = 0
    with open(source) as fh, open(target, "w") as out:
        for line in fh:
            candidate = json.loads(line)
            text = reduce(candidate["text"])
            out.write(json.dumps({
                "id": candidate["id"],
                "tool": candidate["tool"],
                "model": "rule:%s" % name,
                "in_bytes": candidate["bytes"],
                "out_bytes": len(text.encode("utf-8")),
                # No latency to report: a rule is the floor of this column, and a
                # model that is not much slower is a model worth using.
                "latency_ms": 0,
                "ok": True,
                "digest": text,
            }) + "\n")
            count += 1
    print("%-8s %d outcomes -> %s" % (name, count, target))


def main():
    emit("trim", trim_reduce)
    emit("marker", marker_reduce)


if __name__ == "__main__":
    main()
