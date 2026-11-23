package analyze

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

func TestFunctionHelpJapaneseGlossary(t *testing.T) {
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
		if err != nil || help == nil || help.Summary != japaneseStandardFunctions[key] || help.Summary == "" || help.Documentation == "" {
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
	help := functionHelpAt(t, p, "entry.go", source, "Println() }")
	if help == nil || help.Summary != "" || !strings.Contains(help.Documentation, "project function") {
		t.Fatalf("project must not receive standard-library help: %+v", help)
	}
}
