local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local mode = require('hodocode.mode')
  local clients = require('hodocode.client')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  root = assert((vim.uv or vim.loop).fs_realpath(root))
  vim.fn.writefile({ 'module example.test/readerkeys', '', 'go 1.23' }, root .. '/go.mod')
  local original = {
    'package main',
    'import "fmt"',
    'func leaf() {}',
    'func 日本語() {}',
    'func first() {',
    '  leaf(); leaf()',
    '  日本語(); fmt.Println("日本語"); var f func(); f()',
    '  leaf()',
    '}',
    'func second() {',
    '  leaf()',
    '}',
    'func empty() {',
    '  // no calls',
    '}',
    'var reference = leaf',
  }
  vim.fn.writefile(original, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  hc.setup({ root = root, language = 'go' })
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = tostring(message) end
  local function wait(test, label)
    local ready = vim.wait(15000, test, 10)
    assert(ready, (type(label) == 'function' and label() or label) .. '\n' .. table.concat(notices, '\n'))
  end
  local function cursor(row, col)
    vim.api.nvim_win_set_cursor(0, { row, col or 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = source })
  end
  local function position() return vim.api.nvim_win_get_cursor(0) end
  local function at(expected, label)
    assert(vim.deep_equal(position(), expected), label .. ': ' .. vim.inspect(position()) .. ' ~= ' .. vim.inspect(expected))
  end
  local function press(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'mx', false)
  end
  local function invoke(key)
    local map = vim.fn.maparg(key, 'n', false, true)
    assert(map.buffer == 1 and type(map.callback) == 'function', 'missing source mapping: ' .. key)
    map.callback()
  end
  local function column(row, token, start)
    return assert(original[row]:find(token, start or 1, true), token) - 1
  end
  local first = { 6, column(6, 'leaf') }
  local repeated = { 6, column(6, 'leaf', first[2] + 2) }
  local utf8 = { 7, column(7, '日本語') }
  local sdk = { 7, column(7, 'Println') }
  local unresolved = { 7, column(7, 'f()') }
  local last = { 8, column(8, 'leaf') }
  local ns = vim.api.nvim_create_namespace('HodoCodeFunction')
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true }) end
  local function strong_marks()
    return vim.tbl_filter(function(mark) return mark[4].hl_group == 'HodoCodeFunction' end, marks())
  end

  -- Observe the real backend, keeping its responses and all navigation code intact.
  local client = clients.start(root, hc.config)
  local request = client.request
  local pending, requests, completed_calls = 0, 0, 0
  local results = {}
  client.request = function(self, method, params, callback)
    pending, requests = pending + 1, requests + 1
    return request(self, method, params, function(result, err)
      pending = pending - 1
      if method == 'calls' and not err then
        completed_calls = completed_calls + 1
        results[params['function']] = result
      end
      callback(result, err)
    end)
  end
  local untouched = {}
  for _, key in ipairs({ 'h', 'j', 'k', 'l', 'w', 'B', '0', '$', '<PageUp>', '<PageDown>' }) do
    untouched[key] = vim.fn.maparg(key, 'n', false, true)
  end
  local tick = vim.api.nvim_buf_get_changedtick(source)
  cursor(5)
  local context_ok, context = pcall(hc.context)
  assert(context_ok, 'fixture context: ' .. tostring(context))
  hc.mode()
  local before = #notices
  press('n'); press('N'); press('g'); press('G')
  at({ 5, 0 }, 'not-ready navigation must not move')
  assert(#notices > before, 'not-ready navigation must report an error')
  wait(function() return completed_calls >= 5 and pending == 0 end, function()
    return ('real backend callsite cache: requests=%d pending=%d calls=%d mode=%s'):format(
      requests, pending, completed_calls, tostring(mode.active()))
  end)
  at({ 5, 0 }, 'cache completion must not asynchronously teleport')
  for key, map in pairs(untouched) do
    assert(vim.deep_equal(vim.fn.maparg(key, 'n', false, true), map), 'changed native motion: ' .. key)
  end
  local first_result
  for id, result in pairs(results) do if id:match('%.first$') then first_result = result end end
  assert(first_result and #first_result.calls == 6, 'fixture must retain every repeated/named callsite')
  local names = {}
  for _, site in ipairs(first_result.calls) do
    names[#names + 1] = original[site.Line]:sub(site.Column, site.EndColumn - 1)
  end
  assert(vim.deep_equal(names, { 'leaf', 'leaf', '日本語', 'Println', 'f', 'leaf' }), 'backend byte positions/name order: ' .. vim.inspect(names))
  assert(first_result.calls[5].Unknown, 'fixture function variable must remain unresolved')
  assert(#marks() == 13 and #strong_marks() == 5, 'all names must be marked, only proven targets strongly')
  for _, mark in ipairs(strong_marks()) do
    local name = original[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
    assert(name == 'leaf' or name == '日本語', 'navigation broadened proven-jumpable source markers: ' .. name)
  end

  local cached_requests = requests
  press('n'); at(first, 'next first call')
  press('n'); at(repeated, 'repeated callee must not deduplicate')
  press('n'); at(utf8, 'UTF8 call')
  press('n'); at(sdk, 'SDK call after UTF8 byte prefix')
  press('n'); at(unresolved, 'unresolved named call')
  press('n'); at(last, 'last call')
  press('n'); at(last, 'forward clamp must not wrap into next function')
  press('99n'); at(last, 'forward count clamp')
  press('N'); at(unresolved, 'previous includes unresolved')
  press('2N'); at(utf8, 'previous count')
  press('99N'); at(first, 'backward count clamp')
  press('N'); at(first, 'backward clamp must not wrap')
  cursor(5)
  press('3n'); at(utf8, 'forward count from before first call')
  cursor(9)
  press('2N'); at(unresolved, 'backward count from after last call')
  cursor(first[1], first[2] + 2)
  press('n'); at(repeated, 'inside token next skips current call')
  cursor(repeated[1], repeated[2] + 2)
  press('N'); at(first, 'inside token previous skips current call')
  cursor(11)
  press('99n'); at({ 11, column(11, 'leaf') }, 'next is scoped to second function')
  press('99N'); at({ 11, column(11, 'leaf') }, 'previous cannot escape second function')
  cursor(14, 3)
  before = #notices
  press('n'); press('N')
  at({ 14, 3 }, 'empty function must not navigate elsewhere')
  assert(#notices > before, 'empty function navigation must report an error')
  cursor(16)
  press('n'); press('N')
  at({ 16, 0 }, 'outside functions must not navigate')
  cursor(7, sdk[2])
  press('g'); at({ 5, 0 }, 'function first line column zero')
  press('G'); at({ 9, 0 }, 'function last line column zero')
  cursor(14, 3)
  press('g'); at({ 13, 0 }, 'empty function first line')
  press('G'); at({ 15, 0 }, 'empty function last line')
  assert(requests == cached_requests, 'reader navigation must use cache, not issue async requests')

  -- Dispatch aliases only after the real backend/navigation checks above.
  local actions = {
    { 't', 'calls' }, { 'b', 'back' }, { 'e', 'chat' }, { 'i', 'chat' }, { 'E', 'explain_now' },
    { 'c', 'notes_toggle' }, { '[', 'help_up' }, { ']', 'help_down' }, { 'f', 'functions' },
    { 's', 'syntax' }, { 'r', 'reload' }, { 'a', 'explain' }, { 'x', 'cancel' },
    { 'd', 'diff' }, { 'K', 'notes_show' }, { 'z', 'notes_clear' }, { 'm', 'graph' },
  }
  for _, action in ipairs(actions) do
    local key, method = action[1], action[2]
    local original_method, calls = hc[method], 0
    assert(type(original_method) == 'function', 'missing API: ' .. method)
    hc[method] = function() calls = calls + 1 end
    invoke(key)
    hc[method] = original_method
    assert(calls == 1 and mode.active(), 'wrong dispatch or mode exit: ' .. key .. ' -> ' .. method)
  end
  local explain = require('hodocode.explain')
  local explain_run, input, select = explain.run, vim.ui.input, vim.ui.select
  local prompt
  explain.run = function(_, value) prompt = value end
  vim.ui.input = function() error('E must not prompt for input') end
  vim.ui.select = function() error('E must not ask for confirmation') end
  invoke('E')
  explain.run, vim.ui.input, vim.ui.select = explain_run, input, select
  assert(prompt == 'Explain this function line by line. Read-only; do not modify files.',
    'E must send the canned read-only explain prompt immediately')
  assert(vim.api.nvim_buf_get_changedtick(source) == tick and not vim.bo[source].modified, 'reader actions changed source')
  assert(vim.deep_equal(vim.fn.readfile(root .. '/main.go'), original), 'reader actions changed source on disk')

  for _, key in ipairs({ 'q', '<C-c>', '<C-d>', '<Esc>', 'v' }) do
    if not mode.active() then hc.mode() end
    invoke(key)
    assert(not mode.active() and #marks() == 0, 'exit alias failed to stop/clear mode: ' .. key)
    assert(vim.api.nvim_get_current_buf() == source, 'exit alias must return to editor: ' .. key)
    wait(function() return pending == 0 end, 'late calls after ' .. key)
    assert(#marks() == 0, 'late calls restored markers after ' .. key)
  end

  cursor(5)
  hc.mode()
  hc.exit_mode()
  cursor(14, 3)
  hc.next_call()
  at({ 14, 3 }, 'stopped cache must not move cursor')
  wait(function() return pending == 0 end, 'stopped mode late responses')
  at({ 14, 3 }, 'stopped late responses must not move cursor')
  assert(#marks() == 0, 'stopped late responses must not restore markers')

  cursor(5)
  hc.mode()
  wait(function() return pending == 0 end, 'cache before source edit')
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// unsaved edit invalidates byte positions' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  cursor(7)
  hc.next_call(); hc.previous_call(); hc.function_start(); hc.function_end()
  at({ 7, 0 }, 'edited source must not reuse cached call/function positions')
  assert(#marks() == 0, 'edited source kept stale source markers')
  wait(function() return pending == 0 end, 'edited source late responses')
  at({ 7, 0 }, 'edited source late responses must not move cursor')
  assert(vim.deep_equal(vim.fn.readfile(root .. '/main.go'), original), 'invalidation wrote source to disk')
  hc.exit_mode()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, original)
  vim.bo[source].modified = false
  cursor(5)
  hc.mode()
  assert(pending > 0, 'late-response edit test needs an in-flight real backend request')
  vim.api.nvim_buf_set_lines(source, 0, 0, false, { '// edit while backend responds' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  cursor(14, 3)
  wait(function() return pending == 0 end, 'late backend response after edit')
  hc.next_call(); hc.previous_call(); hc.function_start(); hc.function_end()
  at({ 14, 3 }, 'late backend response must not revive edited cache')
  assert(#marks() == 0, 'late backend response restored edited markers')
  hc.exit_mode()
  clients.stop_all()
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: real backend reader keys, repeated/UTF8/unresolved/SDK calls, scoped cached count/clamp navigation, function edges, dispatch/exit aliases, no prompts, stale cleanup and no source mutation')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
