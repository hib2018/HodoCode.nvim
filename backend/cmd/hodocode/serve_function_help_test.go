package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestServeImportedFunctionSyntax(t *testing.T) {
	root := serveFixture(t)
	if err := os.Mkdir(filepath.Join(root, "helper"), 0700); err != nil {
		t.Fatal(err)
	}
	for name, source := range map[string]string{
		"main.go":        "package machine\nimport ( f \"fmt\"; h \"example.com/machine/helper\" )\nfunc Entry() { _ = \"日本語\"; f.Println(h.Double(2)); h.NoDoc(); missing(); _ = len(\"abc\"); _ = 1 + 2 }\n",
		"helper/help.go": "package helper\n// Double returns twice the input.\nfunc Double(x int) int { return x * 2 }\nfunc NoDoc() {}\n",
	} {
		if err := os.WriteFile(filepath.Join(root, name), []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
	}
	line := "func Entry() { _ = \"日本語\"; f.Println(h.Double(2)); h.NoDoc(); missing(); _ = len(\"abc\"); _ = 1 + 2 }"
	cases := []struct{ name, title, description, signature, reference string }{
		{"Println", "関数情報: Println", "", "func fmt.Println", "GOROOT/src/fmt/print.go:"},
		{"Double", "関数情報: Double", "Double returns twice the input.", "func example.com/machine/helper.Double(x int) int", "helper/help.go:"},
		{"NoDoc", "関数情報: NoDoc", "説明コメントはありません", "func example.com/machine/helper.NoDoc()", "helper/help.go:"},
		{"missing", "", "", "", ""},
		{"len", "", "", "", ""},
		{"+", "+：加算と文字列連結", "", "", ""},
	}
	var requests strings.Builder
	for i, tc := range cases {
		encoded, err := json.Marshal(map[string]any{"id": i + 1, "method": "syntax", "params": map[string]any{"file": "main.go", "row": 2, "column": strings.Index(line, tc.name)}})
		if err != nil {
			t.Fatal(err)
		}
		requests.Write(encoded)
		requests.WriteByte('\n')
	}
	requests.WriteString("{\"id\":7,\"method\":\"functions\"}\n")
	responses := serveMessages(t, root, requests.String())
	if len(responses) != 7 {
		t.Fatalf("responses: %+v", responses)
	}
	for i, tc := range cases {
		r := responses[i]
		if r.Error != "" {
			t.Fatalf("%s: %s", tc.name, r.Error)
		}
		help := r.Result.(map[string]any)
		if len(help) != 6 {
			t.Fatalf("response schema changed: %+v", help)
		}
		if tc.title == "" {
			if strings.HasPrefix(help["title"].(string), "関数情報:") || help["description"] == "" {
				t.Errorf("%s must retain generic syntax help: %+v", tc.name, help)
			}
			continue
		}
		if help["description"] == "" {
			t.Errorf("%s has no description: %+v", tc.name, help)
		}
		for key, want := range map[string]string{"title": tc.title, "description": tc.description, "syntax": tc.signature, "reference": tc.reference} {
			if !strings.Contains(help[key].(string), want) {
				t.Errorf("%s %s: got %q, want %q", tc.name, key, help[key], want)
			}
		}
	}
	if functions := responses[6].Result.([]any); len(functions) != 3 {
		t.Errorf("function help must not add SDK navigation targets: %+v", functions)
	}
}

func TestServeDependencyTranslationMetadata(t *testing.T) {
	t.Setenv("GOPROXY", "off")
	t.Setenv("GOSUMDB", "off")
	t.Setenv("GOWORK", "off")
	t.Setenv("GOFLAGS", "-mod=readonly")
	root, dep := t.TempDir(), t.TempDir()
	for filename, source := range map[string]string{
		filepath.Join(root, "go.mod"):   "module example.com/help\n\ngo 1.23\nrequire example.com/dep v1.0.0\nreplace example.com/dep => " + filepath.ToSlash(dep) + "\n",
		filepath.Join(dep, "go.mod"):    "module example.com/dep\n\ngo 1.23\n",
		filepath.Join(dep, "dep.go"):    "package dep\n// Work performs external work.\nfunc Work() {}\nfunc NoDoc() {}\n",
		filepath.Join(root, "entry.go"): "package help\nimport (\"example.com/dep\"; \"strings\")\n// Local performs local work.\nfunc Local() {}\nfunc Entry() { dep.Work(); dep.NoDoc(); Local(); _ = strings.NewReader(\"x\").Len() }\n",
	} {
		if err := os.WriteFile(filename, []byte(source), 0600); err != nil {
			t.Fatal(err)
		}
	}
	line := `func Entry() { dep.Work(); dep.NoDoc(); Local(); _ = strings.NewReader("x").Len() }`
	var requests strings.Builder
	for i, marker := range []string{"Work()", "NoDoc()", "Local()", "Len()"} {
		encoded, err := json.Marshal(map[string]any{"id": i + 1, "method": "syntax", "params": map[string]any{"file": "entry.go", "row": 4, "column": strings.Index(line, marker)}})
		if err != nil {
			t.Fatal(err)
		}
		requests.Write(encoded)
		requests.WriteByte('\n')
	}
	responses := serveMessages(t, root, requests.String())
	for i, response := range responses {
		if response.Error != "" {
			t.Fatal(response.Error)
		}
		help := response.Result.(map[string]any)
		if i == 0 {
			if len(help) != 8 || help["translate"] != true || help["documentation"] != "Work performs external work.\n" || help["description"] != help["documentation"] {
				t.Fatalf("dependency translation metadata: %+v", help)
			}
		} else if len(help) != 6 {
			t.Fatalf("non-translatable help schema: %+v", help)
		}
	}
}
