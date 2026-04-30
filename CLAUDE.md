# OpenClaw + Codex CLI (Docker Compose)

Slackチャンネルごとに異なるワークスペースを持ち、Codex CLI (gpt-5.5) で回答を生成する構成。

## アーキテクチャ

```
Slack #channel ── Socket Mode ──> [OpenClaw] ── bindings ──> agent ──> workspaces/<name>/
                                                                         ├── AGENTS.md (コンテキスト)
                                                                         └── docs/ (ドキュメント)
```

コンテナ起動時に `workspaces/channels.conf` + ディレクトリ構成から `openclaw.json` を自動生成。`channels.conf` のチャンネルIDはSlack bindingsと `channels.slack.channels` allowlist の両方に反映され、登録済みチャンネルでも workspace に入るのはメンション付き投稿だけです。

`workspaces/` は read-only source としてマウントし、実際にOpenClawへ渡すワークスペースは `state/runtime-workspaces/` に起動時生成する。プロジェクトファイルは `workspaces/` へのsymlink、OpenClawが更新する実行時状態は `state/workspaces/<name>/` へのsymlinkにする。

workspace 内のファイルを更新したら、その workspace の session を切り直す。`scripts/workspace-session-invalidator.sh` は手動失効、`scripts/workspace-session-watch.sh` はポーリング監視用。watcher のデフォルト間隔は5秒で、`.git`、`.codex`、`.DS_Store` は監視対象から除外する。常駐の自動監視が必要なら、`launchd` や `cron` から watch スクリプトを起動する。

## セットアップ

```bash
cp .env.example .env       # Slackトークンを記入
cp workspaces/channels.conf.sample workspaces/channels.conf  # チャンネルマッピングを記入
TOKEN=$(openssl rand -hex 32)
sed -i.bak "s/^OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$TOKEN/" .env
rm .env.bak
docker compose up -d --build
./scripts/codex-login.sh   # 初回のみ: Codex OAuthログイン (device code)
```

## 主要ファイル

- `Dockerfile` — OpenClawイメージ (バージョンタグ指定) + Codex CLI + entrypoint
- `docker-compose.yml` — サービス定義・ボリューム・ポート
- `config/openclaw.base.json` — 共通設定テンプレート (agents/bindings/Slackチャンネルallowlist以外)。Codex backend args は bwrap sandbox を使わないよう `danger-full-access` に上書きする。
- `state/` — OpenClawの実行時状態 (git管理外)
- `workspaces/channels.conf.sample` — チャンネルマッピングのテンプレート (git管理)
- `workspaces/channels.conf` — 実際のマッピング (git管理外)
- `scripts/entrypoint.sh` — 起動時に runtime workspace と openclaw.json を動的生成
- `.env` — Slackトークン + gateway token (git管理外)
- `scripts/codex-login.sh` — Docker内でCodex device code認証を実行

## ワークスペース追加

1. `workspaces/` にプロジェクトを配置 (git clone 等)
2. `workspaces/channels.conf` に `プロジェクト名=チャンネルID` を追記
3. `docker compose restart openclaw`

環境固有のSlackチャンネルIDは `config/openclaw.base.json` には書かず、git管理外の `workspaces/channels.conf` に置く。

## モデル変更

`config/openclaw.base.json` の `agents.defaults.model.primary` を変更:

```
codex-cli/gpt-5.5, codex-cli/gpt-5.4, codex-cli/gpt-5.4-mini, codex-cli/gpt-5.3-codex
```

## サンドボックス

Codex CLIはDocker内で `sandbox_mode = "danger-full-access"` として動作する。OpenClaw の Codex backend はデフォルトで `workspace-write` sandbox を明示するため、`config/openclaw.base.json` の `args` / `resumeArgs` でも `danger-full-access` を明示する。これはCodex CLIのbwrapベースsandboxがDocker環境によって `setting up uid map: Permission denied` で失敗することを避けるため。ホスト側の `workspaces/` は `docker-compose.yml` で read-only マウントされるため、Slack経由の会話でプロジェクトファイルは読み取れるが変更されない。Docker socket、ホスト全体、ホームディレクトリ全体はマウントしない。`state/` はOpenClawの実行時状態として書き込み可能にするため、ここには秘密情報を置かない。

## ポート

- `18789` — OpenClaw管理UI (http://localhost:18789)
