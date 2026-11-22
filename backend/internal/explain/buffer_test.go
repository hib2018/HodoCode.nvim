package explain

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrepareBufferWholeSource(t *testing.T) {
	for _, tt := range []struct{ file, source string }{
		{"new.go", "// COMMENT_SECRET\r\npackage p\nvar value = `LITERAL_SECRET\n秘密`\n" + strings.Repeat("func next() {}\n", 20)},
		{"new.py", "# COMMENT_SECRET\r\nvalue = 'LITERAL_SECRET秘密'\ndef next():\n    return value\n"},
		{"new.js", "// COMMENT_SECRET\r\nconst value = 'LITERAL_SECRET秘密';\nfunction next() { return value; }\n"},
		{"new.rs", "/* COMMENT_SECRET */\nconst VALUE: &str = r#\"LITERAL_SECRET秘密\"#;\nfn next() {}\n"},
		{"new.c", "/* COMMENT_SECRET */\nchar *value = \"LITERAL_SECRET秘密\";\nint next(void) { return 0; }\n"},
		{"new.zig", "// COMMENT_SECRET\nconst value = \"LITERAL_SECRET秘密\";\nfn next() void {}\n"},
		{"new.ts", "// COMMENT_SECRET\nconst value: string = 'LITERAL_SECRET秘密';\nfunction next() {}\n"},
	} {
		t.Run(tt.file, func(t *testing.T) {
			root := t.TempDir() // Intentionally no go.mod, files, LSP or project analysis.
			b, err := PrepareBuffer(root, "unsaved/"+tt.file, tt.source, "explain", nil)
			if err != nil {
				t.Fatal(err)
			}
			if len(b.Content) != len(tt.source) || strings.Contains(b.Content, "SECRET") || strings.Contains(b.Content, "秘密") || !strings.Contains(b.Content, "next") {
				t.Fatalf("incorrect whole-source mask: %q", b.Content)
			}
			for i := range tt.source {
				if tt.source[i] == '\n' || tt.source[i] == '\r' {
					if b.Content[i] != tt.source[i] {
						t.Fatalf("newline moved at %d", i)
					}
				}
			}
			if b.Version != fmt.Sprintf("%x", sha256.Sum256([]byte(tt.source))) || b.LineCount != strings.Count(tt.source, "\n")+1 || b.File != "unsaved/"+tt.file || b.Purpose != "explain" || b.Language == "" {
				t.Fatalf("wrong metadata: %+v", b)
			}
		})
	}
}

func TestPrepareBufferRejects(t *testing.T) {
	root := t.TempDir()
	for _, tt := range []struct {
		name, file, content, purpose string
		excludes                     []string
	}{
		{name: "absolute", file: "/tmp/a.go"}, {name: "traversal", file: "../a.go"}, {name: "clean traversal", file: "x/../a.go"},
		{name: "Windows", file: "C:/a.go"}, {name: "backslash", file: `x\a.go`}, {name: "secret", file: "secrets/a.go"},
		{name: "unsupported", file: "a.txt"}, {name: "exclude", file: "src/a.go", excludes: []string{"src"}},
		{name: "invalid pattern", file: "a.go", excludes: []string{"["}}, {name: "unsafe pattern", file: "a.go", excludes: []string{"../x"}},
		{name: "NUL", file: "a.go", content: "\x00"}, {name: "UTF8", file: "a.go", content: string([]byte{255})},
		{name: "source size", file: "a.go", content: strings.Repeat(" ", maxPrompt+1)},
		{name: "encoded size", file: "a.go", content: strings.Repeat("\n", maxPrompt/2)},
		{name: "purpose size", file: "a.go", purpose: strings.Repeat("x", maxPurpose+1)},
		{name: "Go unterminated", file: "a.go", content: "package p; var x = `SECRET"},
		{name: "JS ambiguous", file: "a.js", content: "const x = `SECRET${value}`"},
		{name: "Python ambiguous", file: "a.py", content: "x = f'SECRET{value}'"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			purpose := tt.purpose
			if purpose == "" {
				purpose = "explain"
			}
			if b, err := PrepareBuffer(root, tt.file, tt.content, purpose, tt.excludes); err == nil || b != nil {
				t.Fatalf("accepted unsafe input: %+v %v", b, err)
			}
		})
	}
	for _, purpose := range []string{"", "  ", "\x00", string([]byte{255})} {
		if _, err := PrepareBuffer(root, "a.go", "", purpose, nil); err == nil {
			t.Fatal("accepted invalid purpose")
		}
	}
}

func TestPrepareBufferSymlinksAndPaths(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(outside, "a.go"), []byte("package p"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct{ name, target string }{{"escape", outside}, {"inside", root}, {"alias.go", filepath.Join(outside, "a.go")}, {"mismatch.py", filepath.Join(outside, "a.go")}, {"broken.go", filepath.Join(root, "absent.go")}} {
		if err := os.Symlink(tt.target, filepath.Join(root, tt.name)); err != nil {
			t.Fatal(err)
		}
		file := tt.name
		if !strings.Contains(file, ".") {
			file += "/new.go"
		}
		if _, err := PrepareBuffer(root, file, "package p", "explain", nil); err == nil {
			t.Fatalf("accepted symlink %s", file)
		}
	}
	if err := os.Mkdir(filepath.Join(root, "dir.go"), 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := PrepareBuffer(root, "dir.go", "", "explain", nil); err == nil {
		t.Fatal("accepted directory")
	}
	if _, err := PrepareBuffer(filepath.Join(root, "absent"), "a.go", "", "explain", nil); err == nil {
		t.Fatal("accepted absent root")
	}
}
