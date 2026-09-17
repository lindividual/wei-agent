#!/usr/bin/env bash
# Rename every name this project invented for itself from `upstream*` to `wei*`.
#
# Run from the repository root of a *copy*: it rewrites files in place and moves
# directories with `git mv`, so it wants a tree it is allowed to change.
#
#   1. moves (directories and the files whose names carry the old brand)
#   2. textual substitutions, in the order they are listed (see subst.pl)
#
# Deliberately NOT touched here — these point at the upstream project, not at us,
# and are handled by hand or left alone:
#   ~/.upstream/agent/...        upstream's credential store, skills and model catalogue
#   @earendil-works/upstream-*   the oracle the fixture generators import
#   "upstream's rule", "from upstream" comments that record where a number was copied from
set -euo pipefail

cd "$(dirname "$0")"

if [ -n "$(git status --porcelain)" ]; then
  echo "refusing to run on a dirty tree" >&2
  exit 1
fi

# ── 1. moves ───────────────────────────────────────────────────────────────

# The module's CLI package: `moon run upstream` → `moon run wei`.
git mv pi wei

# The Swift package, and the targets inside it.
git mv macos/WeiShell macos/WeiShell
git mv macos/WeiShell/Sources/WeiShell macos/WeiShell/Sources/WeiShell
git mv macos/WeiShell/Sources/WeiModel macos/WeiShell/Sources/WeiModel
git mv macos/WeiShell/Sources/WeiKit macos/WeiShell/Sources/WeiKit
git mv macos/WeiShell/Sources/WeiShellC macos/WeiShell/Sources/WeiShellC
git mv macos/WeiShell/Sources/wei-cli macos/WeiShell/Sources/wei-cli
git mv macos/WeiShell/Tests/WeiModelTests macos/WeiShell/Tests/WeiModelTests
git mv macos/WeiShell/Tests/WeiShellTests macos/WeiShell/Tests/WeiShellTests

# Files whose *name* carries the old brand.
git mv macos/WeiShell/Sources/WeiShell/WeiApp.swift macos/WeiShell/Sources/WeiShell/WeiApp.swift
git mv macos/WeiShell/Sources/WeiKit/ShellClient.swift macos/WeiShell/Sources/WeiKit/ShellClient.swift
git mv macos/WeiShell/Sources/WeiShellC/WeiShellC.c macos/WeiShell/Sources/WeiShellC/WeiShellC.c
git mv macos/WeiShell/Sources/WeiShellC/include/WeiShellC.h macos/WeiShell/Sources/WeiShellC/include/WeiShellC.h

# ── 2. substitutions ───────────────────────────────────────────────────────

# Text files only, and never through a symlink: `README.md` is one, and rewriting
# it in place would replace the link with a copy of its target.
while IFS= read -r -d '' f; do
  [ -L "$f" ] && continue
  [ -T "$f" ] || continue
  perl -i -p subst.pl "$f"
done < <(git ls-files -z)

echo "done: $(git status --porcelain | wc -l | tr -d ' ') paths changed"
