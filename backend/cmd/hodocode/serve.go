package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/hib2018/HodoCode/internal/analyze"
)

const maxServeMessage = 1 << 20

type serveRequest struct {
	ID     *int   `json:"id"`
	Method string `json:"method"`
	Params struct {
		Function string   `json:"function"`
		File     string   `json:"file"`
		Row      int      `json:"row"`
		Column   int      `json:"column"`
		Kind     string   `json:"kind"`
		Dir      string   `json:"dir"`
		Depth    *int     `json:"depth"`
		Expand   []string `json:"expand"`
	} `json:"params"`
}

type serveResponse struct {
	ID     int    `json:"id"`
	Result any    `json:"result"`
	Error  string `json:"error,omitempty"`
}

type serveCalls struct {
	Function analyze.Function            `json:"function"`
	Calls    []analyze.CallSite          `json:"calls"`
	Targets  map[string]analyze.Function `json:"Targets"`
}

type serveGraphNode struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

type serveGraphEdge struct {
	From    string `json:"from"`
	To      string `json:"to"`
	Unknown bool   `json:"unknown,omitempty"`
}

type serveGraphResult struct {
	Kind    string           `json:"kind"`
	Nodes   []serveGraphNode `json:"nodes"`
	Edges   []serveGraphEdge `json:"edges"`
	Mermaid string           `json:"mermaid"`
}

type serveSyntax struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	Syntax      string `json:"syntax"`
	Example     string `json:"example"`
	Caution     string `json:"caution"`
	Reference   string `json:"reference"`
}

func runServe(ctx context.Context, args []string, in io.Reader, out, stderr io.Writer) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	root := fs.String("root", ".", "local project root (saved source only)")
	language := fs.String("language", "auto", "source language, or auto")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(fs.Args(), " "))
	}
	p, err := analyze.LoadLanguageContext(ctx, *root, *language)
	if err != nil {
		return err
	}
	// Pin the canonical root so reload cannot follow a replaced root symlink.
	*root = p.Root
	scan := bufio.NewScanner(in)
	scan.Buffer(make([]byte, 4096), maxServeMessage+1)
	encode := json.NewEncoder(out)
	// Project caches are mutable: dispatch and all Functions reads stay sequential.
	for scan.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		var req serveRequest
		response := serveResponse{}
		err := json.Unmarshal(scan.Bytes(), &req)
		if req.ID != nil {
			response.ID = *req.ID
		}
		if err == nil && req.ID == nil {
			err = fmt.Errorf("id must be an integer")
		}
		if err == nil {
			response.Result, err = serveDispatch(ctx, &p, *root, *language, req)
		}
		if err != nil {
			response.Error = err.Error()
		}
		if err := encode.Encode(response); err != nil {
			return err
		}
	}
	if err := scan.Err(); err != nil {
		// Oversized messages terminate the stream without retaining unbounded input.
		if writeErr := encode.Encode(serveResponse{Error: "read request: " + err.Error()}); writeErr != nil {
			return writeErr
		}
		return err
	}
	return nil
}

func serveDispatch(ctx context.Context, project **analyze.Project, root, language string, req serveRequest) (any, error) {
	p := *project
	switch req.Method {
	case "functions":
		functions := make([]analyze.Function, 0, len(p.Functions))
		for _, id := range functionIDs(p) {
			functions = append(functions, p.Functions[id])
		}
		return functions, nil
	case "function-names":
		return p.FunctionNames(req.Params.File)
	case "calls":
		if req.Params.Function == "" {
			return nil, fmt.Errorf("function is required")
		}
		id, err := p.Resolve(req.Params.Function)
		if err != nil {
			return nil, err
		}
		calls, err := p.CallSites(id)
		if err != nil {
			return nil, err
		}
		if calls == nil {
			calls = []analyze.CallSite{}
		}
		result := serveCalls{Function: p.Functions[id], Calls: calls, Targets: map[string]analyze.Function{}}
		for _, call := range calls {
			for _, target := range append([]string{call.To}, call.Candidates...) {
				if f, ok := p.Functions[target]; ok && p.LocalFunction(target) {
					result.Targets[target] = f
				}
			}
		}
		return result, nil
	case "graph":
		result, err := serveGraph(p, req)
		if err != nil {
			return nil, err
		}
		return result, nil
	case "syntax":
		return serveSyntaxAt(root, req.Params.File, req.Params.Row, req.Params.Column)
	case "reload":
		next, err := analyze.LoadLanguageContext(ctx, root, language)
		if err != nil {
			return nil, err
		}
		*project = next
		return map[string]bool{"reloaded": true}, nil
	default:
		return nil, fmt.Errorf("unknown method %q", req.Method)
	}
}

