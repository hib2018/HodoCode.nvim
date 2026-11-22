package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/hib2018/HodoCode/internal/analyze"
)

func graphRequest(t *testing.T, p *analyze.Project, params string) (serveGraphResult, error) {
	t.Helper()
	var req serveRequest
	if err := json.Unmarshal([]byte(`{"method":"graph","params":`+params+`}`), &req); err != nil {
		t.Fatal(err)
	}
	result, err := serveDispatch(context.Background(), &p, p.Root, "auto", req)
	if err != nil {
		if result != nil {
			t.Fatalf("error returned non-nil result: %+v", result)
		}
		return serveGraphResult{}, err
	}
	return result.(serveGraphResult), nil
}

func TestServeGraphDependencies(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "child"), 0700); err != nil {
		t.Fatal(err)
	}
	p := &analyze.Project{Root: root, Imports: []analyze.Edge{
		{From: "child/child.go", To: "strings"},
		{From: "main.go", To: "fmt"},
	}}
	for _, tc := range []struct {
		params string
		edges  []analyze.Edge
	}{
		{`{"kind":"deps"}`, p.Imports},
		{`{"kind":"deps","dir":".","depth":-1}`, p.Imports},
		{`{"kind":"deps","depth":0}`, p.Imports[1:]},
		{`{"kind":"deps","dir":"child","depth":0}`, p.Imports[:1]},
	} {
		t.Run(tc.params, func(t *testing.T) {
			got, err := graphRequest(t, p, tc.params)
			if err != nil {
				t.Fatal(err)
			}
			if got.Kind != "deps" || got.Mermaid != analyze.Mermaid(tc.edges) || len(got.Edges) != len(tc.edges) || len(got.Nodes) != 2*len(tc.edges) {
				t.Fatalf("graph: %+v", got)
			}
			for i, edge := range tc.edges {
				if got.Edges[i] != (serveGraphEdge{From: edge.From, To: edge.To}) {
					t.Fatalf("edges: %+v", got.Edges)
				}
			}
			for i, node := range got.Nodes {
				if node.ID != node.Label || i > 0 && got.Nodes[i-1].ID >= node.ID {
					t.Fatalf("nodes not sorted with original labels: %+v", got.Nodes)
				}
			}
		})
	}
	for _, params := range []string{
		`{}`, `{"kind":"flow"}`, `{"kind":"deps","depth":-2}`,
		`{"kind":"deps","dir":".."}`, `{"kind":"deps","dir":"missing"}`,
	} {
		if _, err := graphRequest(t, p, params); err == nil {
			t.Errorf("accepted invalid params: %s", params)
		}
	}
}

func TestServeGraphCalls(t *testing.T) {
	root := serveFixture(t)
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte(`package machine
import "strings"
func Entry(dynamic func()) { Leaf(); Leaf(); dynamic(); strings.TrimSpace("x") }
func Leaf() { Tail() }
func Tail() {}
func Unreachable() {}
`), 0600); err != nil {
		t.Fatal(err)
	}
	p, err := analyze.Load(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, expansions := range [][]string{nil, {"Leaf"}, {"Leaf", "Tail", "Leaf"}} {
		params, _ := json.Marshal(map[string]any{"kind": "calls", "function": "Entry", "expand": expansions})
		got, err := graphRequest(t, p, string(params))
		if err != nil {
			t.Fatal(err)
		}
		flow, err := newFlow(p, "Entry", expansions)
		if err != nil {
			t.Fatal(err)
		}
		if got.Kind != "calls" || got.Mermaid != flow.diagram() || len(got.Edges) != len(flow.edges) {
			t.Fatalf("graph: %+v", got)
		}
		nodes := map[string]bool{}
		for _, node := range got.Nodes {
			nodes[node.ID] = true
		}
		unknown := false
		for i, edge := range flow.edges {
			if got.Edges[i] != (serveGraphEdge{edge.From, edge.To, edge.Unknown}) || !nodes[edge.From] || !nodes[edge.To] {
				t.Fatalf("edge mismatch or missing endpoint: %+v", got)
			}
			unknown = unknown || edge.Unknown
		}
		if !unknown || !nodes["strings.TrimSpace"] || nodes["example.com/machine.Unreachable"] {
			t.Fatalf("missing unknown/external or unexpected unreachable node: %+v", got)
		}
	}
	for _, params := range []string{
		`{"kind":"calls"}`, `{"kind":"calls","function":"missing"}`,
		`{"kind":"calls","function":"Entry","expand":["Tail"]}`,
		`{"kind":"calls","function":"Entry","expand":["Unreachable"]}`,
	} {
		if _, err := graphRequest(t, p, params); err == nil {
			t.Errorf("accepted invalid params: %s", params)
		}
	}
	leaf, err := graphRequest(t, p, `{"kind":"calls","function":"Tail"}`)
	if err != nil || !reflect.DeepEqual(leaf.Nodes, []serveGraphNode{{ID: "example.com/machine.Tail", Label: "example.com/machine.Tail"}}) || leaf.Edges == nil || len(leaf.Edges) != 0 {
		t.Fatalf("standalone leaf: %+v, %v", leaf, err)
	}
}

func TestServeGraphProtocol(t *testing.T) {
	responses := serveMessages(t, serveFixture(t), `{"id":1,"method":"graph","params":{"kind":"deps"}}
{"id":2,"method":"graph","params":{"kind":"calls","function":"Leaf"}}
{"id":3,"method":"graph","params":{"kind":"invalid"}}
{"id":4,"method":"graph","params":{"kind":"deps","depth":"wrong"}}
{"id":5,"method":"functions"}
`)
	if len(responses) != 5 {
		t.Fatalf("responses: %+v", responses)
	}
	for i, response := range responses {
		if response.ID != i+1 {
			t.Fatalf("response ordering: %+v", responses)
		}
		if i == 2 || i == 3 {
			if response.Error == "" || response.Result != nil {
				t.Fatalf("expected protocol error: %+v", response)
			}
		} else if response.Error != "" {
			t.Fatalf("response: %+v", response)
		}
	}
	for _, response := range responses[:2] {
		graph := response.Result.(map[string]any)
		if len(graph) != 4 || graph["nodes"] == nil || graph["edges"] == nil || !strings.HasPrefix(graph["mermaid"].(string), "flowchart TD\n") {
			t.Fatalf("graph JSON contract: %+v", graph)
		}
	}
	data, err := json.Marshal(serveGraphEdge{From: "a", To: "b", Unknown: true})
	if err != nil || string(data) != `{"from":"a","to":"b","unknown":true}` {
		t.Fatalf("unknown edge JSON: %s, %v", data, err)
	}
	data, err = json.Marshal(serveGraphEdge{From: "a", To: "b"})
	if err != nil || string(data) != `{"from":"a","to":"b"}` {
		t.Fatalf("known edge JSON: %s, %v", data, err)
	}
}
