package analyze

import (
	"strings"
	"testing"
)

func TestFunctionRange(t *testing.T) {
	for _, tt := range []struct {
		name, language, source string
		row, start, end        int
	}{
		{"Go declaration", "go", "package p\nfunc first() {}\n\nfunc second(\n n int,\n) {\n _ = n\n}\n", 5, 4, 8},
		{"Go method", "go", "package p\ntype T int\nfunc (\n t T,\n) Method() {\n}\n", 3, 3, 6},
		{"Go nested literal", "go", "package p\nfunc outer() {\n f := func(\n ) {\n  println(\"日本語\")\n }\n f()\n}\n", 5, 3, 6},
		{"Go outer", "go", "package p\nfunc outer() {\n f := func() {}\n f()\n}\n", 4, 2, 5},
		{"Go raw string", "go", "package p\n// func fake() {}\nvar s = `func fake() {\n}`\nfunc real() {\n println(\"} // 日本語\")\n}\n", 6, 5, 7},
		{"Go physical lines", "go", "package p\n//line other.go:500\nfunc real() {\n}\n", 3, 3, 4},
		{"JS arrow nested", "javascript", "function outer() {\n const inner = (\n x\n ) => {\n return x;\n };\n}\n", 5, 2, 6},
		{"JS comments strings", "javascript", "// function fake() {}\nconst s = 'function fake() {}';\nfunction real(\n x\n) {\n return '}';\n}\n", 4, 3, 7},
		{"Python nested", "python", "def outer():\n    def inner(\n        x\n    ):\n        return x\n    return inner(1)\n", 5, 2, 5},
		{"Rust", "rust", "fn first() {}\nfn second(\n n: i32\n) {\n}\n", 3, 2, 5},
		{"C", "c", "int first() {}\nint second(\n int n\n) {\n}\n", 3, 2, 5},
		{"Zig", "zig", "fn first() void {}\nfn second(\n n: i32\n) void {\n}\n", 3, 2, 5},
		{"TypeScript", "typescript", "const f = (\n x: number\n): number => {\n return x;\n};\n", 3, 1, 5},
	} {
		t.Run(tt.name, func(t *testing.T) {
			start, end, err := FunctionRange(tt.language, tt.source, tt.row)
			if err != nil || start != tt.start || end != tt.end {
				t.Fatalf("got %d:%d, %v; want %d:%d", start, end, err, tt.start, tt.end)
			}
		})
	}
}

func TestFunctionRangeNoFunction(t *testing.T) {
	source := "package p\n// func fake() {}\nvar s = `func fake() {}`\nfunc real() {}\n"
	for _, row := range []int{-1, 0, 1, 2, 3, 5, 6} {
		if _, _, err := FunctionRange("go", source, row); err == nil || !strings.Contains(err.Error(), "no function at cursor") {
			t.Fatalf("row %d: %v", row, err)
		}
	}
	if _, _, err := FunctionRange("javascript", "const s = 'function fake() {}';", 1); err == nil || !strings.Contains(err.Error(), "no function at cursor") {
		t.Fatalf("string mistaken for function: %v", err)
	}
}
