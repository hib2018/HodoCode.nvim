local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.lines, vim.o.columns = true, 45, 140
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved source', 'second line' })
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local source_undo = vim.bo[source].undolevels
  local pending = { source = source, phase = 'waiting' }
  local session = { id = 'test', history = { { role = 'user', content = 'first question', intent = 'chat', file = 'source.lua', status = 'sent', request_id = 'private-request-id' },
    { role = 'assistant', content = 'first answer', intent = 'edit', file = 'target.lua', outcome = 'applied' } }, request = pending }
  local calls, cancelled, exited = {}, 0, 0
  package.loaded['hodocode.session'] = { get = function() return session end }
  package.loaded['hodocode.agent'] = {
    status = function(buf)
      assert(buf == source)
      return { phase = pending.phase, elapsed_ms = 2300, running = true }
    end,
    run = function(config, prompt, intent, target)
      calls[#calls + 1] = { config = config, prompt = prompt, intent = intent, target = target }
    end,
    stop = function() error('view cancelled request') end,
  }
  package.loaded['hodocode'] = { cancel = function() cancelled = cancelled + 1 end }
  package.loaded['hodocode.mode'] = { stop = function() exited = exited + 1 end }
  local chat, ui = require('hodocode.chat'), require('hodocode.ui')
  local events = { 'WinClosed', 'VimResized', 'User', 'BufWipeout', 'VimLeavePre' }
  local baseline = #vim.api.nvim_get_autocmds({ event = events })
  local function key(buf, mode, lhs)
    local map = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, mode, false, true) end)
    assert(map.callback, 'missing mapping: ' .. lhs)
    map.callback()
  end
  local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local config = { agent = { 'mock-only' } }
  assert(chat.open(config))
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  assert(buf ~= source and chat.visible())
  assert(chat.is_view(buf) and not chat.is_view(source) and not chat.is_view(nil))
  local reader = vim.api.nvim_create_buf(false, true)
  vim.bo[reader].readonly, vim.bo[reader].modifiable = true, false
  assert(not chat.is_view(reader), 'unrelated readonly view accepted')
  vim.api.nvim_buf_delete(reader, { force = true })
  assert(vim.bo[buf].bufhidden == 'hide' and vim.bo[buf].filetype == 'markdown')
  assert(not vim.bo[buf].modifiable and vim.bo[buf].readonly and vim.bo[buf].undolevels == -1)
  assert(text(buf):find('first answer', 1, true) and text(buf):find('応答待ち（経過 2秒）', 1, true))
  assert(text(buf):find('質問 | 対象: source.lua', 1, true))
  assert(text(buf):find('編集依頼 | 対象: target.lua', 1, true))
  assert(text(buf):find('[送信済み]', 1, true) and text(buf):find('[適用済み]', 1, true))
  assert(not text(buf):find('private-request-id', 1, true))
  assert(text(buf):find('送信時点のコード', 1, true))
  for phase, label in pairs({ validating = '検証中', done = '完了', cancelled = '中止', error = '失敗' }) do
    pending.phase = phase
    vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeSessionChanged' })
    assert(text(buf):find('状態: ' .. label, 1, true))
  end
  pending.phase = 'waiting'
  assert(vim.api.nvim_win_get_config(win).width == ui.popup_size())
  vim.o.lines, vim.o.columns = 30, 100
  vim.api.nvim_exec_autocmds('VimResized', {})
  local width, height = ui.popup_size()
  assert(vim.api.nvim_win_get_config(win).width == width and vim.api.nvim_win_get_config(win).height == height)
  key(buf, 'n', '<Esc>')
  assert(not chat.visible() and vim.api.nvim_buf_is_valid(buf) and chat.is_view(buf))
  assert(session.request == pending and vim.api.nvim_get_current_win() == source_win)
  session.history[#session.history + 1] = { role = 'assistant', content = 'hidden update', outcome = 'cancelled' }
  vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeSessionChanged' })
  assert(not text(buf):find('hidden update', 1, true), 'hidden view repainted')
  assert(vim.api.nvim_get_current_win() == source_win and not chat.visible())
  assert(chat.open(config) and vim.api.nvim_get_current_buf() == buf)
  assert(text(buf):find('hidden update', 1, true) and text(buf):find('[中止]', 1, true))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(win, true)
  assert(not chat.visible() and session.request == pending)
  assert(chat.open(config) and vim.api.nvim_get_current_buf() == buf)
  -- Input is a separate editable popup, and target is captured at submit, not compose.
  key(buf, 'n', 'i')
  local input = vim.api.nvim_get_current_buf()
  assert(input ~= buf and vim.bo[input].modifiable and not chat.is_view(input))
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'a question', 'with a newline' })
  vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
  key(input, 'i', '<C-s>')
  assert(#calls == 1 and calls[1].config == config and calls[1].intent == 'chat')
  assert(calls[1].prompt == 'a question\nwith a newline' and calls[1].target.buf == source)
  assert(calls[1].target.cursor[1] == 2)
  assert(session.request == pending)
  key(buf, 'n', 'A')
  input = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'edit please' })
  local updated_config = { agent = { 'updated-mock-only' } }
  local input_win = vim.api.nvim_get_current_win()
  chat.configure(updated_config)
  assert(vim.api.nvim_get_current_win() == input_win and session.request == pending)
  key(input, 'n', '<CR>')
  assert(calls[2].intent == 'edit' and calls[2].target.buf == source and calls[2].config == updated_config)
  key(buf, 'n', 'x'); assert(cancelled == 1)
  key(buf, 'n', '<C-d>'); assert(exited == 1 and session.request == pending)
  -- Reopening from another source changes future targets, never the active request.
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other)
  chat.open(config)
  assert(chat.source().buf == other and pending.source == source)
  chat.stop()
  for _, mapping in ipairs({ 'q', '<C-c>', '<Esc>' }) do
    chat.open(config)
    assert(vim.api.nvim_get_current_buf() == buf)
    key(buf, 'n', mapping)
    assert(not chat.visible() and session.request == pending)
  end
  assert(exited == 2)
  vim.api.nvim_set_current_buf(source)
  chat.open(config)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(session.request == pending and #session.history == 3)
  chat.open(config)
  buf = vim.api.nvim_get_current_buf()
  assert(text(buf):find('hidden update', 1, true))
  chat.hide()
  -- Stored valid source works even when its original window now displays another buffer.
  vim.api.nvim_set_current_buf(other)
  chat.open(config, { buf = source, win = source_win, cursor = { 2, 0 } })
  key(buf, 'n', '<CR>')
  input = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(input, 0, -1, false, { 'hidden source question' })
  key(input, 'n', '<CR>')
  assert(calls[3].target.buf == source)
  chat.hide()
  chat.open({})
  assert(text(buf):find('`agent` にコマンドと引数を設定', 1, true) and #calls == 3)
  session.request = nil
  session.last_status = { phase = 'error', elapsed_ms = 1200, code = 'invalid_response' }
  vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeSessionChanged' })
  assert(text(buf):find('状態: 失敗', 1, true) and text(buf):find('[不正な応答]', 1, true))
  assert(vim.bo[source].undolevels == source_undo)
  chat.shutdown(); chat.shutdown()
  assert(not vim.api.nvim_buf_is_valid(buf) and not chat.visible() and not chat.is_view(buf) and not chat.is_view(nil))
  assert(#vim.api.nvim_get_autocmds({ event = events }) == baseline, 'autocmd leak')
  assert(vim.api.nvim_buf_get_changedtick(source) == tick and text(source) == 'unsaved source\nsecond line')
  assert(#session.history == 3 and cancelled == 1)
  print('PASS: persistent conversation, hide/reopen/wipe, request independence, submit target/intent, status/setup, cleanup')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
