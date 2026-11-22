package explain

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"github.com/hib2018/HodoCode/internal/analyze"
	"github.com/hib2018/HodoCode/internal/sourcelex"
)

// Buffer is a local, whole-buffer snapshot; Version identifies the original bytes.
type Buffer struct {
	File      string `json:"file"`
	Language  string `json:"language"`
	Content   string `json:"content"`
	Purpose   string `json:"purpose"`
	Version   string `json:"version"`
	LineCount int    `json:"line_count"`
}

// PrepareBuffer masks supplied source without reading or analyzing source files.
// Source and encoded output are each capped at 128 KiB; purpose at 8 KiB.
// Symlinks below the canonical root are rejected, including in existing parents
// of a new file. Concurrent filesystem replacement is outside this API's model.
func PrepareBuffer(root, file, content, purpose string, excludes []string) (*Buffer, error) {
	if !utf8.ValidString(file) || !relative(file) {
		return nil, fmt.Errorf("file must be project-relative without traversal")
	}
	if !utf8.ValidString(content) || strings.ContainsRune(content, 0) {
		return nil, fmt.Errorf("content must be valid UTF-8 without NUL")
	}
	if len(content) > maxPrompt {
		return nil, fmt.Errorf("source exceeds %d bytes", maxPrompt)
	}
	if !utf8.ValidString(purpose) || strings.ContainsRune(purpose, 0) || strings.TrimSpace(purpose) == "" || len(purpose) > maxPurpose {
		return nil, fmt.Errorf("purpose must be valid UTF-8 without NUL, nonempty and at most %d bytes", maxPurpose)
	}
	for _, pattern := range excludes {
		if !utf8.ValidString(pattern) || !relative(pattern) {
			return nil, fmt.Errorf("exclude must be relative without traversal: %q", pattern)
		}
		if _, err := filepath.Match(pattern, ""); err != nil {
			return nil, fmt.Errorf("invalid exclude %q: %w", pattern, err)
		}
	}
	if blocked(file, excludes) {
		return nil, fmt.Errorf("file is excluded or blocked")
	}
	language := analyze.FileLanguage(file)
	if language == "" {
		return nil, fmt.Errorf("unsupported source file %q", file)
	}
	canonical, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("root: %w", err)
	}
	canonical, err = filepath.EvalSymlinks(canonical)
	if err != nil {
		return nil, fmt.Errorf("root: %w", err)
	}
	info, err := os.Stat(canonical)
	if err != nil {
		return nil, fmt.Errorf("root: %w", err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("root is not a directory")
	}
	current := canonical
	parts := strings.Split(file, "/")
	for i, part := range parts {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("source path: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, fmt.Errorf("source path must not contain symlinks")
		}
		if i < len(parts)-1 && !info.IsDir() || i == len(parts)-1 && !info.Mode().IsRegular() {
			return nil, fmt.Errorf("source path must name a regular file")
		}
	}
	var clean string
	if language == "go" {
		clean, err = redact([]byte(content))
	} else {
		clean, err = sourcelex.Mask(language, content)
	}
	if err != nil {
		return nil, fmt.Errorf("redact: %w", err)
	}
	sum := sha256.Sum256([]byte(content))
	result := &Buffer{File: file, Language: language, Content: clean, Purpose: purpose, Version: hex.EncodeToString(sum[:]), LineCount: 1 + strings.Count(content, "\n")}
	encoded, err := json.Marshal(result)
	if err != nil {
		return nil, err
	}
	if len(encoded) > maxPrompt {
		return nil, fmt.Errorf("prepared JSON exceeds %d bytes", maxPrompt)
	}
	return result, nil
}
