package analyze

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func variableHelpAt(t *testing.T, p *Project, source, marker string) *VariableHelp {
	t.Helper()
	offset := strings.Index(source, marker)
	if offset < 0 {
		t.Fatalf("missing marker %q", marker)
	}
	row := strings.Count(source[:offset], "\n")
	column := offset - strings.LastIndex(source[:offset], "\n") - 1
	help, err := p.VariableHelp("entry.go", source, row, column)
	if err != nil {
		t.Fatal(err)
	}
	return help
}

func TestVariableHelpInitialValues(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	source := `package vars
const (
 First = iota + 10
 Second
)
var Global int
type Item struct { Field int }
func Pair() (int, string) { return 1, "x" }
func Entry(param int) (result int) {
 var zero int
 var flag bool
 var pointer *int
 var text string
 var composite Item
 inferred := 1234567890123
 explicit := First + 2
 left, right := 1, "two"
 tuple, other := Pair()
 var variable = inferred
 var holder Item
 // 日本語
 _ = zero; _ = flag; _ = pointer; _ = text; _ = composite
 _ = inferred; _ = explicit; _ = left; _ = right
 _ = tuple; _ = other; _ = variable; _ = holder.Field
 _ = param; _ = result; _ = Global; _ = Second
 return
}
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	count := len(p.Functions)
	for _, tc := range []struct {
		marker, typ, kind, initial, value, expr string
		safe                                    bool
	}{
		{"zero;", "int", "ローカル変数", "zero", "zero", "", true},
		{"flag;", "bool", "ローカル変数", "zero", "zero", "", true},
		{"pointer;", "*int", "ローカル変数", "zero", "zero", "", true},
		{"text;", "string", "ローカル変数", "zero", "zero", "", true},
		{"composite\n", "example.com/vars.Item", "ローカル変数", "zero", "zero", "", true},
		{"inferred;", "int", "ローカル変数", "constant", "1234567890123", "1234567890123", true},
		{"explicit;", "int", "ローカル変数", "constant", "12", "First + 2", true},
		{"left;", "int", "ローカル変数", "constant", "1", "1", true},
		{"right\n", "string", "ローカル変数", "constant", `"two"`, `"two"`, true},
		{"tuple;", "int", "ローカル変数", "expression", "", "Pair()", true},
		{"other;", "string", "ローカル変数", "expression", "", "Pair()", true},
		{"variable;", "int", "ローカル変数", "expression", "", "inferred", true},
		{"Field\n", "int", "フィールド", "unknown", "", "", false},
		{"param;", "int", "パラメータ", "unknown", "", "", true},
		{"result;", "int", "戻り値", "unknown", "", "", true},
		{"Global;", "int", "パッケージ変数", "zero", "zero", "", false},
		{"Second\n return", "untyped int", "定数", "constant", "11", "", false},
	} {
		h := variableHelpAt(t, p, source, tc.marker)
		if h == nil {
			t.Errorf("%s: nil", tc.marker)
			continue
		}
		if h.Type != tc.typ || h.Kind != tc.kind || h.InitialKind != tc.initial || h.InitialValue != tc.value || h.Initializer != tc.expr || h.RuntimeSafe != tc.safe {
			t.Errorf("%s: %+v", tc.marker, h)
		}
		if h.Declaration.File != "entry.go" || h.Declaration.Source == "" || !strings.HasPrefix(h.Reference, "entry.go:") || h.FunctionFile != "entry.go" || h.FunctionStartLine != 9 || h.FunctionEndLine != 27 {
			t.Errorf("locations %s: %+v", tc.marker, h)
		}
	}
	if h := variableHelpAt(t, p, source, "Global int"); h == nil || h.FunctionFile != "" || h.RuntimeSafe {
		t.Fatalf("package cursor: %+v", h)
	}
	if len(p.Functions) != count {
		t.Fatal("registered functions")
	}
}

func TestVariableHelpBindingReferencesAndUpdates(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	source := `package vars
func Entry(param int) {
 value := 1
 value = 2
 value += 3
 value++
 value, extra := 4, 5
 _ = extra
 _ = func() int { value--; return value }
 { value := 9; value++; _ = value }
 // 日本語 before byte columns
 日本語 := value; _ = 日本語
 _ = param
}
func Other() { value := 8; value++; _ = value }
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	h := variableHelpAt(t, p, source, "value = 2")
	if h == nil || len(h.Updates) != 5 || len(h.References) != 7 || h.RuntimeSafe {
		t.Fatalf("outer binding: %+v", h)
	}
	for i, want := range []string{"value = 2", "value += 3", "value++", "value, extra := 4, 5", "value--"} {
		if h.Updates[i].Source != want || h.Updates[i].File != "entry.go" || h.Updates[i].Column < 1 {
			t.Errorf("update %d: %+v", i, h.Updates[i])
		}
	}
	inner := variableHelpAt(t, p, source, "value := 9")
	if inner == nil || inner.InitialValue != "9" || len(inner.Updates) != 1 || len(inner.References) != 2 || inner.RuntimeSafe {
		t.Fatalf("inner binding: %+v", inner)
	}
	utf := variableHelpAt(t, p, source, "日本語\n _ = param")
	if utf == nil || utf.Name != "日本語" || !utf.RuntimeSafe || len(utf.References) != 1 {
		t.Fatalf("utf: %+v", utf)
	}
	offset := strings.Index(source, "日本語\n _ = param")
	column := offset - strings.LastIndex(source[:offset], "\n")
	if utf.References[0].Column != column {
		t.Fatalf("byte column: %+v want %d", utf.References, column)
	}
	param := variableHelpAt(t, p, source, "param\n}")
	if param == nil || !param.RuntimeSafe {
		t.Fatalf("parameter: %+v", param)
	}
}

func TestVariableHelpSnapshotFallbackAndExternal(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	write(t, root, "model/model.go", "package model\nvar Global int\nvar Initial = 4\nconst Constant = 5\n")
	source := "package vars\nimport m \"example.com/vars/model\"\nfunc Entry(){ var bad missing; _ = bad; _ = m.Global; _ = m.Initial; _ = m.Constant; unknown(); _ = len(\"x\") }\n"
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "model/model.go"), []byte("package changed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ marker, initial, expr, value string }{{"Global;", "unknown", "", ""}, {"Initial;", "expression", "4", ""}, {"Constant;", "constant", "5", "5"}} {
		h := variableHelpAt(t, p, source, tc.marker)
		if h == nil || h.InitialKind != tc.initial || h.Initializer != tc.expr || h.InitialValue != tc.value || h.RuntimeSafe || h.Declaration.File != "model/model.go" {
			t.Errorf("%s: %+v", tc.marker, h)
		}
	}
	for _, marker := range []string{"bad;", "unknown()", "len(\"x\")", "Entry()", "m.Global"} {
		if h := variableHelpAt(t, p, source, marker); h != nil {
			t.Errorf("fallback %s: %+v", marker, h)
		}
	}
	if h := variableHelpAt(t, p, source+"\n", "Global;"); h != nil {
		t.Fatalf("stale: %+v", h)
	}
	for _, pos := range [][2]int{{-1, 0}, {0, -1}, {99, 0}, {0, 999}, {0, 12}} {
		h, err := p.VariableHelp("entry.go", source, pos[0], pos[1])
		if err != nil || h != nil {
			t.Errorf("bounds %+v: %+v %v", pos, h, err)
		}
	}
	for _, file := range []string{"../entry.go", filepath.Join(root, "entry.go")} {
		if _, err := p.VariableHelp(file, source, 0, 0); err == nil {
			t.Errorf("accepted %s", file)
		}
	}
}
