local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local mode = require('hodocode.mode')
  local ns = vim.api.nvim_create_namespace('HodoCodeFunction')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module example.test/marker', '', 'go 1.23' }, root .. '/go.mod')
  local original = { 'package main', 'import "fmt"', 'func leaf() {}', 'func 日本語() {}',
    'func first() { leaf(); leaf(); other() }',
    'func second() { 日本語(); fmt.Println("x"); var f func(); f() }',
    'var reference = leaf', 'func third() {', '  leaf()', '}' }
  vim.fn.writefile(original, root .. '/main.go')
  vim.fn.writefile({ 'package main', 'func other() { leaf() }' }, root .. '/other.go')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  hc.setup({ root = root, language = 'go' })
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true }) end
  local function wait(test, label) assert(vim.wait(15000, test, 10), label) end
  local function cursor(row, col)
    vim.api.nvim_win_set_cursor(0, { row, col or 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = source })
  end
  local function marked_names()
    local names = {}
    for _, mark in ipairs(marks()) do
      local details = mark[4]
      assert(mark[2] == details.end_row and not details.hl_eol, 'marker must cover a name, not full lines')
      local line = vim.api.nvim_buf_get_lines(source, mark[2], mark[2] + 1, false)[1]
      names[#names + 1] = line:sub(mark[3] + 1, details.end_col)
    end
    return names
  end
  vim.api.nvim_set_hl(0, 'HodoCodeFunction', { bg = 0x123456 })
  cursor(1)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  hc.mode()
  wait(function() return #marks() == 5 end, 'all jumpable names, without cursor inside a function')
  assert(vim.deep_equal(marked_names(), { 'leaf', 'leaf', 'other', '日本語', 'leaf' }),
    'marked declaration/reference/external/unresolved call or missed UTF8/local target')
  assert(vim.api.nvim_get_hl(0, { name = 'HodoCodeFunction' }).bg == 0x123456, 'overwrote user highlight')
  local function positions()
    local result = {}
    for _, mark in ipairs(marks()) do result[#result + 1] = { mark[2], mark[3], mark[4].end_row, mark[4].end_col } end
    return result
  end
  local before = positions()
  cursor(10)
  assert(vim.deep_equal(positions(), before), 'cursor movement changed name markers')
  local _, float = require('hodocode.ui').float({ 'popup' }, 'test')
  assert(#marks() == 5 and mode.active(), 'float lost source markers')
  vim.api.nvim_win_close(float, true)
  assert(vim.api.nvim_buf_get_changedtick(source) == tick and not vim.bo[source].modified, 'marker edited source')
  local target = vim.fn.bufadd(root .. '/other.go')
  vim.fn.bufload(target)
  vim.api.nvim_buf_set_lines(target, 0, 0, false, { '// local edit' })
  cursor(1)
  assert(#marks() == 4 and not vim.tbl_contains(marked_names(), 'other'), 'marked an unjumpable modified target')
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { 'package main', 'func other() { leaf() }' })
  vim.bo[target].modified = false
  cursor(5, original[5]:find('leaf', 1, true) - 1)
  assert(#marks() == 5)
  vim.fn.maparg('<CR>', 'n', false, true).callback()
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 3 end, 'Enter on a marked name')
  assert(#marks() == 5 and mode.active(), 'jump lost other name markers')
  vim.api.nvim_buf_set_lines(source, 1, 1, false, { '' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(#marks() == 0 and mode.active(), 'edit did not invalidate markers')
  vim.cmd.write()
  wait(function() return #marks() == 5 end, 'saved source marker refresh')
  assert(marks()[1][2] == 5 and marks()[5][2] == 9, 'saved name positions are stale')
  hc.exit_mode()
  assert(#marks() == 0, 'mode exit left markers')

  local clients = require('hodocode.client')
  clients.stop_all()
  local start, pending = clients.start, {}
  clients.start = function()
    return { request = function(_, method, params, callback)
      pending[#pending + 1] = { method, callback, params }
    end }
  end
  cursor(6)
  hc.mode()
  assert(pending[1][1] == 'reload')
  pending[1][2]({ reloaded = true })
  assert(pending[2][1] == 'functions')
  pending[2][2]({ { ID = 'first', File = 'main.go', Line = 6, End = 6 },
    { ID = 'other', File = 'other.go', Line = 2, End = 2 } })
  assert(#pending == 3 and pending[3][1] == 'calls' and pending[3][3]['function'] == 'first', 'must request calls only for source file')
  local site = { Line = 6, Column = 16, EndColumn = 20, To = 'leaf' }
  local result = { calls = { site }, Targets = { leaf = { File = 'main.go', Line = 4 } } }
  hc.exit_mode()
  pending[3][2](result)
  assert(#marks() == 0, 'late calls after exit inserted markers')
  pending = {}
  hc.mode()
  pending[1][2]({ reloaded = true })
  pending[2][2]({ { ID = 'first', File = 'main.go', Line = 6, End = 6 } })
  -- Overlapping call ranges cannot be followed unambiguously.
  pending[3][2]({ calls = { site, site }, Targets = result.Targets })
  assert(#marks() == 0, 'ambiguous ranges marked')
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// changed' })
  pending[3][2](result)
  assert(#marks() == 0, 'late calls after edit inserted markers')
  hc.exit_mode()
  pending = {}
  hc.mode()
  assert(#pending == 0 and #marks() == 0, 'unsaved source should not request analysis')
  hc.exit_mode()
  clients.start = start
  hc.setup({ root = root })
  vim.api.nvim_buf_delete(target, { force = true })
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: all jumpable call names independent of cursor, UTF8/external/unknown/ambiguous/modified-target exclusions, Enter, save refresh, stale cleanup; no source writes')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
