package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/hib2018/HodoCode/internal/analyze"
)

func TestServeFunctionNames(t *testing.T) {
	responses := serveMessages(t, serveFixture(t), `{"id":1,"method":"function-names","params":{"file":"main.go"}}
{"id":2,"method":"function-names","params":{}}
{"id":3,"method":"function-names","params":{"file":"../secret.go"}}
{"id":4,"method":"function-names","params":{"file":"go.mod"}}
`)
	if len(responses) != 4 || responses[0].Error != "" {
		t.Fatalf("responses: %+v", responses)
	}
	encoded, err := json.Marshal(responses[0].Result)
	if err != nil {
		t.Fatal(err)
	}
	var got []analyze.FunctionName
	if err := json.Unmarshal(encoded, &got); err != nil {
		t.Fatal(err)
	}
	expected := []analyze.FunctionName{{Line: 2, Column: 6, EndColumn: 11}, {Line: 2, Column: 16, EndColumn: 20}, {Line: 2, Column: 24, EndColumn: 28}, {Line: 3, Column: 6, EndColumn: 10}, {Line: 4, Column: 6, EndColumn: 15}}
	if !reflect.DeepEqual(got, expected) {
		t.Fatalf("names: %+v; want %+v", got, expected)
	}
	for _, response := range responses[1:] {
		if response.Error == "" || response.Result != nil {
			t.Fatalf("invalid request accepted: %+v", response)
		}
	}
}

func TestServeFunctionNamesSnapshotAndEmptyArray(t *testing.T) {
	root := serveFixture(t)
	if err := os.WriteFile(filepath.Join(root, "empty.go"), []byte("package machine\nvar value = 1\n"), 0600); err != nil {
		t.Fatal(err)
	}
	p, err := analyze.LoadLanguage(root, "go")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("invalid source"), 0600); err != nil {
		t.Fatal(err)
	}
	absolute := serveRequest{Method: "function-names"}
	absolute.Params.File = filepath.Join(root, "main.go")
	if _, err := serveDispatch(context.Background(), &p, root, "go", absolute); err == nil {
		t.Fatal("accepted absolute file path")
	}
	for _, tc := range []struct {
		file  string
		count int
	}{{"main.go", 5}, {"empty.go", 0}} {
		req := serveRequest{Method: "function-names"}
		req.Params.File = tc.file
		result, err := serveDispatch(context.Background(), &p, root, "go", req)
		if err != nil {
			t.Fatal(err)
		}
		names := result.([]analyze.FunctionName)
		if names == nil || len(names) != tc.count {
			t.Fatalf("%s: %#v", tc.file, names)
		}
		if len(names) == 0 {
			encoded, _ := json.Marshal(result)
			if string(encoded) != "[]" {
				t.Fatalf("empty JSON: %s", encoded)
			}
		}
	}
}
