# cmux Cloud スキル

`cmux` CLI を使ってユーザーの Cloud マシンで作業します。このファイルは
アプリが生成するため編集しないでください。記載と実装が異なる場合は
`cmux vm <subcommand> --help` を優先します。

## 基本モデル

- マシンはサインイン中のユーザーが所有する永続 Cloud VM です。生成された名前が操作時のアドレスです。`vm rename` は表示ラベルだけを変更します。
- ターミナルとスクロールバックはマシン上のセッションが保持します。ペインやノートパソコンを閉じてもマシンとプロセスは存続します。
- 管理対象セッションはプライベートな cmux-remote 接続を使います。利用できる操作は応答の `capabilities` で確認し、プロバイダー名から推測しません。
- イメージはバックエンドが選択します。デスクトップや独立した永続ホームボリュームがあるとは限りません。SSH に対応しないマシンもあります。
- Base はユーザーごとに一つの永続スロットです。`vm base` は同じマシンを再度開き、`vm new` は新しいマシンを作成します。
- 一台のマシンに複数のワークスペースを作成できます。タスクごとにマシンを増やすより、マシン内のワークスペースを分けてください。
- ワークスペースは `ws_…`、ターミナルは `term_…` の ID を使います。ワークスペース名は一意の場合のみ使用できます。同名がある場合は ID が必要です。
- `agent-pool` マシンはルーターが管理し再利用します。ユーザーが手動で作成したマシンを勝手にルーターへ取り込みません。
- 台数・メモリ・無料アクセス期間の制限は `vm ls` の現在の応答から確認します。

## 一覧と状態

```bash
cmux vm ls
cmux vm status <id>
cmux vm stats <id>
cmux vm ports <id>
cmux vm tools <id>
cmux vm tree [<machine>|local] [--refresh]
```

## 作成と名前

```bash
cmux vm new [--base] [--size <2g|4g|8g|16g|32g>] [--detach|-d]
cmux vm rename <id> <new-label>
cmux vm base
cmux vm base reset [--reason <text>]
```

`vm new` は位置引数を受け付けません。タイプミスで有料マシンを作成しないためです。
Base のリセットは新しい世代を作り、古いマシンを保持します。

## 接続と表示

```bash
cmux vm shell <id>
cmux vm tui <id>
cmux vm desktop <id>
cmux vm open <machine>
cmux vm open <machine>/<ws>[/<term>]
cmux vm open <machine>:desktop
cmux vm open <machine> <port> [--print]
cmux vm ssh <id>
```

HTTP ポートはプライベートネットワークの URL を使います。デスクトップと SSH は
対応マシンのみ利用できます。`vm tree` のアドレスをそのまま `vm open` に渡せます。

## ワークスペースとターミナル

```bash
cmux vm workspace new <id> [--name <n>]
cmux vm workspace open <id> <ws> [--here|--tabs|--pane <p> --left|--right|--up|--down]
cmux vm workspace rename <id> <ws> <name>
cmux vm workspace rm <id> <ws>
cmux vm workspace close <id> <ws>
cmux vm terminal close <id> <term>
cmux vm terminal send <id> <term> 'bun test' --keys enter
cmux vm terminal wait <id> <term> --pattern 'pass|fail' [--timeout 120]
cmux vm terminal read <id> <term>
cmux surface ls [--json]
cmux surface new-terminal --machine <id> --no-open -- <cmd>
```

`workspace rm` は内部のターミナルも終了します。`workspace close` はターミナルを
実行したままワークスペースを閉じます。`workspace open` は空なら何も開かず、
`vm open <machine>/<ws>` は空のワークスペースでシェルを開始します。
`--tabs` と分割方向は併用せず、方向は一つだけ指定します。

対話プログラムや別のエージェントは `terminal send/wait/read` で操作し、
ユーザーのフォーカスを奪いません。見せる内容ができたときだけペインを開きます。

## コマンドとエージェント

```bash
cmux vm exec <id> -- <command...>
cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <s>] [--timeout <seconds>] -- <command...>
cmux vm route [--cwd <dir>]
cmux vm wait <id> [--timeout <seconds>] [--wake]
cmux vm agent --agent <claude|codex|opencode|pi> [--machine <id>] [--sync] [--cwd <dir>] [--name <name>] [--no-open] [--new] [--size <s>] -- <prompt or args...>
```

`vm run` は空いているプールマシンを再利用し、必要なら起動または作成します。
既定の期限は 600 秒、上限は 15 分です。`--sync` は先に作業ディレクトリを送信し、
`--pull` は終了後に指定パスを取得します。長時間の作業は永続ターミナルの
`vm agent` で開始してください。引数の先頭が通常の文章ならワンショットの
プロンプトとして実行し、フラグや既知のサブコマンドはそのまま渡します。
クラウド用エージェントの認証設定は `cmux ai-accounts upload` で行います。

## ファイルと保存

```bash
cmux vm push <id> <local-path> [remote-path] [--exclude <pattern>]...
cmux vm pull <id> <remote-path> [local-path]
cmux vm snapshot <id> [--name <name>]
cmux vm fork <id> [--name <name>]
cmux vm restore <snapshot-id>
cmux vm rm <id>
```

ディレクトリは tar で転送し、`node_modules` や `.git` などを既定で除外します。
転送サイズには制限があるため、ビルド成果物を含めないでください。
保存・複製・復元は機能契約で対応を確認してください。`vm rm` は確認なしで
不可逆に削除するため、このセッションで作成したマシン以外は、ユーザーが
今回明示的に指定した場合のみ削除できます。

## マシン内の操作

`cmux self [--json]` はこのマシンを識別し、`cmux vm ls [--json]` はチームの稼働中のマシンを一覧表示します。どちらもローカルデーモンを必要とせず、エッジが付与するマシン認証で `GET /api/vm/self` を読み取ります。リンク済みの接続先は `cmux vm peers` で確認できます。

```bash
cmux workspace current run -- bun test
cmux session current snapshot --json
cmux vm peers
cmux vm exec <peer> -- <command>
cmux vm tree <peer>
```

ローカル操作はマシン自身のセッションを使います。接続先への操作には既存の
許可と互換性のあるデーモンが必要です。このビルドには古い Mac の `vm link`
登録処理がないため、新しい接続許可を作成できると案内しないでください。
アカウントの認証情報はマシンに保存しません。

接続完了はデーモンのイベントで通知され、30 秒の期限とキャンセル処理を備えます。
状態確認のためのポーリングは行いません。ゲストの案内言語は `LC_ALL`、
`LC_MESSAGES`、`LANG` の順で選び、英語と日本語に対応します。

## 作業上の規則

- 新規作成は課金と台数制限に影響します。まず `vm ls` を確認し、`vm run` や `vm agent` の再利用を優先します。
- 状態を繰り返し問い合わせず、`vm wait` を使います。
- `--json` はヘルプに記載されたコマンドだけで使い、人間向けの表を解析しません。
- シェル構文を使う場合は `-- sh -c '<script>'` と明示します。
- 料金プランの制限や利用できるサイズは、記憶ではなく現在の CLI 応答から読み取ります。
