package analyze

import (
	"fmt"
	"go/ast"
	"go/build"
	"go/types"
	"path/filepath"
	"sort"

	"github.com/hib2018/HodoCode/internal/sourcelex"
)

// FunctionName covers only a recognized name, in physical 1-based byte columns.
// EndColumn is exclusive. Names are sorted by source position, without duplicates.
type FunctionName struct {
	Line, Column, EndColumn int
}

// FunctionNames recognizes declarations, named calls (including unresolved calls),
// and identifiable Go function references in an indexed local file's saved snapshot.
// It never loads source or type information from the filesystem.
func (p *Project) FunctionNames(file string) ([]FunctionName, error) {
	if file == "" || filepath.IsAbs(file) || !filepath.IsLocal(file) {
		return nil, fmt.Errorf("file must be project-relative")
	}
	file, err := filepath.Abs(filepath.Join(p.Root, file))
	if err != nil {
		return nil, err
	}
	rel, err := filepath.Rel(p.Root, file)
	if err != nil || escapes(rel) {
		return nil, fmt.Errorf("file escapes project root")
	}
	source, ok := p.sources[file]
	if !ok {
		return nil, fmt.Errorf("file is not an indexed local snapshot: %s", rel)
	}
	names := map[int]int{}
	if polyExtension(file) == "go" {
		p.goFunctionNames(file, names)
	} else {
		language := polyExtension(file)
		tokens, err := sourcelex.Scan(language, string(source))
		if err != nil {
			return nil, err
		}
		filtered := tokens[:0]
		for _, token := range tokens {
			if token.Kind != "comment" {
				filtered = append(filtered, token)
			}
		}
		tokens = filtered
		for _, fn := range p.polyglot {
			if fn.file != file {
				continue
			}
			for i, token := range fn.tokens {
				if token.Start >= fn.start && i < fn.body && token.Kind == "identifier" && token.Text == fn.name {
					names[token.Start] = token.End
					break
				}
			}
		}
		// shortcut: lexical named calls only; use language-specific parsers for generic,
		// computed callees, non-call references, or constructor/type distinctions.
		for i, token := range tokens {
			if token.Kind != "identifier" || polyControl(token.Text) || language == "c" && polyCType(token.Text) {
				continue
			}
			if i > 0 && (tokens[i-1].Text == "@" || tokens[i-1].Text == "#") {
				continue
			}
			if i+1 < len(tokens) && tokens[i+1].Text == "(" {
				names[token.Start] = token.End
			}
		}
	}
	offsets := make([]int, 0, len(names))
	for offset := range names {
		offsets = append(offsets, offset)
	}
	sort.Ints(offsets)
	result := make([]FunctionName, 0, len(offsets))
	line, lineStart, scanned := 1, 0, 0
	for _, offset := range offsets {
		for ; scanned < offset; scanned++ {
			if source[scanned] == '\n' {
				line++
				lineStart = scanned + 1
			}
		}
		result = append(result, FunctionName{Line: line, Column: offset - lineStart + 1, EndColumn: names[offset] - lineStart + 1})
	}
	return result, nil
}

func (p *Project) goFunctionNames(filename string, names map[int]int) {
	for pkg, files := range p.packages {
		var selected *ast.File
		for _, file := range files {
			if p.fset.PositionFor(file.Pos(), false).Filename == filename {
				selected = file
				break
			}
		}
		if selected == nil {
			continue
		}
		info := &types.Info{Uses: map[*ast.Ident]types.Object{}, Types: map[ast.Expr]types.TypeAndValue{}}
		loader := &snapshotImporter{project: p, cache: map[string]*types.Package{}, loading: map[string]bool{}}
		config := types.Config{Importer: loader, Sizes: types.SizesFor(build.Default.Compiler, build.Default.GOARCH), Error: func(error) {}}
		_, _ = config.Check(pkg, p.fset, files, info)
		add := func(name *ast.Ident) {
			if name != nil && name.Name != "_" {
				pos := p.fset.PositionFor(name.Pos(), false)
				names[pos.Offset] = pos.Offset + len(name.Name)
			}
		}
		ast.Inspect(selected, func(node ast.Node) bool {
			switch node := node.(type) {
			case *ast.FuncDecl:
				add(node.Name)
			case *ast.Ident:
				object := info.Uses[node]
				if object == nil {
					break
				}
				switch object.(type) {
				case *types.Func, *types.Builtin:
					add(node)
				case *types.Var:
					if _, ok := object.Type().Underlying().(*types.Signature); ok {
						add(node)
					}
				}
			case *ast.CallExpr:
				expr := unparen(node.Fun)
				if info.Types[expr].IsType() {
					break
				}
				switch indexed := expr.(type) {
				case *ast.IndexExpr:
					expr = unparen(indexed.X)
				case *ast.IndexListExpr:
					expr = unparen(indexed.X)
				}
				var name *ast.Ident
				switch expr := expr.(type) {
				case *ast.Ident:
					name = expr
				case *ast.SelectorExpr:
					name = expr.Sel
				}
				if name != nil {
					object := info.Uses[name]
					if object == nil {
						add(name)
					} else {
						switch object.(type) {
						case *types.Func, *types.Builtin:
							add(name)
						case *types.Var:
							if _, ok := object.Type().Underlying().(*types.Signature); ok {
								add(name)
							}
						}
					}
				}
			}
			return true
		})
		return
	}
}

// Unlike navigation's importer, this importer only consumes original local ASTs.
type snapshotImporter struct {
	project *Project
	cache   map[string]*types.Package
	loading map[string]bool
}

func (i *snapshotImporter) Import(path string) (*types.Package, error) {
	if path == "unsafe" {
		return types.Unsafe, nil
	}
	if cached := i.cache[path]; cached != nil {
		return cached, nil
	}
	if i.loading[path] {
		return nil, fmt.Errorf("import cycle: %s", path)
	}
	var files []*ast.File
	for _, file := range i.project.packages[path] {
		filename := i.project.fset.PositionFor(file.Pos(), false).Filename
		rel, err := filepath.Rel(i.project.Root, filename)
		if err == nil && !escapes(rel) {
			files = append(files, file)
		}
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("type information outside local snapshot: %s", path)
	}
	i.loading[path] = true
	defer delete(i.loading, path)
	config := types.Config{Importer: i, IgnoreFuncBodies: true, Sizes: types.SizesFor(build.Default.Compiler, build.Default.GOARCH), Error: func(error) {}}
	pkg, err := config.Check(path, i.project.fset, files, nil)
	if pkg != nil {
		i.cache[path] = pkg
		return pkg, nil
	}
	return nil, err
}
