.PHONY: build test

build:
	cd backend && go build -o ../bin/hodocode ./cmd/hodocode

test: build
	cd backend && go test ./cmd/hodocode ./internal/...
	nvim --headless -u NONE -l tests/headless.lua
	nvim --headless -u NONE -l tests/edges.lua
	nvim --headless -u NONE -l tests/errors.lua
	nvim --headless -u NONE -l tests/mode.lua
	nvim --headless -u NONE -l tests/marker.lua
	nvim --headless -u NONE -l tests/reader_keys.lua
	nvim --headless -u NONE -l tests/reader_history.lua
	nvim --headless -u NONE -l tests/navigation.lua
	nvim --headless -u NONE -l tests/tree.lua
	nvim --headless -u NONE -l tests/ai_trial.lua
	nvim --headless -u NONE -l tests/function_explain.lua
	nvim --headless -u NONE -l tests/trial_demo.lua
	nvim --headless -u NONE -l tests/snacks_integration.lua
