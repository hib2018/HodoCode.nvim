package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/hib2018/HodoCode/internal/explain"
)

func TestPrepareBufferCommand(t *testing.T) {
	source := "// SECRET\npackage p\nvar x = \"SECRET\"\n" + strings.Repeat("func entry() {}\n", 20)
	input, _ := json.Marshal(map[string]any{"file": "new.go", "content": source, "purpose": "explain"})
	var out, stderr bytes.Buffer
	runner := func(context.Context, string) (string, error) { t.Fatal("AI called"); return "", nil }
	err := run(context.Background(), []string{"prepare-buffer", "--root", t.TempDir()}, bytes.NewReader(input), &out, &stderr, runner)
	if err != nil {
		t.Fatal(err)
	}
	var result explain.Buffer
	if err := json.Unmarshal(out.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(result.Content, "SECRET") || strings.Count(result.Content, "entry") != 20 || result.LineCount != strings.Count(source, "\n")+1 || len(result.Version) != 64 || stderr.Len() != 0 {
		t.Fatalf("bad response: %s stderr=%s", out.String(), stderr.String())
	}
}

func TestPrepareBufferCommandFunctionScope(t *testing.T) {
	root := t.TempDir()  // No go.mod or source file; only the supplied unsaved buffer exists.
	t.Setenv("PATH", "") // Neither Go tools nor an LSP can run.
	source := "package p\n// SECRET\nfunc first() {\n println(\"秘密\")\n}\n\nfunc second(\n n int,\n) {\n _ = n\n}\n"
	prepare := func(row any) (explain.Buffer, map[string]any, error) {
		t.Helper()
		request := map[string]any{"file": "unsaved/new.go", "content": source, "purpose": "explain"}
		if row != nil {
			request["row"] = row
		}
		input, _ := json.Marshal(request)
		var out, stderr bytes.Buffer
		err := runPrepareBuffer([]string{"--root", root}, bytes.NewReader(input), &out, &stderr)
		if err != nil {
			if out.Len() != 0 {
				t.Fatalf("output on failure: %s", out.String())
			}
			return explain.Buffer{}, nil, err
		}
		var result explain.Buffer
		var fields map[string]any
		if err := json.Unmarshal(out.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(out.Bytes(), &fields); err != nil {
			t.Fatal(err)
		}
		return result, fields, nil
	}
	whole, fields, err := prepare(nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := fields["start_line"]; ok {
		t.Fatal("row absent must omit scope")
	}
	if _, ok := fields["end_line"]; ok {
		t.Fatal("row absent must omit scope")
	}
	if len(fields) != 6 || whole.Version != fmt.Sprintf("%x", sha256.Sum256([]byte(source))) || whole.LineCount != 12 {
		t.Fatalf("old contract changed: %+v", whole)
	}
	for _, tt := range []struct{ row, start, end int }{{3, 3, 5}, {4, 3, 5}, {5, 3, 5}, {8, 7, 11}, {11, 7, 11}} {
		result, fields, err := prepare(tt.row)
		if err != nil || result.StartLine != tt.start || result.EndLine != tt.end || len(fields) != 8 {
			t.Fatalf("row %d: %+v, %v", tt.row, result, err)
		}
		result.StartLine, result.EndLine = 0, 0
		if result != whole || strings.Contains(result.Content, "SECRET") || strings.Contains(result.Content, "秘密") {
			t.Fatalf("scope changed full-buffer contract: %+v", result)
		}
	}
	for _, row := range []any{-1, 0, 1, 2, 6, 12, 13} {
		if _, _, err := prepare(row); err == nil || !strings.Contains(err.Error(), "no function at cursor") {
			t.Fatalf("row %v: %v", row, err)
		}
	}
	for _, row := range []any{1.5, "4", true} {
		if _, _, err := prepare(row); err == nil {
			t.Fatalf("accepted invalid row %v", row)
		}
	}
}

func TestPrepareBufferCommandInvalid(t *testing.T) {
	for _, input := range []string{
		"", "null", "[]", `{}`, `{"file":"a.go","purpose":"explain"}`,
		`{"file":"a.go","content":"","purpose":"explain","extra":1}`,
		`{"file":"a.go","content":"","purpose":"explain"} {}`,
		`{"file":"a.go","content":"","purpose":"explain"} garbage`,
		string([]byte{'{', 255, '}'}), strings.Repeat(" ", maxBufferInput+1),
	} {
		t.Run(fmt.Sprintf("%.30q", input), func(t *testing.T) {
			var out, stderr bytes.Buffer
			if err := runPrepareBuffer([]string{"--root", t.TempDir()}, strings.NewReader(input), &out, &stderr); err == nil || out.Len() != 0 {
				t.Fatalf("accepted input: %v, %s", err, out.String())
			}
		})
	}
}

func TestPrepareBufferCommandHelp(t *testing.T) {
	var out, stderr bytes.Buffer
	if err := runPrepareBuffer([]string{"--help"}, strings.NewReader(""), &out, &stderr); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(stderr.String(), "131072") || !strings.Contains(stderr.String(), "1048576") {
		t.Fatalf("missing limits: %s", stderr.String())
	}
}
