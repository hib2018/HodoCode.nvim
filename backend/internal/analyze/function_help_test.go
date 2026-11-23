package analyze

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func functionHelpAt(t *testing.T, p *Project, file, source, marker string) *FunctionHelp {
	t.Helper()
	offset := strings.Index(source, marker)
	if offset < 0 {
		t.Fatalf("missing marker %q", marker)
	}
	row := strings.Count(source[:offset], "\n")
	column := offset - strings.LastIndex(source[:offset], "\n") - 1
	help, err := p.FunctionHelp(file, source, row, column)
	if err != nil {
		t.Fatal(err)
	}
	return help
}

func TestFunctionHelpStaticSources(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/help\n\ngo 1.23\n")
	write(t, root, "local/local.go", `package local
// Identity returns its argument.
func Identity[T any](v T) T { return v }
type Item struct{}
// Read returns a value.
func (Item) Read() int { return 1 }
type Reader interface { Read() int }
`)
	source := `package help
import ( f "fmt"; l "example.com/help/local" )
// Entry is local.
func Entry(dynamic func(), reader l.Reader) {
 f.Println("hello")
 _ = l.Identity[int](1)
 item := l.Item{}
 _ = item.Read()
 _ = reader.Read()
 closure := func() { 日本語 := 1; _ = 日本語; f.Printf("%d", 1) }
 closure()
 dynamic()
 missing()
 _ = l.Item{}
 _ = len("x")
}
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	originalFunctions := len(p.Functions)
	for _, tc := range []struct{ marker, name, signature, docs, reference string }{
		{"Println(\"hello\")", "Println", "func fmt.Println(", "Println formats", "GOROOT/src/fmt/print.go:"},
		{"Identity[int]", "Identity", "func example.com/help/local.Identity[T any](v T) T", "Identity returns its argument.\n", "local/local.go:3"},
		{"Read()\n _ = reader", "Read", "func (example.com/help/local.Item).Read() int", "Read returns a value.\n", "local/local.go:6"},
		{"Printf(\"%d\"", "Printf", "func fmt.Printf(", "Printf formats", "GOROOT/src/fmt/print.go:"},
		{"Entry(dynamic", "Entry", "func example.com/help.Entry(", "Entry is local.\n", "entry.go:4"},
	} {
		help := functionHelpAt(t, p, "entry.go", source, tc.marker)
		if help == nil || help.Name != tc.name || !strings.HasPrefix(help.Signature, tc.signature) || !strings.HasPrefix(help.Documentation, tc.docs) || !strings.HasPrefix(help.Reference, tc.reference) {
			t.Errorf("%s: %+v", tc.marker, help)
		}
	}
	// Dynamic variables, closures, builtins, types, and unknown names have no static function declaration.
	for _, marker := range []string{"dynamic()", "closure()", "Read()\n closure", "missing()", "Item{}", "len(\"x\")"} {
		if help := functionHelpAt(t, p, "entry.go", source, marker); help != nil {
			t.Errorf("%s: %+v", marker, help)
		}
	}
	if help := functionHelpAt(t, p, "entry.go", source+"\n", "Println"); help != nil {
		t.Fatalf("stale source: %+v", help)
	}
	for _, pos := range [][2]int{{-1, 0}, {0, -1}, {100, 0}, {0, 100}} {
		help, err := p.FunctionHelp("entry.go", source, pos[0], pos[1])
		if help != nil || err != nil {
			t.Fatalf("bounds: %+v %v", help, err)
		}
	}
	if len(p.Functions) != originalFunctions {
		t.Fatal("help registered navigation functions")
	}
}

func TestFunctionHelpOfflineDependency(t *testing.T) {
	offlineTestEnv(t)
	for _, replacement := range []bool{false, true} {
		t.Run(map[bool]string{false: "cached", true: "replace"}[replacement], func(t *testing.T) {
			root, cache := t.TempDir(), t.TempDir()
			t.Setenv("GOMODCACHE", cache)
			dep := filepath.Join(cache, "example.com/dep@v1.0.0")
			mod := "module example.com/help\n\ngo 1.23\nrequire example.com/dep v1.0.0\n"
			if replacement {
				dep = t.TempDir()
				mod += "replace example.com/dep => " + filepath.ToSlash(dep) + "\n"
			}
			write(t, root, "go.mod", mod)
			write(t, dep, "go.mod", "module example.com/dep\n\ngo 1.23\n")
			write(t, dep, "dep.go", "package dep\n// Work performs work.\n//line imaginary.go:900\nfunc Work() {}\n")
			write(t, dep, "excluded.go", "//go:build never_help_test\n\npackage dep\nfunc Work() {}\n")
			if !replacement {
				write(t, cache, "cache/download/example.com/dep/@v/v1.0.0.mod", "module example.com/dep\n\ngo 1.23\n")
				hash := "h1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
				write(t, cache, "cache/download/example.com/dep/@v/v1.0.0.ziphash", hash)
				modHash := sha256.Sum256([]byte(fmt.Sprintf("%x  go.mod\n", sha256.Sum256([]byte("module example.com/dep\n\ngo 1.23\n")))))
				write(t, root, "go.sum", "example.com/dep v1.0.0 "+hash+"\nexample.com/dep v1.0.0/go.mod h1:"+base64.StdEncoding.EncodeToString(modHash[:])+"\n")
			}
			source := "package help\nimport alias \"example.com/dep\"\nfunc Entry() { alias.Work() }\n"
			write(t, root, "entry.go", source)
			p, err := Load(root)
			if err != nil {
				t.Fatal(err)
			}
			help := functionHelpAt(t, p, "entry.go", source, "Work()")
			if help == nil || help.Origin != "dependency" || help.Name != "Work" || help.Signature != "func example.com/dep.Work()" || help.Documentation != "Work performs work.\n" || !strings.HasSuffix(help.Reference, "/dep.go:4") || !strings.HasPrefix(help.Reference, "example.com/dep@v1.0.0") {
				t.Fatalf("dependency help: %+v", help)
			}
			if replacement && !strings.Contains(help.Reference, "[replace => ") {
				t.Fatal(help.Reference)
			}
			// Repeated help uses the parsed snapshot, not changed dependency source.
			if err := os.WriteFile(filepath.Join(dep, "dep.go"), []byte("package dep\n"), 0600); err != nil {
				t.Fatal(err)
			}
			again := functionHelpAt(t, p, "entry.go", source, "Work()")
			if again == nil || *again != *help {
				t.Fatalf("cached help: %+v", again)
			}
			if err := p.EnsureFunction("example.com/dep.Work"); err == nil {
				t.Fatal("dependency became navigation target")
			}
		})
	}
}

func TestFunctionHelpUnresolvedImportAndNoDocumentation(t *testing.T) {
	offlineTestEnv(t)
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/help\n\ngo 1.23\nrequire example.com/missing v1.0.0\n")
	source := `package help
import "example.com/missing"
func Local() {}
func Entry() { missing.Unknown(); Local() }
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	if help := functionHelpAt(t, p, "entry.go", source, "Unknown()"); help != nil {
		t.Fatalf("missing dependency: %+v", help)
	}
	help := functionHelpAt(t, p, "entry.go", source, "Local() }")
	if help == nil || help.Documentation != "" || help.Reference != "entry.go:3" {
		t.Fatalf("undocumented local function: %+v", help)
	}
	for _, file := range []string{"../entry.go", filepath.Join(root, "entry.go")} {
		if _, err := p.FunctionHelp(file, source, 3, 28); err == nil {
			t.Fatalf("accepted nonlocal path: %s", file)
		}
	}
}
