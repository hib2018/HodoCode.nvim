package analyze

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"strings"

	"github.com/hib2018/HodoCode/internal/sourcelex"
)

// FunctionRange finds the smallest function containing row in supplied source.
// It returns physical, 1-based inclusive lines without loading files or projects.
func FunctionRange(language, source string, row int) (startLine, endLine int, err error) {
	missing := func() (int, int, error) {
		return 0, 0, fmt.Errorf("no function at cursor: place the cursor inside a function declaration or body")
	}
	if row < 1 || row > 1+strings.Count(source, "\n") {
		return missing()
	}
	best := len(source) + 1
	consider := func(start, end int) {
		if start < 0 || end <= start || end > len(source) {
			return
		}
		first := 1 + strings.Count(source[:start], "\n")
		last := 1 + strings.Count(source[:end-1], "\n")
		if first <= row && row <= last && end-start < best {
			startLine, endLine, best = first, last, end-start
		}
	}
	if language == "go" {
		files := token.NewFileSet()
		file, parseErr := parser.ParseFile(files, "", source, 0)
		if parseErr != nil {
			return 0, 0, fmt.Errorf("no function at cursor: fix Go syntax: %w", parseErr)
		}
		ast.Inspect(file, func(node ast.Node) bool {
			switch fn := node.(type) {
			case *ast.FuncDecl:
				if fn.Body != nil {
					consider(files.PositionFor(fn.Pos(), false).Offset, files.PositionFor(fn.End(), false).Offset)
				}
			case *ast.FuncLit:
				consider(files.PositionFor(fn.Pos(), false).Offset, files.PositionFor(fn.End(), false).Offset)
			}
			return true
		})
	} else {
		tokens, scanErr := sourcelex.Scan(language, source)
		if scanErr != nil {
			return 0, 0, fmt.Errorf("no function at cursor: %w", scanErr)
		}
		filtered := tokens[:0]
		for _, t := range tokens {
			if t.Kind != "comment" {
				filtered = append(filtered, t)
			}
		}
		for _, fn := range polyParse(language, source, filtered, polyPairs(filtered)) {
			consider(fn.start, fn.end)
		}
	}
	if startLine == 0 {
		return missing()
	}
	return startLine, endLine, nil
}
