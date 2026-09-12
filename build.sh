#!/usr/bin/env bash
# Build the rabbita frontend and deploy the extension + assets to the global
# extension directory.
#
# Why global: a project-local extension is not loaded when a session switch
# enters an untrusted cwd, so workspace switching would silently lose the
# bridge. Global extensions are always loaded.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
DEST="$HOME/.pi/agent/extensions/pi-web-shell"

moon build --target js "$([ "$MODE" = release ] && echo --release)"

mkdir -p dist "$DEST/dist"
cp "_build/js/$MODE/build/web/web.js" dist/web.js
cp web/index.html dist/index.html

cp extension/index.ts "$DEST/index.ts"
cp extension/package.json "$DEST/package.json"
cp dist/web.js dist/index.html "$DEST/dist/"

echo "前端     → dist/ ($(du -h dist/web.js | cut -f1), $MODE)"
echo "扩展部署 → $DEST"
