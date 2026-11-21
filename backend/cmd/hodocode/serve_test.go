package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/hib2018/HodoCode/internal/analyze"
)

func serveFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for name, text := range map[string]string{
		"go.mod":  "module example.com/machine\n\ngo 1.23\n",
		"main.go": "package machine\nfunc Entry() { Leaf(); Leaf() }\nfunc Leaf() {}\nfunc 日本語() { _ = \"🙂\"; 日本 := 1; _ = 日本 + 2 }\n",
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	canonical, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	return canonical
}

func serveMessages(t *testing.T, root, input string) []serveResponse {
	t.Helper()
	var output, diagnostics bytes.Buffer
	if err := run(context.Background(), []string{"serve", "--root", root, "--language", "auto"}, strings.NewReader(input), &output, &diagnostics, nil); err != nil {
		t.Fatalf("serve: %v; stderr: %s", err, &diagnostics)
	}
	decoder := json.NewDecoder(&output)
	var responses []serveResponse
	for {
		var response serveResponse
		if err := decoder.Decode(&response); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	return responses
}

func TestServeFunctionsAndCalls(t *testing.T) {
	responses := serveMessages(t, serveFixture(t), `{"id":1,"method":"functions"}
{"id":2,"method":"calls","params":{"function":"Entry"}}
{"id":3,"method":"calls","params":{"function":"Leaf"}}
`)
	if len(responses) != 3 {
		t.Fatalf("responses: %+v", responses)
	}
	for i, response := range responses {
		if response.ID != i+1 || response.Error != "" {
			t.Fatalf("response: %+v", response)
		}
	}
	functions := responses[0].Result.([]any)
	if len(functions) != 3 {
		t.Fatalf("functions: %v", functions)
	}
	previous := ""
	for _, value := range functions {
		function := value.(map[string]any)
		id := function["ID"].(string)
		if id <= previous || function["File"] != "main.go" || function["Line"] == nil || function["End"] == nil {
			t.Fatalf("function: %v", function)
		}
		previous = id
	}
	calls := responses[1].Result.(map[string]any)
	sites := calls["calls"].([]any)
	if len(sites) != 2 || sites[0].(map[string]any)["To"] != "example.com/machine.Leaf" || calls["function"].(map[string]any)["ID"] != "example.com/machine.Entry" {
		t.Fatalf("calls: %v", calls)
	}
	if calls["Targets"].(map[string]any)["example.com/machine.Leaf"].(map[string]any)["File"] != "main.go" {
		t.Fatalf("targets: %v", calls)
	}
	if empty := responses[2].Result.(map[string]any)["calls"].([]any); len(empty) != 0 {
		t.Fatalf("leaf calls: %v", empty)
	}
}

func TestServeSyntaxUTF8AndSecurity(t *testing.T) {
	root := serveFixture(t)
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "secret.go"), []byte("package secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "secret.go"), filepath.Join(root, "link.go")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "sample.py"), []byte("値 = 1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	line := "func 日本語() { _ = \"🙂\"; 日本 := 1; _ = 日本 + 2 }"
	plus := strings.Index(line, "+")
	cases := []struct {
		file        string
		row, column int
		bad         bool
	}{
		{"main.go", 3, plus, false},
		{"main.go", 3, strings.Index(line, "日本") + 1, true},
		{"main.go", 3, strings.Index(line, "🙂") + 1, true},
		{"main.go", -1, 0, true},
		{"main.go", 300, 0, true},
		{"main.go", 0, 1000, true},
		{"../secret.go", 0, 0, true},
		{filepath.Join(outside, "secret.go"), 0, 0, true},
		{"escape/secret.go", 0, 0, true},
		{"link.go", 0, 0, true},
		{"go.mod", 0, 0, true},
		{"sample.py", 0, len("値 "), false},
	}
	// Direct syntax checks avoid starting an unrelated Python language server.
	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			result, err := serveSyntaxAt(root, tc.file, tc.row, tc.column)
			if (err != nil) != tc.bad {
				t.Fatalf("result=%v err=%v", result, err)
			}
			if !tc.bad {
				value := result.(serveSyntax)
				if value.Description == "" || value.Reference == "" {
					t.Fatalf("syntax: %+v", value)
				}
				if tc.file == "main.go" && value.Title != "+：加算と文字列連結" {
					t.Fatalf("wrong UTF8 selection: %+v", value)
				}
			}
		})
	}
	if err := os.Remove(filepath.Join(root, "sample.py")); err != nil {
		t.Fatal(err)
	}
	input, _ := json.Marshal(map[string]any{"id": 7, "method": "syntax", "params": map[string]any{"file": "main.go", "row": 3, "column": plus}})
	response := serveMessages(t, root, string(input)+"\n")[0]
	syntax := response.Result.(map[string]any)
	if response.ID != 7 || response.Error != "" || len(syntax) != 6 || syntax["title"] != "+：加算と文字列連結" {
		t.Fatalf("syntax response: %+v", response)
	}
}

