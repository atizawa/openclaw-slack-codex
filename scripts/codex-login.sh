#!/usr/bin/env bash
set -euo pipefail

echo "=== Codex CLI Device Code Login ==="
echo "ブラウザでOpenAIにログインし、表示されるコードを入力してください。"
echo ""

docker compose exec -it openclaw codex login --device-auth