func serveGraph(p *analyze.Project, req serveRequest) (serveGraphResult, error) {
	result := serveGraphResult{Kind: req.Params.Kind, Nodes: []serveGraphNode{}, Edges: []serveGraphEdge{}}
	var edges []analyze.Edge
	nodes := map[string]bool{}
	switch req.Params.Kind {
	case "deps":
		depth := -1
		if req.Params.Depth != nil {
			depth = *req.Params.Depth
		}
		var err error
		edges, err = p.Dependencies(req.Params.Dir, depth)
		if err != nil {
			return serveGraphResult{}, err
		}
		result.Mermaid = analyze.Mermaid(edges)
	case "calls":
		if req.Params.Function == "" {
			return serveGraphResult{}, fmt.Errorf("function is required")
		}
		s, err := newFlow(p, req.Params.Function, req.Params.Expand)
		if err != nil {
			return serveGraphResult{}, err
		}
		edges, nodes = s.edges, s.nodes
		result.Mermaid = s.diagram()
	default:
		return serveGraphResult{}, fmt.Errorf("kind must be deps or calls")
	}
	for _, edge := range edges {
		nodes[edge.From], nodes[edge.To] = true, true
		result.Edges = append(result.Edges, serveGraphEdge{From: edge.From, To: edge.To, Unknown: edge.Unknown})
	}
	ids := make([]string, 0, len(nodes))
	for id := range nodes {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		result.Nodes = append(result.Nodes, serveGraphNode{ID: id, Label: id})
	}
	return result, nil
}

func serveSyntaxAt(root, file string, row, column int) (any, error) {
	if file == "" || filepath.IsAbs(file) || !filepath.IsLocal(file) {
		return nil, fmt.Errorf("file must be project-relative")
	}
	filename, err := filepath.EvalSymlinks(filepath.Join(root, file))
	if err != nil {
		return nil, err
	}
	rel, err := filepath.Rel(root, filename)
	if err != nil || !filepath.IsLocal(rel) {
		return nil, fmt.Errorf("file escapes project root")
	}
	language := analyze.FileLanguage(file)
	if language == "" {
		return nil, fmt.Errorf("unsupported source file %q", file)
	}
	info, err := os.Stat(filename)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("file must be a regular source file")
	}
	source, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(source), "\n")
	if row < 0 || row >= len(lines) || column < 0 || column > len(lines[row]) {
		return nil, fmt.Errorf("position is outside source")
	}
	if !utf8.Valid(source) || column < len(lines[row]) && !utf8.RuneStart(lines[row][column]) {
		return nil, fmt.Errorf("position must be on a UTF-8 byte boundary")
	}
	runeColumn := utf8.RuneCountInString(lines[row][:column])
	for _, note := range languageExplanations(language, string(source)) {
		if row < note.row || row > note.endRow || row == note.row && runeColumn < note.column || row == note.endRow && runeColumn >= note.endColumn {
			continue
		}
		help := note.help()
		return serveSyntax{help.title, help.description, help.syntax, help.example, help.caution, help.reference}, nil
	}
	return nil, fmt.Errorf("no syntax at position")
}
