package main

import (
	"bytes"
	"context"
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
