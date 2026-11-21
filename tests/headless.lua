local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module example.test/demo', '', 'go 1.23' }, root .. '/go.mod')
  local original = { 'package main', '', 'func leaf() {}', 'func main() { leaf() }' }
  vim.fn.writefile(original, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  hc.setup({ root = root, language = 'go', timeout_ms = 10000 })
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local function wait(test, label)
    assert(vim.wait(15000, test, 10), 'timeout: ' .. label .. '\n' .. table.concat(notices, '\n'))
  end
  local client = require('hodocode.client').start(root, hc.config)
  local functions, calls, syntax
  client:request('functions', {}, function(result, err) assert(not err, err); functions = result end)
  wait(function() return functions ~= nil end, 'functions')
  assert(#functions == 2 and functions[1].ID == 'example.test/demo.leaf')
  client:request('calls', { ['function'] = 'example.test/demo.main' }, function(result, err) assert(not err, err); calls = result end)
  wait(function() return calls ~= nil end, 'calls')
  assert(#calls.calls == 1 and calls.Targets['example.test/demo.leaf'].Line == 3)
  client:request('syntax', { file = 'main.go', row = 3, column = 0 }, function(result, err) assert(not err, err); syntax = result end)
  wait(function() return syntax ~= nil end, 'syntax')
  assert(type(syntax.description) == 'string' and #syntax.description > 0)

  vim.api.nvim_win_set_cursor(0, { 4, 1 })
  hc.syntax()
  wait(function() return vim.bo.buftype == 'nofile' end, 'syntax float')
  local float = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_config(float).relative == 'editor')
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// local' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(not vim.api.nvim_win_is_valid(float), 'stale help must close')
  local valid = pcall(hc.context)
  assert(not valid, 'analysis must reject unsaved code')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, original)
  vim.cmd.write()
  vim.api.nvim_win_set_cursor(0, { 4, 1 })
  hc.calls()
  wait(function() return vim.bo.buftype == 'nofile' end, 'call tree float')
  wait(function() return #vim.api.nvim_buf_get_lines(0, 0, -1, false) >= 4 end, 'tree expansion')
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('example.test/demo.leaf', 1, true))
  vim.api.nvim_win_close(0, true)

  local get_clients = vim.lsp.get_clients
  vim.fn.writefile({ 'def example(): pass' }, root .. '/example.py')
  local python_buf = vim.fn.bufadd(root .. '/example.py')
  vim.lsp.get_clients = function() return { { attached_buffers = { [python_buf] = true } } } end
  hc.config.language = 'auto'
  assert(not pcall(hc.context), 'duplicate non-Go LSP must be blocked')
  hc.config.language = 'go'
  assert(pcall(hc.context), 'Go-only analysis must not be blocked by unrelated Python LSP')
  vim.lsp.get_clients = get_clients

  local selected
  local select = vim.ui.select
  vim.ui.select = function(items, _, callback) selected = items; callback(items[1]) end
  hc.functions()
  wait(function() return selected ~= nil end, 'function selection')
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
  vim.ui.select = select

  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// unsaved' })
  local before = table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n') .. '\n'
  hc.config.agent = { 'python3', '-c', [[import json,sys
r=json.load(sys.stdin)
assert r['buffer']['modified'] and r['prompt']=='update'
json.dump({'message':'done','content':r['buffer']['content']+'// agent\n'},sys.stdout)]] }
  hc.agent('update')
  wait(function() return table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n'):find('// agent', 1, true) ~= nil end, 'agent edit')
  assert(vim.bo[source].modified, 'agent must not silently save')
  assert(not table.concat(vim.fn.readfile(root .. '/main.go'), '\n'):find('// agent', 1, true))
  vim.api.nvim_win_close(0, true)
  hc.diff()
  assert(#vim.api.nvim_tabpage_list_wins(0) == 2 and vim.wo.diff, 'diff tab')
  local found_before = false
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buf ~= source then
      found_before = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n' == before
    end
  end
  assert(found_before, 'diff baseline must include preexisting unsaved edits, not HEAD')
  vim.cmd.tabclose()
  vim.api.nvim_win_set_buf(0, source)
  hc.config.agent = { 'python3', '-c', [[import json,sys,time
r=json.load(sys.stdin)
time.sleep(0.2)
json.dump({'message':'done','content':'SHOULD NOT APPLY\n'},sys.stdout)]] }
  hc.agent('conflict')
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// concurrent edit' })
  wait(function() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('競合', 1, true) ~= nil end, 'conflict guard')
  assert(not table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n'):find('SHOULD NOT APPLY', 1, true))
  vim.api.nvim_win_close(0, true)
  vim.cmd.write()
  local external = vim.fn.readfile(root .. '/main.go')
  external[#external + 1] = '// external edit'
  vim.fn.writefile(external, root .. '/main.go')
  vim.api.nvim_exec_autocmds('FocusGained', {})
  wait(function() return vim.api.nvim_buf_get_lines(source, -2, -1, false)[1] == '// external edit' end, 'automatic disk reload')

  -- Modified user buffers are never replaced by external file changes.
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// keep me' })
  vim.fn.writefile(original, root .. '/main.go')
  vim.api.nvim_exec_autocmds('FocusGained', {})
  assert(vim.api.nvim_buf_get_lines(source, -2, -1, false)[1] == '// keep me')
  require('hodocode.client').stop_all()
  require('hodocode.agent').stop()
  vim.fn.delete(root, 'rf')
  print('PASS: API, navigation, calls, syntax/stale guard, unsaved agent context, edit/diff, conflict guard, automatic reload')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
