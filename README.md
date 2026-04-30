# OpenClaw + Codex CLI

Slackチャンネルごとに異なるワークスペース（AGENTS.md + ドキュメント）を持ち、OpenAI Codex CLI (gpt-5.5) で回答を生成するDocker Compose構成です。

OpenClaw/Codex CLI はコンテナ内で実行し、ホスト側では `config/`、`workspaces/`、`state/` のみをマウントします。ホスト全体へのアクセスは与えず、Codex が参照できる対象を `workspaces/` 配下のプロジェクトに限定します。`workspaces/` は Docker の read-only マウントにしているため、Slack 経由の会話でプロジェクトファイルは読み取れますが変更されません。OpenClaw が更新する実行時状態だけは `state/` に保存します。`workspaces/` には必要なプロジェクトだけを配置し、機密ファイルや無関係なリポジトリを置かないようにしてください。

Codex CLI の `read-only` sandbox は内部で `bwrap` を使いますが、Docker環境によって `bwrap: setting up uid map: Permission denied` などで起動できないため、この構成では Codex CLI の bwrap sandbox は使いません。代わりに Docker のマウント境界で参照範囲を限定し、`workspaces/` を read-only にします。

セキュリティ上、`docker-compose.yml` では `privileged: true`、`SYS_ADMIN`、`seccomp=unconfined`、`apparmor=unconfined`、Docker socket mount を使いません。ホストのホームディレクトリ全体やホストの `/` もマウントしないでください。Slack 経由で参照されてもよいプロジェクトだけを `workspaces/` に置き、秘密情報は `.env` や不要なリポジトリファイルに置かない運用にしてください。

## アーキテクチャ

```
Slack #channel-a ──┐
Slack #channel-b ──┤── Socket Mode ──> [OpenClaw + Codex CLI コンテナ]
Slack DM ──────────┘                        │
                                      bindings でルーティング
                                      ┌──────┼──────┐
                                      ▼      ▼      ▼
                                   agent-a agent-b  default
                                      │      │      │
                                      ▼      ▼      ▼
                              state/runtime-workspaces/
                                      │
                                      ├── project files -> workspaces/ (read-only)
                                      └── runtime state -> state/ (writable)
```

- コンテナ起動時に `workspaces/channels.conf` からルーティングとSlackチャンネルallowlistを自動生成
- 各エージェントはワークスペース内のAGENTS.mdやドキュメントを参照可能
- OpenClaw が更新する実行時状態は `state/workspaces/<name>/` に保存
- DMやマッチしないチャンネルはdefaultエージェントにフォールバック
- `channels.conf` で紐づけたSlackチャンネルは、メンションを付けた投稿だけを対応する workspace で処理する
- watcher を常駐させると、workspace 内のファイル変更でその workspace の session を切り直す

## 必要なもの

- Docker Desktop または Docker Engine + Docker Compose v2
- Slack App（Socket Mode有効）のトークン
  - App-Level Token (`xapp-...`) — `connections:write` スコープ
  - Bot Token (`xoxb-...`)
- OpenAIアカウント（Codex CLI OAuth認証用）

### Slack Appの作成

