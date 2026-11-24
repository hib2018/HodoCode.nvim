package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestServeVariableSyntax(t *testing.T) {
	root := serveFixture(t)
	source := strings.Join([]string{
		"package machine", "import \"fmt\"", "const Limit = 1 << 3", "var Global = 2", "type Item struct { Value int }", "func Entry(arg int) {",
		" var zero int", " n := Limit", " n++", " _ = n", " var item Item", " _ = item.Value", " _ = arg", " _ = Global", " _ = Limit", " fmt.Println(n)", " { n := 2; _ = n }", "}", "",
	}, "\n")
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(source, "\n")
	cases := []struct {
		name string
		row  int
		kind string
		safe bool
		want []string
	}{
		{"zero", 6, "ローカル変数", true, []string{"型: int", "ゼロ初期化", "実行時の値: 静的解析では不明"}},
		{"n", 9, "ローカル変数", false, []string{"宣言時の初期化式", "Limit", "n++", "直接の代入・更新"}},
		{"arg", 12, "パラメータ", true, []string{"初期値: 静的には取得できません"}},
		{"Value", 11, "フィールド", false, []string{"初期値: 静的には取得できません", "異なるインスタンスを含む"}},
		{"Global", 13, "パッケージ変数", false, []string{"宣言時の初期化式", "2"}},
		{"Limit", 14, "定数", false, []string{"定数値（コンパイル時に確定）: 8"}},
	}
	var input strings.Builder
	for i, tc := range cases {
		request, _ := json.Marshal(map[string]any{"id": i + 1, "method": "syntax", "params": map[string]any{"file": "main.go", "row": tc.row, "column": strings.Index(lines[tc.row], tc.name)}})
		input.Write(request)
		input.WriteByte('\n')
	}
	results := serveMessages(t, root, input.String())
	if len(results) != len(cases) {
		t.Fatalf("responses: %+v", results)
	}
	for i, tc := range cases {
		if results[i].Error != "" {
			t.Fatalf("%s: %s", tc.name, results[i].Error)
		}
		result := results[i].Result.(map[string]any)
		if result["title"] != "変数情報: "+tc.name || result["variable"] == nil {
			t.Fatalf("%s: %+v", tc.name, result)
		}
		meta := result["variable"].(map[string]any)
		if meta["name"] != tc.name || meta["kind"] != tc.kind || meta["runtime_safe"] != tc.safe {
			t.Errorf("%s metadata: %+v", tc.name, meta)
		}
		if _, ok := result["translate"]; ok {
			t.Errorf("variable must never translate: %+v", result)
		}
		if _, ok := result["documentation"]; ok {
			t.Errorf("variable must never send documentation: %+v", result)
		}
		for _, want := range tc.want {
			if !strings.Contains(result["description"].(string), want) {
				t.Errorf("%s missing %q: %+v", tc.name, want, result)
			}
		}
	}
}
