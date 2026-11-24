package analyze

import "testing"

func TestVariableHelpInvalidInitialConstant(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	source := `package vars
func Entry() {
 var invalid int = 1.2
 var overflow int8 = 300
 const broken int = 1.2
 valid := 1 + 2
 const folded = 2 + 3
 unused := 7
 var (
  groupedInvalid int8 = 300
  groupedValid = 2 + 4
 )
 _ = groupedInvalid; _ = groupedValid
 _ = invalid; _ = overflow; _ = valid; _ = folded; _ = broken
}
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, marker := range []string{"invalid;", "overflow;", "broken\n}", "groupedInvalid;"} {
		h := variableHelpAt(t, p, source, marker)
		if h != nil && (h.InitialKind == "constant" || h.InitialValue != "" || h.RuntimeSafe) {
			t.Errorf("invalid initializer %s claims value: %+v", marker, h)
		}
	}
	for _, tc := range []struct{ marker, value string }{{"valid :=", "3"}, {"folded;", "5"}, {"unused :=", "7"}, {"groupedValid\n", "6"}} {
		h := variableHelpAt(t, p, source, tc.marker)
		if h == nil || h.InitialKind != "constant" || h.InitialValue != tc.value {
			t.Errorf("valid initializer %s: %+v", tc.marker, h)
		}
	}
}
