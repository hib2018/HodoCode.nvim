.PHONY: build test

build:
	cd backend && go build -o ../bin/hodocode ./cmd/hodocode

test: build
	cd backend && go test ./cmd/hodocode ./internal/...
	nvim --headless -u NONE -l tests/headless.lua
	nvim --headless -u NONE -l tests/edges.lua
	nvim --headless -u NONE -l tests/errors.lua
