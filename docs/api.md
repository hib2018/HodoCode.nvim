# Neovim向けバックエンドAPI

```sh
bin/hodocode serve --root /absolute/project --language auto
```

標準入出力のJSON Lines。解析はローカルの保存済みソースのみで、AI送信は行わない。既存CLIコマンドはそのまま残す。各要求は直列に処理され、同時に可変解析キャッシュへアクセスしない。入力は1メッセージ1MiBまで。超過時はエラー応答後に終了する。Neovim側の既定応答上限は1行8MiB、要求タイムアウトは120秒。

要求は整数`id`、文字列`method`、オブジェクト`params`からなる。応答は同じ`id`と`result`を持ち、失敗時は`result: null`と文字列`error`を返す。要求IDを回復できない不正な入力には`id: 0`を使う。

```json
{"id":1,"method":"functions","params":{}}
{"id":1,"result":[{"ID":"example.main","File":"main.go","Language":"go","Line":3,"End":5}]}
```

| method | params | result |
| --- | --- | --- |
| `functions` | `{}` | ローカル関数配列、ID順 |
| `function-names` | `{"file":"main.go"}` | 関数名の位置配列：`Line`・`Column`・`EndColumn`（1始まりのUTF-8バイト位置、終端は含まない） |
| `calls` | `{"function":"完全IDまたは一意の接尾辞"}` | `function`、`calls`配列、`Targets`辞書 |
| `syntax` | `{"file":"main.go","row":2,"column":0}` | `title`・`description`・`syntax`・`example`・`caution`・`reference` |
| `reload` | `{}` | `{"reloaded":true}` |
| `graph` | `{"kind":"deps","dir":".","depth":-1}` または `{"kind":"calls","function":"完全ID","expand":[]}` | `kind`、`nodes:[{id,label}]`、`edges:[{from,to,unknown?}]`、`mermaid` |

関数・呼び出し情報のフィールド名は既存Go構造体に合わせて大文字始まり。`calls`の要素は`From`、`To`、`Unknown`、`Line`、`Column`、`EndColumn`、`Offset`、`Name`、`Reason`、`Candidates`を持つ。`Targets`はIDからローカル関数への辞書。候補は移動先を確定する根拠として扱わない。SDKソースの遅延読み込みはこのAPIでは追加しない。

`function-names`は指定ファイルの解析時スナップショットから、宣言・名前付き呼び出し・識別可能なGoの関数参照を返す。コメント・文字列の中の名前は含めない。Go以外は既存の宣言情報と字句解析が中心で、非呼び出し参照やジェネリック・計算された呼び出しの識別には制限がある。ジャンプ可能性を保証するAPIではなく、強調表示用。追加のファイル読み取りやAI送信はしない。

`syntax`の`row`は0始まり、`column`は0始まりのUTF-8バイト位置。Neovimのカーソル列をそのまま渡し、バックエンドで既存のルーン位置へ変換する。関数の`Line`/`End`と呼び出し位置は既存解析器の1始まり。`file`はプロジェクト相対パスで、絶対パス・親ディレクトリ参照・ルート外へのシンボリックリンクを拒否する。

`syntax`はGoの関数内にある関数名を静的に解決できる場合、既存の応答形式のまま関数情報を優先表示する。`syntax`はシグネチャ、`description`は手書きの日本語説明を登録済みの標準関数ではその説明、未登録の関数では未登録である旨と定義コメント（原文。コメントがなければその旨）、`reference`は定義元のラベルと行番号。標準ライブラリ・repo内・既存のオフライン依存元から取得し、新しいダウンロードやAI送信はしない。型・ソースが解決できない場合、組み込み関数、Go以外は従来の構文解説に戻る。静的な宣言情報であり、動的ディスパッチの実装確定ではない。関数情報の座標は解析スナップショットを使うため、対象ファイルがディスク上で変更されていた場合も従来の構文解説へ戻し、再解析後に関数情報を取得する。

`reload`は新しい解析結果の構築に成功したときだけスナップショットを置き換える。失敗時はエラーを返し、Neovim側はその操作を中断する。`syntax`は指定時点のディスク上のファイルを読む。複数ファイルをまたぐディスク更新に対するトランザクション保証はない。Neovim側では操作元バッファの変更番号とファイル状態を確認して遅延応答を破棄する。

`graph`の`deps`は既存のimport依存図。`dir`はルート相対（既定は全体）、`depth`は-1（既定、無制限）または非負整数。`calls`は既存の`flow`と同じ起点の一段分で、`expand`には現在の図から到達できるローカル関数を順に指定する。未解決エッジは`unknown:true`、Mermaidでは点線。ノードID・ラベルは元の識別子、Mermaid内では安全なエスケープ表現になる。どちらもAIへ送信しない。

## 未保存バッファの送信前処理

```sh
bin/hodocode prepare-buffer --root /absolute/project
```

`serve`とは別の単発コマンド。stdinのJSONを1件読み、マスク済みJSONをstdoutへ返す。失敗はstderrと非0終了。解析・LSP起動・対象コード実行・外部送信はしない。新規ファイルや`go.mod`のないプロジェクトでも、既存の対応言語を前処理できる。

```json
{"file":"main.go","content":"package main\n// secret\n","purpose":"Explain this buffer","excludes":["private","*.secret.go"]}
```

入力に任意の`row`（1始まりのカーソル行）を指定すると、その行を含む最小の関数を未保存の入力ソースから特定し、応答に`start_line/end_line`（1始まり・両端含む）を追加する。関数外ならエラーになり、全文へのフォールバックはしない。`go.mod`・LSPは不要。`content`は引き続き全文のマスク結果であり、Neovim側でこの行範囲だけ切り出して行解説アダプターへ送信する。

応答フィールドは`file/language/content/purpose/version/line_count`（`row`指定時は`start_line/end_line`も含む）。`content`は全文を対象に既存のGo・多言語マスキングで文字列・コメントを空白化したもの。`version`は**元全文のUTF-8バイト列**のSHA-256（小文字hex）。`line_count`はLF個数+1で、末尾LF後の空行も数える。行注釈を受け取る側では、別途実際のバッファ行数を上限に検証する。

プロジェクト相対パス、既存の機密パス除外と指定`excludes`、UTF-8・NULを検査する。ルートを正規化した後、その配下のシンボリックリンクはルート内を指すものも含めて拒否する。入力JSON上限1MiB、元ソースとコンパクトな応答JSONは各128KiB、`purpose`は非空で8KiB以内。stdoutにはJSON後のLFが1バイト加わる。マスキング不能な曖昧な構文は送信せずエラーにする。

これは送信準備であって、秘密の完全除去やCLIのサンドボックスではない。識別子・パス・指示は残る。ファイルシステムの同時置換への原子性や、アダプター自身によるファイル・履歴の読み取りに対する保護は保証しない。行解説・チャットのアダプター契約は[`README.md`](../README.md)を参照。
