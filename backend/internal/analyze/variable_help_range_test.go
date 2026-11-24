package analyze

import "testing"

func TestVariableHelpRangeWrites(t *testing.T) {
	root := t.TempDir()
	write(t, root, "go.mod", "module example.com/vars\n\ngo 1.23\n")
	source := `package vars
func Entry(xs []int, entries map[string]int) {
 var index, value int
 var key string
 for index = range xs { _ = index }
 for key, value = range entries { _ = key; _ = value }
 _ = func() { for index, value = range xs { _ = value } }
 { index := 4; for index = range xs { _ = index } }
 for index := range xs { _ = index }
 for fresh, item := range xs { _ = fresh; _ = item }
 _ = index; _ = value
}
`
	write(t, root, "entry.go", source)
	p, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		marker  string
		updates []string
	}{
		{"index, value int", []string{"for index = range xs", "for index, value = range xs"}},
		{"value int", []string{"for key, value = range entries", "for index, value = range xs"}},
		{"key string", []string{"for key, value = range entries"}},
		{"index := 4", []string{"for index = range xs"}},
		{"index := range", nil},
		{"fresh, item :=", nil},
		{"item := range", nil},
	} {
		h := variableHelpAt(t, p, source, tc.marker)
		if h == nil || len(h.Updates) != len(tc.updates) {
			t.Errorf("%s: %+v", tc.marker, h)
			continue
		}
		for i, want := range tc.updates {
			if h.Updates[i].Source != want {
				t.Errorf("%s update %d: %+v want %q", tc.marker, i, h.Updates[i], want)
			}
		}
		if tc.marker == "fresh, item :=" || tc.marker == "item := range" || tc.marker == "index := range" {
			if h.Declaration.Source == "" || h.InitialKind != "unknown" {
				t.Errorf("range declaration %s: %+v", tc.marker, h)
			}
		}
	}
}