func TestServeMalformedMessages(t *testing.T) {
	responses := serveMessages(t, serveFixture(t), `no json
{"id":2,"method":"unknown"}
{"id":3,"method":"calls","params":{"function":"missing"}}
{"id":4,"method":"calls"}
{"method":"functions"}
{"id":"wrong","method":"functions"}
null
{"id":8,"method":"syntax","params":{"row":"wrong"}}
{"id":9,"method":"functions"} trailing
{"id":10,"method":"functions"}
`)
	if len(responses) != 10 {
		t.Fatalf("responses: %+v", responses)
	}
	for _, response := range responses[:9] {
		if response.Error == "" || response.Result != nil {
			t.Fatalf("expected protocol error: %+v", response)
		}
	}
	if responses[9].Error != "" || responses[9].ID != 10 {
		t.Fatalf("stream did not recover: %+v", responses[9])
	}
}

func TestServeReload(t *testing.T) {
	root := serveFixture(t)
	responses := serveMessages(t, root, "{\"id\":1,\"method\":\"reload\"}\n{\"id\":2,\"method\":\"functions\"}\n")
	if len(responses) != 2 || responses[0].Error != "" || responses[0].Result.(map[string]any)["reloaded"] != true || responses[1].Error != "" {
		t.Fatalf("reload protocol: %+v", responses)
	}
	p, err := analyze.LoadLanguage(root, "auto")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "new.go"), []byte("package machine\nfunc Added() {}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, ok := p.Functions["example.com/machine.Added"]; ok {
		t.Fatal("snapshot changed without reload")
	}
	result, err := serveDispatch(context.Background(), &p, p.Root, "auto", serveRequest{Method: "reload"})
	if err != nil || result.(map[string]bool)["reloaded"] != true {
		t.Fatalf("reload=%v err=%v", result, err)
	}
	if _, ok := p.Functions["example.com/machine.Added"]; !ok {
		t.Fatal("reload missed saved source")
	}
	previous := p
	if err := os.WriteFile(filepath.Join(root, "new.go"), []byte("package !"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := serveDispatch(context.Background(), &p, p.Root, "auto", serveRequest{Method: "reload"}); err == nil || p != previous {
		t.Fatalf("failed reload lost original snapshot: %v", err)
	}
}

func TestServeInputBoundAndFlags(t *testing.T) {
	root := serveFixture(t)
	var output bytes.Buffer
	err := runServe(context.Background(), []string{"--root", root}, strings.NewReader(strings.Repeat("x", maxServeMessage+1)+"\n"), &output, io.Discard)
	if err == nil || !strings.Contains(output.String(), `"result":null`) || !strings.Contains(output.String(), `"error":`) {
		t.Fatalf("oversized request: err=%v output=%s", err, &output)
	}
	for _, args := range [][]string{{"--help"}, {"extra"}, {"--repo", "https://example.com"}} {
		err := runServe(context.Background(), args, strings.NewReader(""), io.Discard, io.Discard)
		if (err == nil) != (args[0] == "--help") {
			t.Fatalf("args=%v err=%v", args, err)
		}
	}
}
