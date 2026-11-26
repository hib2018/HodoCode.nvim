local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.lines, vim.o.columns = true, 35, 120
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'source', 'stay here' })
  vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
  local history = {}
  for i = 1, 60 do history[i] = { role = i % 2 == 1 and 'user' or 'assistant', content = 'turn ' .. i } end
  history[60].content = '# Heading\n\n- **bold** and `code`\n\n```lua\nprint("ok")\n```'
  history[60].outcome = 'nochange'
  local session = { history = history }
  local elapsed = 1000
  package.loaded['hodocode.session'] = { get = function() return session end }
  package.loaded['hodocode.agent'] = { status = function() return { phase = 'waiting', elapsed_ms = elapsed } end }
  local chat = require('hodocode.chat')
  local config = { agent = { 'never-run' } }
  chat.open(config)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local function text() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local function tick() return vim.api.nvim_buf_get_changedtick(buf) end
  local function bottom()
    return vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf)
  end
  local function change() vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeSessionChanged' }) end
  assert(bottom(), 'opening long history did not select latest')
  assert(text():find(history[60].content, 1, true), 'Markdown source changed')
  assert(not text():find('[変更なし]', 1, true))
  assert(vim.bo[buf].filetype == 'markdown' and vim.b[buf].current_syntax == 'markdown')
  assert(vim.wo[win].conceallevel == 2)
  local before = tick()
  change(); change()
  assert(tick() == before, 'idle repaint')
  local edits = {}
  vim.api.nvim_buf_attach(buf, false, { on_lines = function(_, _, _, first, last, new_last)
    edits[#edits + 1] = { first, last, new_last }
  end })
  session.request = { source = source, phase = 'waiting' }
  change()
  local status_line = vim.api.nvim_buf_line_count(buf) - 1
  assert(text():match('状態: 応答待ち（経過 1秒）$'))
  before = tick(); edits = {}
  change()
  assert(tick() == before and #edits == 0, 'identical status repaint')
  elapsed = 2000
  change()
  assert(#edits == 1 and edits[1][1] == status_line and edits[1][2] == status_line + 1,
    'status update rewrote history prefix')
  -- Reader position survives appends; async rendering must not take source focus.
  vim.api.nvim_win_set_cursor(win, { 10, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
  local saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  vim.api.nvim_set_current_win(source_win)
  edits = {}
  history[#history + 1] = { role = 'assistant', content = 'new tail', outcome = 'applied' }
  change()
  local after = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  assert(after.lnum == saved.lnum and after.topline == saved.topline, 'append jumped reader')
  assert(vim.api.nvim_get_current_win() == source_win, 'render stole focus')
  assert(#edits == 1 and edits[1][1] > 100, 'append rewrote history prefix')
  -- Explicit open always goes latest, including an already-visible view.
  chat.open(config)
  assert(bottom() and vim.api.nvim_get_current_win() == win)
  history[#history + 1] = { role = 'assistant', content = 'follow tail', outcome = 'conflict' }
  vim.api.nvim_set_current_win(source_win)
  change()
  assert(bottom() and vim.api.nvim_get_current_win() == source_win, 'tail did not follow without focus change')
  assert(text():find('[競合]', 1, true) and text():find('[適用済み]', 1, true))
  -- Same reference/count with edited entry must not be silently cached.
  history[1].content = 'edited first entry'
  history[1].file = 'changed.lua'
  change()
  assert(text():find('edited first entry', 1, true) and text():find('changed.lua', 1, true))
  history[1] = { role = 'assistant', content = 'replaced entry', outcome = 'cancelled' }
  change()
  assert(text():find('replaced entry', 1, true) and text():find('[中止]', 1, true))
  chat.hide()
  before = tick()
  history[#history + 1] = { role = 'assistant', content = 'hidden tail' }
  elapsed = 3000
  change()
  assert(tick() == before and not text():find('hidden tail', 1, true), 'hidden repaint')
  assert(not chat.visible() and vim.api.nvim_get_current_win() == source_win)
  chat.open(config)
  win = vim.api.nvim_get_current_win()
  assert(bottom() and text():find('hidden tail', 1, true))
  -- Reset uses a new history object; truncation and empty state also repaint.
  session = { history = { { role = 'user', content = 'fresh session' } }, last_status = 'done' }
  change()
  assert(text():find('fresh session', 1, true) and not text():find('hidden tail', 1, true))
  assert(not text():find('状態:', 1, true))
  -- Latest means the last wrapped display segment, not the start of its logical line.
  local wrapped = string.rep('wrapped text ', 500) .. 'END'
  session.history[1].content = wrapped
  change()
  local source_cursor = vim.api.nvim_win_get_cursor(source_win)
  local function wrapped_end()
    local cursor = vim.api.nvim_win_get_cursor(win)
    assert(bottom() and cursor[2] == #wrapped - 1, 'latest did not reach wrapped line end')
    local visible = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    assert(visible.skipcol > 0, 'latest did not reveal final wrapped segment')
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(source_win), source_cursor), 'source cursor moved')
  end
  chat.open(config)
  wrapped_end()
  chat.hide()
  assert(vim.api.nvim_get_current_win() == source_win)
  chat.open(config)
  win = vim.api.nvim_get_current_win()
  wrapped_end()
  session.history[1] = nil
  change()
  assert(text() == 'Enter: 質問 / A: 編集依頼 / ?: ヘルプ')
  before = tick(); change(); assert(tick() == before)
  assert(vim.api.nvim_win_get_cursor(source_win)[1] == 2, 'source cursor moved')
  assert(not vim.bo[buf].modifiable and vim.bo[buf].readonly and vim.bo[buf].undolevels == -1)
  chat.shutdown()
  print('PASS: incremental chat, status-only writes, latest open, reader/tail positions, hidden cache, Markdown, mutation/reset')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
