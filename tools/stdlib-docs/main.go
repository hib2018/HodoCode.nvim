package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

type document struct {
	ID         string   `json:"id"`
	Text       string   `json:"text"`
	References []string `json:"references"`
}

type output struct {
	GoVersion string     `json:"go_version"`
	Documents []document `json:"documents"`
}

func receiverName(expr ast.Expr) string {
	switch expr := expr.(type) {
	case *ast.Ident:
		return expr.Name
	case *ast.StarExpr:
		return receiverName(expr.X)
	case *ast.IndexExpr:
		return receiverName(expr.X)
	case *ast.IndexListExpr:
		return receiverName(expr.X)
	case *ast.ParenExpr:
		return receiverName(expr.X)
	}
	return ""
}

func extract(root string) ([]document, error) {
	byID := make(map[string]*document)
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		name := entry.Name()
		if entry.IsDir() {
			if path != root && (strings.HasPrefix(name, ".") || name == "internal" || name == "vendor" || name == "cmd" || name == "testdata") {
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() || strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			return nil
		}
		file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ParseComments|parser.SkipObjectResolution)
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, filepath.Dir(path))
		if err != nil {
			return err
		}
		pkg := filepath.ToSlash(rel)
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || !fn.Name.IsExported() || fn.Doc == nil {
				continue
			}
			ref := pkg + "." + fn.Name.Name
			if fn.Recv != nil {
				receiver := receiverName(fn.Recv.List[0].Type)
				if !ast.IsExported(receiver) {
					continue
				}
				ref = pkg + "." + receiver + "." + fn.Name.Name
			}
			text := fn.Doc.Text()
			if text == "" {
				continue
			}
			hash := sha256.Sum256([]byte(text))
			id := hex.EncodeToString(hash[:])
			if byID[id] == nil {
				byID[id] = &document{ID: id, Text: text}
			}
			byID[id].References = append(byID[id].References, ref)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	docs := make([]document, 0, len(byID))
	for _, doc := range byID {
		sort.Strings(doc.References)
		refs := doc.References[:0]
		for _, ref := range doc.References {
			if len(refs) == 0 || refs[len(refs)-1] != ref {
				refs = append(refs, ref)
			}
		}
		doc.References = refs
		docs = append(docs, *doc)
	}
	sort.Slice(docs, func(i, j int) bool { return docs[i].ID < docs[j].ID })
	return docs, nil
}

func main() {
	docs, err := extract(filepath.Join(runtime.GOROOT(), "src"))
	if err == nil {
		err = json.NewEncoder(os.Stdout).Encode(output{runtime.Version(), docs})
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
