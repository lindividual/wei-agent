#!/usr/bin/env bash
# Build the rabbita frontend and assemble dist/ for the pi extension to serve.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-debug}"
moon build --target js "$([ "$MODE" = release ] && echo --release)"

OUT="_build/js/$MODE/build/web/web.js"
mkdir -p dist
cp "$OUT" dist/web.js
cp web/index.html dist/index.html
echo "dist/ 已更新 ($MODE): $(du -h dist/web.js | cut -f1) web.js"
