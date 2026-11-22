package analyze

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/hib2018/HodoCode/internal/sourcelex"
)

func markedFunctionNames(marked string) (string, []FunctionName) {
	var source strings.Builder
	expected := []FunctionName{}
	for {
		start := strings.Index(marked, "«")
		if start < 0 {
			source.WriteString(marked)
			break
		}
		source.WriteString(marked[:start])
		marked = marked[start+len("«"):]
		end := strings.Index(marked, "»")
		prefix := source.String()
		column := len(prefix) - strings.LastIndex(prefix, "\n")
		expected = append(expected, FunctionName{Line: strings.Count(prefix, "\n") + 1, Column: column, EndColumn: column + end})
		source.WriteString(marked[:end])
		marked = marked[end+len("»"):]
	}
	return source.String(), expected
}

func TestFunctionNamesGoSnapshot(t *testing.T) {
	source, expected := markedFunctionNames(`package names
import ext "unavailable.example/ext"
func «leaf»() int { return 1 }
var reference = «leaf»
var initial = «leaf»()
type Box[T any] struct{}
func (
 b *Box[T],
) «Method»(callback func()) {
 _ = "leaf() fake()" // leaf() fake()
 日本 := "値"; _ = 日本; «leaf»(); «reference»(); _ = «callback»
 «callback»()
 «Generic»[int](1)
 b.«Method»(«leaf»)
 _ = b.«Method»
 ext.«External»()
 «unresolved»()
 _ = int(1); _ = Box[int]{}
 _ = «len»(日本)
 func(){ «leaf»() }()
}
func «Generic»[
 T any,
](value T) T { return value }
var typed func()
var saved = «typed»
`)
	root := t.TempDir()
	for file, text := range map[string]string{"go.mod": "module example.com/names\n\ngo 1.23\n", "names.go": source, "empty.go": "package names\nvar scalar = 1\n"} {
		if err := os.WriteFile(filepath.Join(root, file), []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	p, err := LoadLanguage(root, "go")
	if err != nil {
		t.Fatal(err)
	}
	// The query must not re-read a replaced source or follow a new symlink.
	if err := os.Remove(filepath.Join(p.Root, "names.go")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(t.TempDir(), "missing.go"), filepath.Join(p.Root, "names.go")); err != nil {
		t.Fatal(err)
	}
	got, err := p.FunctionNames("names.go")
	if err != nil || !reflect.DeepEqual(got, expected) {
		t.Fatalf("names = %+v, %v; want %+v", got, err, expected)
	}
	empty, err := p.FunctionNames("empty.go")
	if err != nil || empty == nil || len(empty) != 0 {
		t.Fatalf("empty = %#v, %v", empty, err)
	}
	for _, file := range []string{"", "../names.go", filepath.Join(p.Root, "names.go"), filepath.Join(t.TempDir(), "names.go"), "go.mod", "missing.go", "link.go"} {
		if _, err := p.FunctionNames(file); err == nil {
			t.Errorf("accepted %q", file)
		}
	}
}

func TestFunctionNamesPolyglot(t *testing.T) {
	for _, tc := range []struct{ language, file, marked string }{
		{"javascript", "main.js", "const «arrow» = () => «external»();\nfunction «leaf»() { /* fake() */ return \"fake()\"; }\n«unknown»(); obj.«method»(); const value = /fake()/;\n"},
		{"python", "main.py", "def «leaf»():\n    return 'fake()' # fake()\n«external»()\nobj.«method»()\n"},
		{"rust", "main.rs", "fn «leaf»() { /* fake() */ «external»(); }\n"},
	} {
		t.Run(tc.language, func(t *testing.T) {
			source, expected := markedFunctionNames(tc.marked)
			tokens, err := sourcelex.Scan(tc.language, source)
			if err != nil {
				t.Fatal(err)
			}
			root := t.TempDir()
			file := filepath.Join(root, tc.file)
			p := &Project{Root: root, sources: map[string][]byte{file: []byte(source)}, polyglot: map[string]polyFunction{}}
			pairs := polyPairs(tokens)
			for i, fn := range polyParse(tc.language, source, tokens, pairs) {
				fn.file, fn.language, fn.tokens = file, tc.language, tokens
				p.polyglot[string(rune('a'+i))] = fn
			}
			got, err := p.FunctionNames(tc.file)
			if err != nil || !reflect.DeepEqual(got, expected) {
				t.Fatalf("names = %+v, %v; want %+v", got, err, expected)
			}
		})
	}
}
