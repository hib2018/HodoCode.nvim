package analyze

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestFunctionNamesLocalImportedReferences(t *testing.T) {
	root := t.TempDir()
	source, expected := markedFunctionNames(`package names
import "example.com/names/other"
var reference = other.«Leaf»
var value = other.«Leaf»()
func «run»() { _ = other.«Leaf»; «reference»() }
`)
	for file, text := range map[string]string{
		"go.mod":         "module example.com/names\n\ngo 1.23\n",
		"names.go":       source,
		"other/other.go": "package other\nfunc Leaf() int { return 1 }\n",
	} {
		filename := filepath.Join(root, file)
		if err := os.MkdirAll(filepath.Dir(filename), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filename, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	p, err := LoadLanguage(root, "go")
	if err != nil {
		t.Fatal(err)
	}
	// Imports must come from AST snapshots even when their saved files disappear.
	if err := os.RemoveAll(filepath.Join(root, "other")); err != nil {
		t.Fatal(err)
	}
	got, err := p.FunctionNames("names.go")
	if err != nil || !reflect.DeepEqual(got, expected) {
		t.Fatalf("names = %+v, %v; want %+v", got, err, expected)
	}
}
