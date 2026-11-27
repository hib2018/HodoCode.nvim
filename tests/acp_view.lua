local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.lines, vim.o.columns = true, 35, 120
  local warnings = {}
  vim.notify = function(message) warnings[#warnings + 1] = message end
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local temp = vim.fn.tempname()
  vim.fn.mkdir(temp .. '/a', 'p'); vim.fn.mkdir(temp .. '/b', 'p')
  vim.api.nvim_buf_set_name(source, temp .. '/a/source.lua')
  local b = vim.fn.bufadd(temp .. '/b/source.lua'); vim.fn.bufload(b)
  local session, chat = require('hodocode.session'), require('hodocode.chat')
  package.loaded['hodocode.agent'] = { status = function() return { phase = 'streaming' } end }
  local config = { agent_transport = 'acp', agent = { 'unused' } }
  assert(chat.open(config, { buf = source, win = source_win }))
  local astate = session.get()
  for i = 1, 60 do session.append('user', 'old history ' .. i) end
  session.changed()
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local edits = {}
  vim.api.nvim_buf_attach(buf, false, { on_lines = function(_, _, _, first) edits[#edits + 1] = first end })
  astate.request = { source = source, stream = '# live', intent = 'chat', phase = 'streaming',
    tool = { title = 'read_file', kind = 'read', status = 'in_progress', rawInput = 'SECRET' } }
  session.changed()
  assert(text():find('# live', 1, true)
    and text():find('read_file / ' .. require('hodocode.ui').label('in_progress'), 1, true))
  assert(not text():find('SECRET', 1, true))
  astate.request.tool = { sessionUpdate = 'notice', message = 'SECRET_NOTICE' }; session.changed()
  assert(text():find('通知を受信', 1, true) and not text():find('ツール:  / ', 1, true))
  assert(not text():find('SECRET_NOTICE', 1, true))
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  session.changed(); assert(vim.api.nvim_buf_get_changedtick(buf) == tick, 'identical stream repainted')
  vim.api.nvim_win_set_cursor(win, { 10, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
  local saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  vim.api.nvim_set_current_win(source_win)
  edits = {}
  astate.request.stream = '# live\n\n**answer**'
  session.changed()
  assert(#edits == 1 and edits[1] > 100, 'chunk rewrote old history')
  local after = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  assert(saved.lnum == after.lnum and saved.topline == after.topline)
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(not chat.open(config, { buf = b, win = source_win }))
  assert(session.get() == astate and chat.source().buf == source, 'busy switched source')
  assert(chat.open(config, { buf = source, win = source_win }), 'same project blocked')
  astate.request.intent = 'edit'; session.changed()
  assert(text():find('```json', 1, true) and not text():find('適用済み', 1, true))
  astate.request = nil
  session.append('assistant', 'final answer', { outcome = 'nochange' }); session.changed()
  assert(text():find('final answer', 1, true) and not text():find('# live', 1, true))
  assert(chat.open(config, { buf = b, win = source_win }))
  assert(not text():find('old history', 1, true), 'B inherited A history')
  session.append('assistant', 'B only'); session.changed()
  assert(chat.open(config, { buf = source, win = source_win }))
  assert(session.get() == astate and text():find('final answer', 1, true) and not text():find('B only', 1, true))
  astate.request = { source = source, stream = 'follow tail', phase = 'streaming' }; session.changed()
  assert(vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf))
  chat.hide(); tick = vim.api.nvim_buf_get_changedtick(buf)
  astate.request.stream = 'hidden'; session.changed()
  assert(not chat.visible() and vim.api.nvim_buf_get_changedtick(buf) == tick)
  astate.request = nil; chat.shutdown()

  local permission = require('hodocode.acp_permission')
  local disk = temp .. '/a/guard.txt'
  vim.fn.writefile({ 'unchanged' }, disk)
  local function params(name, kind)
    return { sessionId = 'session', toolCall = { toolCallId = 'call', name = name, title = name,
      kind = kind, rawInput = { path = disk, old_string = 'SECRET_OLD', new_string = 'unsafe change' } }, options = {
      { optionId = 'yes', name = 'Allow once', kind = 'allow_once' },
      { optionId = 'no', name = 'Reject', kind = 'reject_once' },
    } }
  end
  local function ask(value)
    local results = {}
    local handle = permission.request(value, function(result) results[#results + 1] = result end)
    return results, handle
  end
  local function key(lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(0, 'n')) do
      if map.lhs == lhs then return map.callback end
    end
    error('missing key ' .. lhs)
  end
  local results, handle = ask(params('read_file', 'read'))
  local panel, panelwin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local paneltext = table.concat(vim.api.nvim_buf_get_lines(panel, 0, -1, false), '\n')
  assert(paneltext:find(disk, 1, true) and not paneltext:find('SECRET_OLD', 1, true))
  assert(vim.bo[panel].readonly and not vim.bo[panel].modifiable)
  local late, late_enter = key('1'), key('<CR>'); late(); handle.cancel(); late(); late_enter()
  assert(#results == 1 and results[1].outcome.optionId == 'yes')
  assert(not vim.api.nvim_win_is_valid(panelwin))
  results, handle = ask(params('read_file', 'read')); key('2')()
  assert(results[1].outcome.outcome == 'selected' and results[1].outcome.optionId == 'no')
  local sixteen = params('read_file', 'read')
  sixteen.options = {}
  for i = 1, 16 do
    sixteen.options[i] = { optionId = 'id-' .. i, name = 'Original option ' .. i, kind = 'reject_once' }
  end
  for i = 10, 16 do
    results = ask(sixteen)
    local letter = string.char(string.byte('a') + i - 10)
    assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      :find(letter .. ': Original option ' .. i, 1, true))
    key(letter)()
    assert(#results == 1 and results[1].outcome.optionId == 'id-' .. i)
  end
  for _, operation in ipairs({ { 'edit_file', 'edit' }, { 'shell', 'execute' }, { 'unknown', 'read' }, { 'read_file', 'edit' } }) do
    results, handle = ask(params(operation[1], operation[2]))
    assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('不可: 直接操作未対応', 1, true))
    key('1')(); assert(#results == 1 and results[1].outcome.outcome == 'cancelled')
  end
  assert(vim.fn.readfile(disk)[1] == 'unchanged', 'permission panel changed disk')
  results, handle = ask(params('read_file', 'read')); late = key('1')
  handle.cancel(); handle.cancel(); late()
  assert(#results == 1 and results[1].outcome.outcome == 'cancelled')
  local stops = 0
  package.loaded['hodocode.agent'].stop = function() stops = stops + 1; handle.cancel() end
  results, handle = ask(params('read_file', 'read'))
  panelwin = vim.api.nvim_get_current_win()
  late, late_enter = key('1'), key('<CR>')
  local stop = key('x'); stop(); stop(); late(); late_enter()
  assert(stops == 1 and #results == 1 and results[1].outcome.outcome == 'cancelled')
  assert(not vim.api.nvim_win_is_valid(panelwin), 'x left permission panel open')
  results = ask(params('read_file', 'read')); key('q')()
  assert(stops == 1 and #results == 1 and results[1].outcome.outcome == 'cancelled')
  results = ask(params('read_file', 'read')); vim.api.nvim_win_close(0, true)
  assert(#results == 1 and results[1].outcome.outcome == 'cancelled')
  results = ask({}); assert(#results == 1 and results[1].outcome.outcome == 'cancelled')
  local invalid = params('read_file', 'read'); invalid.options[1].kind = 'invented'
  results = ask(invalid); assert(#results == 1 and results[1].outcome.outcome == 'cancelled')
  vim.fn.delete(temp, 'rf')
  print('PASS: ACP stream/cache/focus/tail/history scope/busy; permission read/reject/unsafe/unknown/close/cancel-once/late callbacks')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
