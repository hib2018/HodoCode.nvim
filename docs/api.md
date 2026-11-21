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
| `calls` | `{"function":"完全IDまたは一意の接尾辞"}` | `function`、`calls`配列、`Targets`辞書 |
| `syntax` | `{"file":"main.go","row":2,"column":0}` | `title`・`description`・`syntax`・`example`・`caution`・`reference` |
| `reload` | `{}` | `{"reloaded":true}` |

関数・呼び出し情報のフィールド名は既存Go構造体に合わせて大文字始まり。`calls`の要素は`From`、`To`、`Unknown`、`Line`、`Column`、`EndColumn`、`Offset`、`Name`、`Reason`、`Candidates`を持つ。`Targets`はIDからローカル関数への辞書。候補は移動先を確定する根拠として扱わない。SDKソースの遅延読み込みはこのAPIでは追加しない。

`syntax`の`row`は0始まり、`column`は0始まりのUTF-8バイト位置。Neovimのカーソル列をそのまま渡し、バックエンドで既存のルーン位置へ変換する。関数の`Line`/`End`と呼び出し位置は既存解析器の1始まり。`file`はプロジェクト相対パスで、絶対パス・親ディレクトリ参照・ルート外へのシンボリックリンクを拒否する。

`reload`は新しい解析結果の構築に成功したときだけスナップショットを置き換える。失敗時はエラーを返し、Neovim側はその操作を中断する。`syntax`は指定時点のディスク上のファイルを読む。複数ファイルをまたぐディスク更新に対するトランザクション保証はない。Neovim側では操作元バッファの変更番号とファイル状態を確認して遅延応答を破棄する。
