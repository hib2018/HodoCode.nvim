package main

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func TestExtract(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		"nested/pkg/api.go": `package notTheDirectory
// Shared documentation.
func Zebra() {}
// Shared documentation.
func Alpha() {}
// Hidden function.
func private() {}
func Undocumented() {}
type Public[T any, U any] struct{}
type privateType struct{}
// Generic pointer method.
func (p *Public[T, U]) Method() {}
// Hidden receiver.
func (p privateType) Exported() {}
// Hidden method.
func (p *Public[T, U]) hidden() {}
`,
		"nested/pkg/api_windows.go": `//go:build windows

package notTheDirectory
// Shared documentation.
func Alpha() {}
// Windows only.
func Windows() {}
`,
		"nested/pkg/api_linux.go": `//go:build linux

package notTheDirectory
// Linux only.
func Linux() {}
`,
		"other/api.go":  "package other\n// Shared documentation.\nfunc Shared() {}\n",
		"single/api.go": "package single\ntype Public[T any] struct{}\n// Single parameter.\nfunc (p Public[T]) Method() {}\n",
	}
	for _, excluded := range []string{"internal", "vendor", "cmd", "testdata", ".hidden", "nested/pkg/internal", "nested/pkg/testdata"} {
		files[excluded+"/bad.go"] = "this must not be parsed"
	}
	files["nested/pkg/api_test.go"] = "this must not be parsed"
	files["nested/pkg/.hidden.go"] = "this must not be parsed"
	for name, text := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(text), 0644); err != nil {
			t.Fatal(err)
		}
	}
	docs, err := extract(root)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string][]string{
		"Shared documentation.\n":   {"nested/pkg.Alpha", "nested/pkg.Zebra", "other.Shared"},
		"Generic pointer method.\n": {"nested/pkg.Public.Method"},
		"Single parameter.\n":       {"single.Public.Method"},
		"Windows only.\n":           {"nested/pkg.Windows"},
		"Linux only.\n":             {"nested/pkg.Linux"},
	}
	if len(docs) != len(want) {
		t.Fatalf("got %d documents, want %d: %+v", len(docs), len(want), docs)
	}
	if !sort.SliceIsSorted(docs, func(i, j int) bool { return docs[i].ID < docs[j].ID }) {
		t.Fatal("documents not sorted by ID")
	}
	for _, doc := range docs {
		if doc.ID != fmt.Sprintf("%x", sha256.Sum256([]byte(doc.Text))) {
			t.Errorf("incorrect hash for %q", doc.Text)
		}
		if !reflect.DeepEqual(doc.References, want[doc.Text]) {
			t.Errorf("references for %q: got %v, want %v", doc.Text, doc.References, want[doc.Text])
		}
	}
}

func TestExtractSkipsOutsideSymlink(t *testing.T) {
	root := t.TempDir()
	outside := filepath.Join(t.TempDir(), "outside.go")
	if err := os.WriteFile(outside, []byte("package outside\n// Outside documentation.\nfunc Outside() {}\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linked.go")); err != nil {
		t.Skipf("cannot create symlink on this platform: %v", err)
	}
	docs, err := extract(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(docs) != 0 {
		t.Fatalf("collected documents from outside symlink: %+v", docs)
	}
}

func TestExtractErrors(t *testing.T) {
	root := t.TempDir()
	if _, err := extract(filepath.Join(root, "missing")); err == nil {
		t.Fatal("missing root should fail")
	}
	if err := os.WriteFile(filepath.Join(root, "bad.go"), []byte("not Go"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := extract(root); err == nil {
		t.Fatal("invalid source should fail")
	}
}
