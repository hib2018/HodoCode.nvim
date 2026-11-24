package analyze

import (
	"fmt"
	"go/ast"
	"go/build"
	"go/constant"
	"go/token"
	"go/types"
	"path/filepath"
	"strings"
)

// VariableHelp describes a declaration and its initial value, never its current value.
type VariableHelp struct {
	Name              string
	Type              string
	Kind              string // Japanese declaration kind.
	Reference         string
	Declaration       DefinitionSource
	Initializer       string
	InitialKind       string // constant, expression, zero, or unknown.
	InitialValue      string // Exact constant value, or "zero"; never a runtime value.
	References        []VariableLocation
	Updates           []VariableLocation
	RuntimeSafe       bool
	FunctionFile      string
	FunctionStartLine int
	FunctionEndLine   int
}

// VariableLocation uses physical, one-based lines and UTF-8 byte columns.
type VariableLocation struct {
	File   string
	Line   int
	Column int
	Source string
}

// VariableHelp resolves identifiers only in the exact indexed Go snapshot.
// References and direct writes are scoped to the enclosing function, including closures.
func (p *Project) VariableHelp(file, source string, row, column int) (*VariableHelp, error) {
	if file == "" || filepath.IsAbs(file) || !filepath.IsLocal(file) {
		return nil, fmt.Errorf("file must be project-relative")
	}
	filename, err := filepath.Abs(filepath.Join(p.Root, file))
	if err != nil {
		return nil, err
	}
	snapshot, ok := p.sources[filename]
	if !ok || string(snapshot) != source || polyExtension(filename) != "go" || row < 0 || column < 0 {
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
	var id, pkg string
	var current *ast.File
	for owner, files := range p.packages {
		for _, f := range files {
			if p.fset.PositionFor(f.Pos(), false).Filename == filename {
				current, pkg = f, owner
			}
		}
	}
	if current == nil {
		return nil, nil
	}
	for candidate, fn := range p.declarations {
		if !p.LocalFunction(candidate) {
			continue
		}
		start, finish := p.fset.PositionFor(fn.Pos(), false), p.fset.PositionFor(fn.End(), false)
		if start.Filename == filename && start.Offset <= offset && offset < finish.Offset && (selected == nil || fn.End()-fn.Pos() < selected.End()-selected.Pos()) {
			selected, id = fn, candidate
		}
	}
	if id == "" {
		for candidate, owner := range p.owners {
			if owner == pkg {
				id = candidate
				break
			}
		}
	}
	var scope ast.Node = current
	if selected != nil {
		scope = selected
	}
	var ident *ast.Ident
	ast.Inspect(scope, func(node ast.Node) bool {
		if name, ok := node.(*ast.Ident); ok {
			start := p.fset.PositionFor(name.Pos(), false).Offset
			if start <= offset && offset < start+len(name.Name) {
				ident = name
			}
		}
		return true
	})
	if ident == nil || ident.Name == "_" {
		return nil, nil
	}
	info := &types.Info{Uses: map[*ast.Ident]types.Object{}, Defs: map[*ast.Ident]types.Object{}, Types: map[ast.Expr]types.TypeAndValue{}}
	loader := p.newImporter(id, true)
	var typeErrors []types.Error
	config := types.Config{Importer: loader, Sizes: types.SizesFor(build.Default.Compiler, build.Default.GOARCH), Error: func(err error) {
		if typed, ok := err.(types.Error); ok && !typed.Soft {
			typeErrors = append(typeErrors, typed)
		}
	}}
	var files []*ast.File
	if selected != nil {
		files = p.definitionTypeFiles(pkg, selected)
	} else {
		files, _ = p.typeFiles(pkg, nil)
	}
	_, _ = config.Check(pkg, p.fset, files, info)
	object := info.Uses[ident]
	if object == nil {
		object = info.Defs[ident]
	}
	switch object.(type) {
	case *types.Var, *types.Const:
	default:
		return nil, nil
	}
	if object.Type() == nil || object.Type().Underlying() == types.Typ[types.Invalid] {
		return nil, nil
	}
	nodes := p.definitionNodes()
	for _, imported := range loader.files {
		addDefinitionNodes(nodes, imported)
	}
	node := nodes[object.Pos()]
	if node == nil {
		return nil, nil
	}
	declaration := p.definitionSource(node)
	declPos := p.fset.PositionFor(object.Pos(), false)
	if label := loader.labels[declPos.Filename]; label != "" {
		declaration.File = label
	}
	help := &VariableHelp{Name: object.Name(), Type: types.TypeString(object.Type(), nil), Kind: "ローカル変数", Reference: fmt.Sprintf("%s:%d", declaration.File, declPos.Line), Declaration: declaration, InitialKind: "unknown", References: []VariableLocation{}, Updates: []VariableLocation{}}
	if c, ok := object.(*types.Const); ok {
		help.Kind = "定数"
		if c.Val().Kind() != constant.Unknown {
			help.InitialKind, help.InitialValue = "constant", c.Val().ExactString()
		}
	} else if variable := object.(*types.Var); variable.IsField() {
		help.Kind = "フィールド"
	} else if object.Pkg() != nil && object.Parent() == object.Pkg().Scope() {
		help.Kind = "パッケージ変数"
	} else if _, ok := node.(*ast.Field); ok {
		help.Kind = "パラメータ"
		for _, f := range files {
			ast.Inspect(f, func(n ast.Node) bool {
				if ft, ok := n.(*ast.FuncType); ok && ft.Results != nil && ft.Results.Pos() <= object.Pos() && object.Pos() < ft.Results.End() {
					help.Kind = "戻り値"
				}
				return true
			})
		}
	}
	// Preserve tuple expressions as source only; never invent their individual values.
	var initial ast.Expr
	initialDeclaration := node
	switch n := node.(type) {
	case *ast.GenDecl:
		for _, spec := range n.Specs {
			value, ok := spec.(*ast.ValueSpec)
			if !ok {
				continue
			}
			for i, name := range value.Names {
				if name.Pos() != object.Pos() {
					continue
				}
				initialDeclaration = value
				if len(value.Values) == len(value.Names) {
					initial = value.Values[i]
				} else if len(value.Values) == 1 {
					initial = value.Values[0]
				}
				if len(value.Values) == 0 && n.Tok == token.VAR && declPos.Filename != "" && object.Pkg() != nil && object.Pkg().Path() == pkg {
					help.InitialKind, help.InitialValue = "zero", "zero"
				}
			}
		}
	case *ast.AssignStmt:
		for i, lhs := range n.Lhs {
			if lhs.Pos() == object.Pos() {
				if len(n.Lhs) == len(n.Rhs) {
					initial = n.Rhs[i]
				} else if len(n.Rhs) == 1 {
					initial = n.Rhs[0]
				}
			}
		}
	}
	if initial != nil {
		help.Initializer = p.definitionSource(initial).Source
		if help.InitialKind != "constant" {
			help.InitialKind = "expression"
			if value := info.Types[initial].Value; value != nil && value.Kind() != constant.Unknown {
				help.InitialKind, help.InitialValue = "constant", value.ExactString()
			}
		}
	}
	invalidInitial := false
	for _, typeError := range typeErrors {
		if initialDeclaration.Pos() <= typeError.Pos && typeError.Pos < initialDeclaration.End() {
			invalidInitial = true
			help.InitialKind, help.InitialValue = "unknown", ""
			break
		}
	}
	if selected == nil {
		return help, nil
	}
	start, finish := p.fset.PositionFor(selected.Pos(), false), p.fset.PositionFor(selected.End(), false)
	help.FunctionFile, help.FunctionStartLine, help.FunctionEndLine = p.sourceName(start.Filename), start.Line, finish.Line
	help.RuntimeSafe = !invalidInitial && (help.Kind == "ローカル変数" || help.Kind == "パラメータ" || help.Kind == "戻り値") && selected.Pos() <= object.Pos() && object.Pos() < selected.End()
	ast.Inspect(selected, func(n ast.Node) bool {
		if name, ok := n.(*ast.Ident); ok && name.Name == object.Name() {
			binding := info.Uses[name]
			if binding == nil {
				binding = info.Defs[name]
			}
			if binding != nil && binding != object {
				help.RuntimeSafe = false
			}
		}
		return true
	})
	location := func(n ast.Node) VariableLocation {
		pos := p.fset.PositionFor(n.Pos(), false)
		return VariableLocation{File: p.sourceName(pos.Filename), Line: pos.Line, Column: pos.Column, Source: p.definitionSource(n).Source}
	}
	ast.Inspect(selected, func(n ast.Node) bool {
		if name, ok := n.(*ast.Ident); ok && info.Uses[name] == object {
			help.References = append(help.References, location(name))
		}
		writes := false
		direct := func(expr ast.Expr) bool {
			// Parentheses preserve the direct variable; selectors resolve their own field object.
			for {
				paren, ok := expr.(*ast.ParenExpr)
				if !ok {
					break
				}
				expr = paren.X
			}
			switch e := expr.(type) {
			case *ast.Ident:
				return info.Uses[e] == object
			case *ast.SelectorExpr:
				return info.Uses[e.Sel] == object
			}
			return false
		}
		switch statement := n.(type) {
		case *ast.AssignStmt:
			for _, lhs := range statement.Lhs {
				if direct(lhs) {
					writes = true
				}
			}
		case *ast.IncDecStmt:
			writes = direct(statement.X)
		case *ast.RangeStmt:
			writes = direct(statement.Key) || direct(statement.Value)
		}
		if writes {
			help.Updates = append(help.Updates, location(n))
		}
		return true
	})
	return help, nil
}
