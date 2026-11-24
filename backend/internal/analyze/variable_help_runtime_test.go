package analyze

import "testing"

func TestVariableHelpRuntimeNameAmbiguity(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	source := `package vars
var captured int
func Entry(param int) (named int) {
 _ = captured
 { captured := 1; _ = captured }
 clean := 2
 _ = func(param int) { _ = param }
 _ = param
 _ = clean
 return
}
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		marker string
		safe   bool
	}{
		{"captured :=", false},
		{"param\n _ = clean", false},
		{"param int) {", false},
		{"clean\n return", true},
		{"named int", true},
	} {
		h := variableHelpAt(t, p, source, tc.marker)
		if h == nil || h.RuntimeSafe != tc.safe {
			t.Errorf("%s: %+v", tc.marker, h)
		}
	}
}

func TestVariableHelpDirectWritesOnly(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	source := `package vars
func Entry() {
 value := 0
 ptr := &value
 *ptr = 2
 values := []int{value}
 values[0] = 3
 type Item struct { Field int }
 var item Item
 item.Field = value
 item.Field++
 _ = values; _ = ptr; _ = item.Field
}
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		marker string
		writes int
	}{{"value :=", 0}, {"ptr :=", 0}, {"values :=", 0}, {"item Item", 0}, {"Field\n}", 2}} {
		h := variableHelpAt(t, p, source, tc.marker)
		if h == nil || len(h.Updates) != tc.writes {
			t.Errorf("%s: %+v", tc.marker, h)
		}
	}
}
