local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.columns, vim.o.lines = true, 140, 45
  vim.cmd('runtime plugin/hodocode.lua')
  local hc, mode, ui = require('hodocode'), require('hodocode.mode'), require('hodocode.ui')
  require('hodocode.client').start = function() error('UX must not start backend') end
  require('hodocode.prepare').argv = function() error('UX must not enter AI preparation') end
  local path = vim.fn.tempname() .. '.go'
  vim.fn.writefile({ 'package main', 'func main() {}' }, path)
  vim.cmd.edit(path)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local items, select, options
  vim.ui.select = function(list, opts, callback) items, options, select = list, opts, callback end
  local routed = {}
  local methods = { 'mode', 'next_call', 'previous_call', 'follow', 'back', 'function_start', 'function_end',
    'calls', 'functions', 'syntax', 'graph', 'notes_show', 'notes_toggle', 'notes_clear', 'help_up', 'help_down',
    'reload', 'explain_now', 'explain_line', 'agent', 'chat', 'cancel', 'diff', 'exit_mode' }
  local originals = {}
  for _, method in ipairs(methods) do
    originals[method] = hc[method]
    hc[method] = function()
      assert(vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf, 'wrong action source')
      routed[#routed + 1] = method
    end
  end
  vim.cmd('HodoCode')
  assert(items and options.prompt:find(':write', 1, true), 'palette command/workflow missing')
  local found = {}
  for _, item in ipairs(items) do
    assert(options.format_item(item):find(' | ', 1, true), 'category missing')
    if item.method ~= 'help' then
      local count = #routed
      select(item)
      assert(#routed == count + 1 and routed[#routed] == item.method, 'incorrect routing: ' .. item.method)
      found[item.method] = true
    end
  end
  for _, method in ipairs(methods) do assert(found[method], 'palette action missing: ' .. method) end
  local count = #routed
  select(nil)
  assert(#routed == count and vim.api.nvim_get_current_win() == win, 'cancel had effects')
  assert(vim.api.nvim_buf_get_changedtick(buf) == tick and not vim.bo[buf].modified, 'palette edited source')
  assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)), 'menu changed content')
  local notifications = {}
  local notify = vim.notify
  vim.notify = function(message) notifications[#notifications + 1] = message end
  local action = items[1]
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'func changed() {}' })
  select(action)
  assert(#routed == count and #notifications == 1, 'changed source accepted')
  hc.actions()
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(win, other)
  select(action)
  assert(#routed == count and #notifications == 2, 'replaced source accepted')
  vim.api.nvim_win_set_buf(win, buf)
  hc.actions()
  select(nil)
  assert(#routed == count and #notifications == 2, 'cancel notified')
  vim.notify = notify
  for method, original in pairs(originals) do hc[method] = original end
  -- Full help also works without entering mode.
  hc.actions()
  for _, item in ipairs(items) do if item.method == 'help' then select(item); break end end
  assert(not mode.active() and vim.api.nvim_get_current_win() ~= win, 'standalone full help unavailable')
  vim.fn.maparg('<Esc>', 'n', false, true).callback()
  assert(vim.api.nvim_get_current_win() == win, 'help Esc lost source')
  local status = { phase = 'waiting', running = true, elapsed_ms = 2400 }
  require('hodocode.agent').status = function(source) assert(source == buf); return status end
  mode.start()
  local function guide_text()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == 'hodocode-mode' then return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n') end
    end
    error('guide missing')
  end
  local function refresh()
    vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeAgentStatus', data = { buf = buf } })
  end
  status = nil
  hc.config.agent = nil
  refresh()
  assert(guide_text():find('AI:未設定', 1, true), 'nil agent must be unset')
  hc.config.agent = {}
  refresh()
  assert(guide_text():find('AI:未設定', 1, true), 'empty agent must be unset')
  hc.config.agent = { 'test-agent' }
  refresh()
  assert(guide_text():find('AI:待機', 1, true), 'configured idle agent missing')
  hc.config.agent = nil
  status = { phase = 'waiting', running = true, elapsed_ms = 2400 }
  refresh()
  assert(guide_text():find('未保存', 1, true) and guide_text():find('AI:応答待ち', 1, true), 'dirty/session guide missing')
  assert(not guide_text():find('2s', 1, true), 'guide must not display stale elapsed time')
  for phase, label in pairs({ starting = '開始中', received = '応答受信', validating = '検証中',
    applying = '反映中', done = '完了', error = '失敗', cancelled = '中止' }) do
    status = { phase = phase, running = false }
    vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeAgentStatus', data = { buf = buf, phase = phase, running = false } })
    assert(guide_text():find(label, 1, true), 'agent phase not readable: ' .. phase)
  end
  local background = vim.api.nvim_create_buf(true, false)
  local session, agent = require('hodocode.session').get(), require('hodocode.agent')
  local get_status = agent.status
  session.request = { source = background }
  agent.status = function(target)
    assert(target == background)
    return { phase = 'received', running = true }
  end
  vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeAgentStatus', data = { buf = background } })
  assert(guide_text():find('AI:応答受信', 1, true), 'background request status did not refresh')
  session.request, agent.status = nil, get_status
  vim.api.nvim_buf_delete(background, { force = true })
  vim.bo[buf].modified = false
  vim.api.nvim_exec_autocmds('BufModifiedSet', { buffer = buf })
  assert(guide_text():find('保存済み', 1, true), 'saved guide did not refresh')
  -- Palette opened from a mode result still dispatches to the original source.
  local _, popup = ui.float({ 'result' }, 'test')
  hc.actions()
  local old = hc.diff
  local called = false
  hc.diff = function() called = vim.api.nvim_get_current_win() == win end
  for _, item in ipairs(items) do if item.method == 'diff' then select(item); break end end
  assert(called, 'result palette did not return to source')
  hc.diff = old
  vim.api.nvim_set_current_win(popup)
  local width, height = ui.popup_size()
  assert(vim.api.nvim_win_get_width(popup) == width and vim.api.nvim_win_get_height(popup) == height, 'popup geometry changed')
  vim.fn.maparg('<Esc>', 'n', false, true).callback()
  assert(not vim.api.nvim_win_is_valid(popup) and mode.active() and vim.api.nvim_get_current_win() == win, 'result Esc exited mode or lost source')
  mode.stop()
  assert(vim.tbl_isempty(vim.fn.maparg('<Esc>', 'n', false, true)), 'source Esc not restored')
  assert(vim.deep_equal(vim.fn.readfile(path), before), 'UX wrote source to disk')
  vim.fn.delete(path)
  print('PASS: complete palette routing, cancel/stale guards, no autosave/edit, standalone help, source focus/Esc, geometry, dirty/agent event guide')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
