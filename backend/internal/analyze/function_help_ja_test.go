package analyze

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"
)

func TestFunctionHelpJapaneseGlossary(t *testing.T) {
	original := stdlibJapaneseCatalog.Translations
	stdlibJapaneseCatalog.Translations = nil
	t.Cleanup(func() { stdlibJapaneseCatalog.Translations = original })
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/japanesehelp\n\ngo 1.23\n")
	keys := make([]string, 0, len(japaneseStandardFunctions))
	packages := map[string]string{}
	for key := range japaneseStandardFunctions {
		keys = append(keys, key)
		path := key[:strings.LastIndexByte(key, '.')]
		packages[path] = ""
	}
	sort.Strings(keys)
	paths := make([]string, 0, len(packages))
	for path := range packages {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	var source strings.Builder
	source.WriteString("package help\nimport (\n")
	for i, path := range paths {
		packages[path] = fmt.Sprintf("p%d", i)
		fmt.Fprintf(&source, "%s %q\n", packages[path], path)
	}
	source.WriteString(")\nfunc Entry() {\n")
	markers := map[string]string{}
	for _, key := range keys {
		dot := strings.LastIndexByte(key, '.')
		marker := packages[key[:dot]] + "." + key[dot+1:]
		markers[key] = marker
		fmt.Fprintf(&source, "_ = %s\n", marker)
	}
	source.WriteString("}\n")
	text := source.String()
	write(t, root, "entry.go", text)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range keys {
		marker := markers[key]
		offset := strings.Index(text, marker) + strings.IndexByte(marker, '.') + 1
		row := strings.Count(text[:offset], "\n")
		column := offset - strings.LastIndex(text[:offset], "\n") - 1
		help, err := p.FunctionHelp("entry.go", text, row, column)
		if err != nil || help == nil || help.Summary != japaneseStandardFunctions[key] || help.Summary == "" || help.Documentation == "" || help.Origin != "standard" {
			t.Errorf("%s: %+v, %v", key, help, err)
		}
	}
}

func TestFunctionHelpJapaneseDoesNotGuessProjectNames(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module fmt\n\ngo 1.23\n")
	source := "package fmt\n// Println is a project function, not the SDK.\nfunc Println() {}\nfunc Entry() { Println() }\n"
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	original := stdlibJapaneseCatalog.Translations
	stdlibJapaneseCatalog.Translations = map[string]string{
		fmt.Sprintf("%x", sha256.Sum256([]byte("Println is a project function, not the SDK.\n"))): "SDK の説明を流用しない",
	}
	t.Cleanup(func() { stdlibJapaneseCatalog.Translations = original })
	help := functionHelpAt(t, p, "entry.go", source, "Println() }")
	if help == nil || help.Origin != "local" || help.Summary != "" || !strings.Contains(help.Documentation, "project function") {
		t.Fatalf("project must not receive standard-library help: %+v", help)
	}
}

func TestFunctionHelpJapaneseCatalogHashAndMethods(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/cataloghelp\n\ngo 1.23\n")
	source := `package help
import ("strings"; "fmt")
func Entry() { var b strings.Builder; _ = b.String(); fmt.Println("x") }
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	original := stdlibJapaneseCatalog.Translations
	t.Cleanup(func() { stdlibJapaneseCatalog.Translations = original })
	stdlibJapaneseCatalog.Translations = map[string]string{}
	for _, marker := range []string{"String()", "Println("} {
		raw := functionHelpAt(t, p, "entry.go", source, marker)
		if raw == nil || raw.Origin != "standard" || raw.Documentation == "" {
			t.Fatalf("SDK declaration: %+v", raw)
		}
		if marker == "String()" && raw.Summary != "" {
			t.Fatalf("method used free-function glossary: %+v", raw)
		}
		key := fmt.Sprintf("%x", sha256.Sum256([]byte(raw.Documentation)))
		// Hashing a trimmed comment must not match Doc.Text's trailing newline.
		stdlibJapaneseCatalog.Translations[fmt.Sprintf("%x", sha256.Sum256([]byte(strings.TrimSpace(raw.Documentation))))] = "誤った翻訳"
		miss := functionHelpAt(t, p, "entry.go", source, marker)
		if miss.Summary == "誤った翻訳" {
			t.Fatal("catalog normalized raw documentation")
		}
		stdlibJapaneseCatalog.Translations[key] = "カタログの日本語説明"
		translated := functionHelpAt(t, p, "entry.go", source, marker)
		if translated.Summary != "カタログの日本語説明" || translated.Documentation != raw.Documentation {
			t.Fatalf("catalog lookup: %+v", translated)
		}
	}
}

func TestEmbeddedJapaneseCatalogFormat(t *testing.T) {
	var catalog struct {
		GoVersion    string            `json:"go_version"`
		Translations map[string]string `json:"translations"`
	}
	if err := json.Unmarshal(stdlibJapaneseJSON, &catalog); err != nil {
		t.Fatal(err)
	}
	if catalog.GoVersion != "go1.27.4" || len(catalog.Translations) != 5717 {
		t.Fatalf("incomplete catalog: SDK %s, %d/5717 translations", catalog.GoVersion, len(catalog.Translations))
	}
	for hash, translation := range catalog.Translations {
		if len(hash) != 64 || strings.Trim(hash, "0123456789abcdef") != "" || strings.TrimSpace(translation) == "" {
			t.Fatalf("invalid catalog entry: %q", hash)
		}
	}
}
