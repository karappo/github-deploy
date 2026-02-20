# github-deploy

GitHub Actions を使ったデプロイスクリプト集です。rsync または lftp でファイルをサーバーに転送します。

## 動作フロー

```mermaid
flowchart LR
  subgraph Local
    A[1. 開発]
  end

  A -->|2. Push| B["GitHub<br/>engineer/their-work"]

  subgraph GA["GitHub Actions"]
    direction TB
    C[3. Clone]
    D["4. deploy.sh を取得<br/>karappo/github-deploy"]
    subgraph exec["5. 実行"]
      direction TB
      E["Before<br/><em>カスタマイズ可能</em><br/>置換処理など"]
      F["Sync<br/><strong>rsync or lftp</strong>"]
      G["After<br/><em>カスタマイズ可能</em><br/>キャッシュクリアなど"]
      E --> F --> G
    end
    C --> D --> exec
  end

  B --> GA

  subgraph Servers["デプロイ先"]
    H[本番サーバー]
    I[ステージングサーバー]
  end

  exec -->|配信| Servers
```

## 特徴

- **rsync または lftp** でファイルを転送
- **ブランチごとの環境切り替え** — 環境変数の命名規則で本番・ステージング等を自動判別
- **カスタマイズ可能な前後処理** — [インクルードファイル](#インクルードファイル)で同期前後に任意のスクリプトを実行
- **除外ファイル指定** — [イグノアファイル](#除外ファイルイグノアファイル)でデプロイ対象外を管理

## セットアップ

### 1. SSH鍵の作成

```sh
ssh-keygen -t rsa -b 4096 -f ~/Desktop/ssh_key -C '<project_name>@github-actions'
```

以下の2ファイルが作成されます。

- `~/Desktop/ssh_key` — 秘密鍵
- `~/Desktop/ssh_key.pub` — 公開鍵

### 2. デプロイ先サーバーの設定

デプロイ先サーバーに接続し、`~/.ssh/authorized_keys` に公開鍵（`ssh_key.pub`）の内容を追記します。

- ファイルが存在しない場合は作成し、パーミッションを `600` に設定
- ファイル末尾に空行があることを確認

### 3. GitHub Secrets の登録

リポジトリの **Settings > Secrets and variables > Actions** で以下を登録します。

| Secret 名 | 内容 |
|:--|:--|
| `SSH_KEY` | 秘密鍵（`ssh_key`）の内容をそのままペースト。末尾の空行を削除しないこと |
| `KNOWN_HOSTS` | ローカルでデプロイ先に SSH 接続後、`~/.ssh/known_hosts` から該当行をコピー。末尾の空行を含めること |

`KNOWN_HOSTS` の例:

```
[ssh-xxx.example.net]:XXXX,[XXX.XXX.XXX.XXX]:XXXX ssh-rsa AAAAB...Q==

```

### 4. deploy.yml の作成

`.github/workflows/deploy.yml` を作成します。

```yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 1

      - name: Setup SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_KEY }}" > ~/.ssh/id_rsa
          chmod 600 ~/.ssh/id_rsa
          echo "${{ secrets.KNOWN_HOSTS }}" > ~/.ssh/known_hosts

      - name: Deploy
        env:
          GITHUB_REF_NAME: ${{ github.ref_name }}
          DEP_MAIN_COMMAND: rsync
          DEP_MAIN_HOST: example.com
          DEP_MAIN_USER: username
          DEP_MAIN_HOST_DIR: /home/username/www
        run: |
          curl -sS https://raw.githubusercontent.com/karappo/github-deploy/refs/heads/main/deploy.sh | bash
```

#### 複数ブランチへの対応

ステージング環境なども同時にデプロイする場合:

```yml
on:
  push:
    branches: [main, staging]

# ...

      - name: Deploy
        env:
          GITHUB_REF_NAME: ${{ github.ref_name }}
          # main ブランチ用
          DEP_MAIN_COMMAND: rsync
          DEP_MAIN_HOST: example.com
          DEP_MAIN_USER: username
          DEP_MAIN_HOST_DIR: /home/username/www
          # staging ブランチ用
          DEP_STAGING_COMMAND: rsync
          DEP_STAGING_HOST: stg.example.com
          DEP_STAGING_USER: username
          DEP_STAGING_HOST_DIR: /home/username/stg
        run: |
          curl -sS https://raw.githubusercontent.com/karappo/github-deploy/refs/heads/main/deploy.sh | bash
```

### 5. 動作確認

対象ブランチに push 後、リポジトリの **Actions** タブでワークフローの実行結果を確認します。

## 環境変数

`[BRANCH]` にはブランチ名を大文字で指定します（例: `main` → `MAIN`、`staging` → `STAGING`）。

`DEP_[BRANCH]_XXX` が見つからない場合は `DEP_REMOTE_XXX` がフォールバックとして使用されます。複数環境で共通の設定がある場合に便利です。

### 必須

| 変数名 | 値 | 説明 |
|:--|:--|:--|
| `DEP_[BRANCH]_COMMAND` | `rsync` または `lftp` | 同期コマンド（`rsync` 推奨） |
| `DEP_[BRANCH]_HOST` | 例: `example.com` | デプロイ先ホスト |
| `DEP_[BRANCH]_USER` | | SSH または FTP ユーザー名 |
| `DEP_[BRANCH]_HOST_DIR` | 例: `/home/user/www` | デプロイ先ディレクトリ。rsync の場合は**絶対パス**、lftp の場合は**相対パス** |

### オプション

| 変数名 | 値 | 説明 |
|:--|:--|:--|
| `DEP_[BRANCH]_PASSWORD` | | rsync で RSA 認証を使う場合は不要 |
| `DEP_[BRANCH]_FTPS` | `yes` / `no` | デフォルト `yes`。FTPS 非対応サーバーの場合のみ `no` に設定 |
| `DEP_[BRANCH]_PORT` | 例: `2222` | rsync で 22 番以外のポートを使用する場合 |
| `DEP_[BRANCH]_INCLUDE_FILE` | 例: `./.depinc.sh` | [インクルードファイル](#インクルードファイル)のパスまたは URL |
| `DEP_[BRANCH]_IGNORE_FILE` | 例: `./.depignore` | [イグノアファイル](#除外ファイルイグノアファイル)のパスまたは URL。未指定時は[デフォルト](https://raw.githubusercontent.com/karappo/github-deploy/refs/heads/main/.depignore)を使用 |

## インクルードファイル

同期の前後にカスタム処理を実行できるファイルです。

### 用途の例

- 環境ごとの DB 設定の切り替え
- ステージング環境のみ Basic 認証を有効化
- デプロイ後のパーミッション設定

### 使い方

`before_sync` と `after_sync` の2つの関数を定義します。

.depinc.sh

```sh
before_sync(){
  # 同期前の処理
}
after_sync(){
  # 同期後の処理
}
```

環境変数でパスを指定します。

```yml
env:
  DEP_REMOTE_INCLUDE_FILE: ./.depinc.sh
```

URL での指定も可能です。

```yml
env:
  DEP_REMOTE_INCLUDE_FILE: https://raw.githubusercontent.com/karappo/github-deploy/refs/heads/main/include-files/wordpress/.depinc.sh
```

### WordPress での例

wp-config.php で環境ごとの DB 設定を切り替える場合:

```php
// ローカル環境（デプロイ時に除去される）
//DEP_REMOTE_RM /*
define('DB_NAME', 'LOCAL_DATABASE');
define('DB_USER', 'root');
define('DB_PASSWORD', 'root');
define('DB_HOST', 'localhost');
//DEP_REMOTE_RM */

// 本番環境（main ブランチのデプロイ先でのみ有効化）
//DEP_MAIN_RM define('DB_NAME', 'PROD_DATABASE');
//DEP_MAIN_RM define('DB_USER', 'PROD_USER');
//DEP_MAIN_RM define('DB_PASSWORD', 'PROD_PASSWORD');
//DEP_MAIN_RM define('DB_HOST', 'PROD_HOST');

// ステージング環境
//DEP_STAGING_RM define('DB_NAME', 'STAGING_DATABASE');
//DEP_STAGING_RM define('DB_USER', 'STAGING_USER');
//DEP_STAGING_RM define('DB_PASSWORD', 'STAGING_PASSWORD');
//DEP_STAGING_RM define('DB_HOST', 'STAGING_HOST');
```

.htaccess でステージング環境のみ Basic 認証を有効化する場合:

```apache
# Basic Authentication
#DEP_STAGING_RM <Files ~ "^\.(htaccess|htpasswd)$">
#DEP_STAGING_RM deny from all
#DEP_STAGING_RM </Files>
#DEP_STAGING_RM AuthUserFile /home/example/www/.htpasswd
#DEP_STAGING_RM AuthGroupFile /dev/null
#DEP_STAGING_RM AuthName "Please enter your ID and password"
#DEP_STAGING_RM AuthType Basic
#DEP_STAGING_RM require valid-user
#DEP_STAGING_RM order deny,allow
```

### 用意済みインクルードファイル

[`include-files`](https://github.com/karappo/github-deploy/tree/main/include-files) ディレクトリに以下のテンプレートがあります。

| ディレクトリ | 用途 |
|:--|:--|
| `php/` | PHP サイト向け（htaccess・robots.txt・PHP ファイルの置換処理） |
| `wordpress/` | WordPress 向け（PHP の置換処理 + デプロイ後のパーミッション設定） |
| `coreserver/` | CoreServer 向け（SSH 登録 + PHP の置換処理） |
| `modx-tmpl/` | MODX 向けテンプレート（要カスタマイズ） |

## 除外ファイル（イグノアファイル）

同期時に転送から除外するファイルを指定します。

.depignore

```sh
.git/
.sass-cache/
.gitignore
README*

# github-deploy
.depignore
.depinc.sh
deploy.sh
```

環境変数でパスを指定します。

```yml
env:
  DEP_MAIN_IGNORE_FILE: ./.depignore
```

未指定の場合は[デフォルトのイグノアファイル](https://raw.githubusercontent.com/karappo/github-deploy/refs/heads/main/.depignore)が自動的にダウンロードされます。

**注意:** コメントは行頭の `#` のみ対応。行中の `#` はコメントとして扱われません（lftp の制約）。

## FAQ

### `Fatal error: Certificate verification: Not trusted` が出る

デプロイ先サーバーが FTPS に対応していない可能性があります。`DEP_[BRANCH]_FTPS` を `no` に設定してください。

```
[DEPLOY] - sync -> via FTPS
ftp://user:password@host.com
mirror: Fatal error: Certificate verification: Not trusted
[DEPLOY] - sync -> [ERROR]
```

### 特定のタイミングでデプロイをスキップしたい

コミットメッセージに `[skip ci]` を含めると、GitHub Actions の実行がスキップされます。

```sh
git commit --allow-empty -m '[skip ci]'
```

参考: [GitHub Actions - ワークフローのスキップ](https://docs.github.com/ja/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/skipping-workflow-runs)

## ライセンス

[MIT License](https://github.com/karappo/github-deploy/blob/main/LICENSE-MIT)
