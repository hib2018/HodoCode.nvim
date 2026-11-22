package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/hib2018/HodoCode/internal/explain"
)

const maxBufferInput = 1 << 20

func runPrepareBuffer(args []string, in io.Reader, out, stderr io.Writer) error {
	fs := flag.NewFlagSet("prepare-buffer", flag.ContinueOnError)
	fs.SetOutput(stderr)
	root := fs.String("root", ".", "local root (no project analysis or source reads)")
	fs.Usage = func() {
		fmt.Fprintln(stderr, "Usage: hodocode prepare-buffer --root PATH\nstdin: JSON {file,content,purpose,excludes?:string[]}\nLimits: input 1048576 bytes; UTF-8 source 131072 bytes; purpose 8192 bytes; prepared JSON 131072 bytes. Masks the whole buffer locally; no AI calls. Symlinks below root are rejected.")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("unexpected arguments: %s", strings.Join(fs.Args(), " "))
	}
	data, err := io.ReadAll(io.LimitReader(in, maxBufferInput+1))
	if err != nil {
		return fmt.Errorf("read input: %w", err)
	}
	if len(data) > maxBufferInput {
		return fmt.Errorf("input exceeds %d bytes", maxBufferInput)
	}
	if !utf8.Valid(data) {
		return fmt.Errorf("input must be valid UTF-8")
	}
	var request struct {
		File     string   `json:"file"`
		Content  *string  `json:"content"`
		Purpose  string   `json:"purpose"`
		Excludes []string `json:"excludes"`
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return fmt.Errorf("input JSON: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return fmt.Errorf("input must contain exactly one JSON object")
	}
	if request.Content == nil {
		return fmt.Errorf("content is required")
	}
	result, err := explain.PrepareBuffer(*root, request.File, *request.Content, request.Purpose, request.Excludes)
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(result)
}
