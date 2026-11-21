# コピー元

- プロジェクト: HodoCode
- リポジトリ: https://github.com/hib2018/HodoCode
- 元コミット: `4b2f43fbb484bdca45cd1a4661c7034e23e85205`
- コピー日: 2026-11-21
- ローカルコピー元: `../HodoCode`（コピー時点で作業ツリーに変更なし）

追跡対象のコード・テスト・ドキュメントをコピーした。`.git`、`.agents`、`.pi`、未追跡ファイルは含めていない。コピー元の追跡ファイルにLICENSEはなかったため、上流のライセンスを推測して追加していない。

今後のNeovim向けAPI追加やバックエンド改良は、この`backend/`配下に行う。元リポジトリは変更しない。Goのモジュール名と内部importはコピー時のまま維持している。

## 検証

このディレクトリで実行する。

```sh
go test ./cmd/hodocode ./internal/...
go build -o /tmp/hodocode-nvim-backend ./cmd/hodocode
```
