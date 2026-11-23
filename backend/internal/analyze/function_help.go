package analyze

import (
	"fmt"
	"go/ast"
	"go/build"
	"go/types"
	"path/filepath"
	"strings"
)

// FunctionHelp describes a static function declaration, never a runtime target.
// Documentation is the declaration's raw Doc.Text; Reference uses a physical line.
type FunctionHelp struct {
	Name          string
	Signature     string
	Documentation string
	Reference     string
}

// FunctionHelp resolves a Go function identifier at a zero-based physical row and
// UTF-8 byte column. Unsupported, stale, and unresolved source returns nil help.
func (p *Project) FunctionHelp(file, source string, row, column int) (*FunctionHelp, error) {
	if file == "" || filepath.IsAbs(file) || !filepath.IsLocal(file) {
		return nil, fmt.Errorf("file must be project-relative")
	}
	filename, err := filepath.Abs(filepath.Join(p.Root, file))
	if err != nil {
		return nil, err
	}
	snapshot, ok := p.sources[filename]
	if !ok || source != string(snapshot) || polyExtension(filename) != "go" || row < 0 || column < 0 {
		return nil, nil
	}
	offset := 0
	for i := 0; i < row; i++ {
		end := strings.IndexByte(source[offset:], '\n')
		if end < 0 {
			return nil, nil
		}
		offset += end + 1
	}
	end := strings.IndexByte(source[offset:], '\n')
	if end < 0 {
		end = len(source) - offset
	}
	if column >= end {
		return nil, nil
	}
	offset += column
	var selected *ast.FuncDecl
	var id string
	for candidate, fn := range p.declarations {
		if !p.LocalFunction(candidate) {
			continue
		}
		start := p.fset.PositionFor(fn.Pos(), false)
		finish := p.fset.PositionFor(fn.End(), false)
		if start.Filename == filename && start.Offset <= offset && offset < finish.Offset && (selected == nil || fn.End()-fn.Pos() < selected.End()-selected.Pos()) {
			selected, id = fn, candidate
		}
	}
	if selected == nil {
		return nil, nil
	}
	var ident *ast.Ident
	ast.Inspect(selected, func(node ast.Node) bool {
		name, ok := node.(*ast.Ident)
		if ok {
			start := p.fset.PositionFor(name.Pos(), false).Offset
			if start <= offset && offset < start+len(name.Name) {
				ident = name
			}
		}
		return true
	})
	if ident == nil {
		return nil, nil
	}
	info := &types.Info{Uses: map[*ast.Ident]types.Object{}, Defs: map[*ast.Ident]types.Object{}}
	loader := p.newImporter(id, true)
	config := types.Config{Importer: loader, Sizes: types.SizesFor(build.Default.Compiler, build.Default.GOARCH), Error: func(error) {}}
	_, _ = config.Check(p.owners[id], p.fset, p.definitionTypeFiles(p.owners[id], selected), info)
	object := info.Uses[ident]
	if object == nil {
		object = info.Defs[ident]
	}
	fn, ok := object.(*types.Func)
	if !ok {
		return nil, nil
	}
	nodes := p.definitionNodes()
	for _, files := range loader.files {
		addDefinitionNodes(nodes, files)
	}
	// Instantiated generic methods retain their original declaration position.
	declaration, ok := nodes[fn.Pos()].(*ast.FuncDecl)
	if !ok {
		return nil, nil
	}
	pos := p.fset.PositionFor(declaration.Pos(), false)
	label := loader.labels[pos.Filename]
	if label == "" {
		label = p.sourceName(pos.Filename)
	}
	return &FunctionHelp{Name: fn.Name(), Signature: types.ObjectString(fn, nil), Documentation: declaration.Doc.Text(), Reference: fmt.Sprintf("%s:%d", label, pos.Line)}, nil
}
