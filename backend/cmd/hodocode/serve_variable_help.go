package main

import (
	"fmt"
	"strings"

	"github.com/hib2018/HodoCode/internal/analyze"
)

// Variable metadata is for local DAP scopes only; it never requests AI translation.
type serveVariableInfo struct {
	Name              string `json:"name"`
	Type              string `json:"type"`
	Kind              string `json:"kind"`
	RuntimeSafe       bool   `json:"runtime_safe"`
	FunctionFile      string `json:"function_file"`
	FunctionStartLine int    `json:"function_start_line"`
	FunctionEndLine   int    `json:"function_end_line"`
}

func variableSyntax(info *analyze.VariableHelp) serveSyntax {
	lines := []string{"種類: " + info.Kind, "型: " + info.Type}
	if info.Declaration.Source != "" {
		lines = append(lines, "", "宣言元:", fmt.Sprintf("%s:%d", info.Declaration.File, info.Declaration.Line), "```go", info.Declaration.Source, "```")
	}
	if info.Initializer != "" {
		lines = append(lines, "", "宣言時の初期化式（現在値ではありません）:", "```go", info.Initializer, "```")
	}
	switch info.InitialKind {
	case "constant":
		label := "初期化時の定数式の値（現在値ではありません）: "
		if info.Kind == "定数" {
			label = "定数値（コンパイル時に確定）: "
		}
		lines = append(lines, "", label+info.InitialValue)
	case "zero":
		value := info.InitialValue
		if value == "zero" {
			value = "型に応じたゼロ値"
		}
		lines = append(lines, "", "明示的なゼロ初期化（宣言時）: "+value)
	case "expression":
		lines = append(lines, "", "初期化式の評価結果は実行せず、値を推測しません。")
	default:
		lines = append(lines, "", "初期値: 静的には取得できません。型検査エラー・引数・外部初期化などを確認してください。ゼロ値とは扱いません。")
	}
	if info.Kind != "定数" {
		lines = append(lines, "", "実行時の値: 静的解析では不明です。")
	}
	referencesTitle := "参照箇所（現在の関数。代入先を含む）:"
	updatesTitle := "直接の代入・更新箇所（現在の関数）:"
	if info.Kind == "フィールド" {
		referencesTitle = "同じ宣言のフィールド参照（異なるインスタンスを含む）:"
		updatesTitle = "同じ宣言のフィールドへの直接更新（異なるインスタンスを含む）:"
	}
	if len(info.References) > 0 {
		lines = append(lines, "", referencesTitle)
		for _, ref := range info.References {
			lines = append(lines, fmt.Sprintf("- %s:%d:%d %s", ref.File, ref.Line, ref.Column, ref.Source))
		}
	}
	lines = append(lines, "", updatesTitle)
	if len(info.Updates) == 0 {
		lines = append(lines, "- 取得できた更新箇所はありません。")
	}
	for _, update := range info.Updates {
		lines = append(lines, fmt.Sprintf("- %s:%d:%d\n```go\n%s\n```", update.File, update.Line, update.Column, update.Source))
	}
	return serveSyntax{
		Title: "変数情報: " + info.Name, Description: strings.Join(lines, "\n"),
		Syntax: info.Name + " " + info.Type, Reference: info.Reference,
		Caution:  "保存済みソースの静的解析です。初期値を現在値とは扱いません。参照先・呼び出し先・別ゴルーチンからの間接的な変更は網羅しません。変数情報・実値は外部AIへ送信しません。",
		Variable: &serveVariableInfo{Name: info.Name, Type: info.Type, Kind: info.Kind, RuntimeSafe: info.RuntimeSafe, FunctionFile: info.FunctionFile, FunctionStartLine: info.FunctionStartLine, FunctionEndLine: info.FunctionEndLine},
	}
}
