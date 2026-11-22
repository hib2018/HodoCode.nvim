local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local mode = require('hodocode.mode')
  local ns = vim.api.nvim_create_namespace('HodoCodeFunction')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module example.test/marker', '', 'go 1.23' }, root .. '/go.mod')
  local original = { 'package main', '', 'func first() {', '}', '', 'func second() {', '}' }
  vim.fn.writefile(original, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  hc.setup({ root = root, language = 'go' })
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true }) end
  local function wait(test, label) assert(vim.wait(15000, test, 10), label) end
  local function cursor(row)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = source })
  end
  vim.api.nvim_set_hl(0, 'HodoCodeFunction', { bg = 0x123456 })
  cursor(3)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  hc.mode()
  wait(function() return #marks() == 1 end, 'initial function marker')
  local mark = marks()[1]
  assert(mark[2] == 2 and mark[4].end_row == 4 and mark[4].hl_eol, 'first function range')
  assert(vim.api.nvim_get_hl(0, { name = 'HodoCodeFunction' }).bg == 0x123456, 'overwrote user highlight')
  cursor(7)
  mark = marks()[1]
  assert(mark[2] == 5 and mark[4].end_row == 7, 'EOF function range / movement')
  cursor(2)
  assert(#marks() == 0, 'outside function retains marker')
  cursor(3)
  local _, float = require('hodocode.ui').float({ 'popup' }, 'test')
  assert(#marks() == 1 and mode.active(), 'float lost source marker')
  vim.api.nvim_win_close(float, true)
  assert(vim.api.nvim_buf_get_changedtick(source) == tick and not vim.bo[source].modified, 'marker edited source')
  vim.api.nvim_buf_set_lines(source, 1, 1, false, { '' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(#marks() == 0 and mode.active(), 'edit did not invalidate marker')
  vim.cmd.write()
  cursor(4)
  wait(function() return #marks() == 1 end, 'saved source marker refresh')
  assert(marks()[1][2] == 3 and marks()[1][4].end_row == 5, 'saved range is stale')
  hc.exit_mode()
  assert(#marks() == 0, 'mode exit left marker')

  -- Neither an old session nor an edited snapshot may insert a delayed marker.
  local clients = require('hodocode.client')
  clients.stop_all()
  local start, pending = clients.start, {}
  clients.start = function()
    return { request = function(_, method, _, callback) pending[#pending + 1] = { method, callback } end }
  end
  hc.mode()
  assert(pending[1][1] == 'reload')
  pending[1][2]({ reloaded = true })
  assert(pending[2][1] == 'functions')
  hc.exit_mode()
  pending[2][2]({ { File = 'main.go', Line = 4, End = 5 } })
  assert(#marks() == 0, 'late response after exit inserted marker')
  pending = {}
  hc.mode()
  pending[1][2]({ reloaded = true })
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// changed' })
  pending[2][2]({ { File = 'main.go', Line = 4, End = 5 } })
  assert(#marks() == 0, 'late response after edit inserted marker')
  hc.exit_mode()
  pending = {}
  hc.mode()
  assert(#pending == 0 and #marks() == 0, 'unsaved source should not request analysis')
  hc.exit_mode()
  clients.start = start
  hc.setup({ root = root })
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: function range marker, cursor/floating focus, EOF, save refresh, exit/edit/stale cleanup, custom highlight, no source writes')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