1. [Slack API](https://api.slack.com/apps) で新しいAppを作成
2. **Socket Mode** を有効化し、App-Level Token (`xapp-...`) を生成（`connections:write` スコープ）
3. **OAuth & Permissions** でBot Token (`xoxb-...`) を取得し、以下のBot Token Scopesを追加:
   - `app_mentions:read`, `chat:write`, `channels:history`, `channels:read`
   - `groups:history`, `groups:read`, `im:history`, `im:read`, `im:write`
   - `mpim:history`, `mpim:read`, `mpim:write`
   - `files:read`, `files:write`, `reactions:read`, `reactions:write`, `users:read`
4. **Event Subscriptions** を有効化し、以下のBot Eventsを購読:
   - `app_mention`, `message.channels`, `message.groups`, `message.im`, `message.mpim`
   - `member_joined_channel`, `member_left_channel`
   - `reaction_added`, `reaction_removed`
5. **App Home** で **Messages Tab** を有効化（DMでの対話に必要）
6. ワークスペースにインストール

詳細は [OpenClaw Slack ドキュメント](https://docs.openclaw.ai/channels/slack) を参照してください。

## セットアップ

### 1. 環境変数の設定

```bash
cp .env.example .env
```

`.env` を編集してSlackトークンを記入します。

Gateway token（管理UI用）を生成して書き込みます:

```bash
TOKEN=$(openssl rand -hex 32)
sed -i.bak "s/^OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=$TOKEN/" .env
rm .env.bak
```

### 2. コンテナのビルドと起動

```bash
docker compose up -d --build
```

### 3. Codex CLIにログイン（初回のみ）

```bash
./scripts/codex-login.sh
```

表示されるURLをブラウザで開き、OpenAIにログイン後、device codeを入力してください。認証情報は `codex-auth` Dockerボリュームに永続化されるため、コンテナ再起動後も維持されます。

### 4. ワークスペースの追加

プロジェクトを `workspaces/` に配置し、`channels.conf` でSlackチャンネルと紐付けます:

```bash
# プロジェクトを配置
cd workspaces
git clone https://github.com/your-org/my-project.git

# チャンネルマッピングを追加
echo "my-project=C0123456789" >> channels.conf
```

プロジェクト側に `AGENTS.md` を置くと、そのワークスペースのエージェント指示として Codex CLI が自動的に読み込みます。`AGENTS.md` がなくてもワークスペース内のファイルは参照可能です。

チャンネルIDの確認方法: Slackでチャンネル名を右クリック → チャンネル詳細 → 最下部に表示されるID

設定後にコンテナを再起動します:

```bash
docker compose restart openclaw
```

### 5. 動作確認

- **Slack**: 各チャンネルでメッセージを送信し、対応するワークスペースのコンテキストで回答されることを確認
- **DM**: defaultエージェントで回答されることを確認
- **管理UI**: http://localhost:18789 にアクセス（`.env` の `OPENCLAW_GATEWAY_TOKEN` で認証）

## ファイル構成

```
.
├── Dockerfile              # OpenClawイメージ (バージョンタグ指定) + Codex CLI + entrypoint
├── docker-compose.yml      # サービス定義
├── .env.example            # 環境変数テンプレート
├── .gitignore
├── CLAUDE.md               # AI エージェント向け指示書
├── AGENTS.md -> CLAUDE.md  # 同上（シンボリックリンク）
├── config/
│   └── openclaw.base.json  # 共通設定 (agents/bindings/Slackチャンネルallowlist以外)
├── state/                  # OpenClawの実行時状態 (git管理外)
│   ├── runtime-workspaces/  # 起動時に生成されるsymlink view
│   └── workspaces/         # OpenClawの永続状態
├── scripts/
│   ├── entrypoint.sh       # 起動時に runtime workspace と openclaw.json を動的生成
│   └── codex-login.sh      # Codex OAuth認証ヘルパー
└── workspaces/
    ├── channels.conf       # ワークスペース名=チャンネルID
    ├── my-project/         # git clone したプロジェクト
    └── another-project/    # 別のプロジェクト
```

## 仕組み

コンテナ起動時に `scripts/entrypoint.sh` が以下を行います:

1. read-only の `workspaces/` を元に `state/runtime-workspaces/` を生成
2. プロジェクトファイルは read-only source への symlink にする
3. OpenClaw が更新する実行時状態は `state/workspaces/<name>/` へ逃がす
4. `config/openclaw.base.json`（共通設定）を読み込み
5. `workspaces/channels.conf` をスキャンしてエージェント、bindings、Slackチャンネルallowlistを生成
6. `workspaces/` 内のディレクトリも検出（channels.confに未登録でもエージェントとして登録）
7. 完成した `openclaw.json` を書き出し
8. Codex CLI の `~/.codex/config.toml` に `sandbox_mode = "danger-full-access"` を設定し、OpenClaw の Codex backend args でも `danger-full-access` を明示する（bwrap sandbox を使わない）
9. OpenClawを起動

ワークスペースへの書き込み防止は Codex CLI の sandbox ではなく、`./workspaces:/home/node/.openclaw/workspaces-source:ro` で担保します。`danger-full-access` はコンテナ内での Codex CLI sandbox を外す設定であり、ホスト全体をマウントする設定ではありません。OpenClaw の Codex backend はデフォルトで `workspace-write` sandbox を明示するため、`config/openclaw.base.json` で fresh/resume 両方の Codex 起動引数を `danger-full-access` に上書きします。`state/` は書き込み可能な永続領域なので、OpenClaw の会話履歴、memory、ワークスペース状態など、Slack 経由の実行で更新される状態が残ります。

`channels.conf` に登録したチャンネルは `channels.slack.groupPolicy="allowlist"` の許可対象としても生成されます。登録済みチャンネルでも、workspace に入るのはメンション付き投稿だけです。環境固有のチャンネルIDは `config/openclaw.base.json` には書かず、git管理外の `workspaces/channels.conf` にだけ置いてください。

workspace の内容を更新したあとに既存セッションを切り直すには、`scripts/workspace-session-invalidator.sh` を使います。workspace 内のファイル種類は問いませんが、`.git`、`.codex`、`.DS_Store` は監視対象から除外します。`scripts/workspace-session-watch.sh` は、workspace 配下の変更を監視して失効させるためのポーリング版です。ポーリング間隔は第1引数で指定し、省略時は5秒です。自動運用したい場合は、この watch スクリプトを `launchd` や `cron` などで常駐させてください。watcher 起動時に既存セッションも失効させたい場合は、`WORKSPACE_SESSION_WATCH_INVALIDATE_ON_START=1` を付けて起動します。

ワークスペースの追加・削除はコンテナ再起動だけで反映されます。

## モデルの変更

`config/openclaw.base.json` の `agents.defaults.model.primary` を変更します:

| モデルID | 特徴 |
|----------|------|
| `codex-cli/gpt-5.5` | 最新フラグシップ（デフォルト、OAuthログイン専用） |
| `codex-cli/gpt-5.4` | 推論 + エージェント向け |
| `codex-cli/gpt-5.4-mini` | 高速・軽量タスク向け |
| `codex-cli/gpt-5.3-codex` | コーディング特化 |

## 運用

```bash
# ログ確認
docker compose logs -f openclaw

# 停止
docker compose stop

# 再起動（ワークスペース追加後）
docker compose restart openclaw

# workspace変更監視（デフォルト5秒間隔）
scripts/workspace-session-watch.sh

# イメージ更新（Dockerfile のバージョンタグを更新後）
docker compose up -d --build
```

## バージョン管理

ベースイメージ（OpenClaw）とCodex CLIの両方をバージョン固定しています。更新する場合:

1. **OpenClaw**: `Dockerfile` の `FROM ghcr.io/openclaw/openclaw:XXXX.X.XX` のタグを変更
2. **Codex CLI**: `npm view @openai/codex version` で最新を確認し、`Dockerfile` のバージョンを変更
