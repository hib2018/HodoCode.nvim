local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.lines, vim.o.columns = true, 45, 140
  local prompt, ui = require('hodocode.edit_prompt'), require('hodocode.ui')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved source' })
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local events = { 'WinClosed', 'VimResized' }
  local baseline = #vim.api.nvim_get_autocmds({ event = events })
  local function key(buf, mode, lhs)
    local map = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(lhs, mode, false, true) end)
    assert(map.callback, 'missing mapping: ' .. mode .. ' ' .. lhs)
    map.callback()
  end
  local function geometry(win)
    local width, height = ui.popup_size()
    local cfg = vim.api.nvim_win_get_config(win)
    assert(cfg.relative == 'editor' and cfg.width == width and cfg.height == height)
    assert(cfg.col == math.max(0, math.floor((vim.o.columns - width) / 2)))
    assert(cfg.row == math.max(0, math.floor((vim.o.lines - height) / 2) - 1))
    assert(not cfg.title or #cfg.title == 0, 'prompt must not have a decorative title')
    assert(vim.deep_equal(cfg.border, { '┌', '─', '┐', '│', '┘', '─', '└', '│' }))
    if vim.fn.has('nvim-0.10') == 1 then
      assert(cfg.footer[1][1] == ' Ctrl-s:送信 Esc:取消 ', 'missing concise input hint')
    end
  end
  local submitted, cancelled = {}, 0
  local function cancel() cancelled = cancelled + 1 end
  local buf, win, close
  buf, win, close = prompt.open(function(text)
    assert(not vim.api.nvim_win_is_valid(win), 'callback before popup closed')
    assert(vim.api.nvim_get_current_win() == source_win, 'source not restored')
    submitted[#submitted + 1] = text
  end, cancel)
  geometry(win)
  assert(vim.bo[buf].modifiable and vim.bo[buf].buftype == 'nofile'
    and vim.bo[buf].bufhidden == 'wipe' and vim.bo[buf].filetype == 'text')
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { '' }))
  assert(vim.fn.maparg('<CR>', 'i') == '', 'insert Enter must remain a newline')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ' ', '\t' })
  key(buf, 'n', '<CR>')
  assert(vim.api.nvim_win_is_valid(win) and #submitted == 0 and cancelled == 0)
  vim.o.lines, vim.o.columns = 30, 100
  vim.api.nvim_exec_autocmds('VimResized', {})
  geometry(win)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ' first line', '', 'second line ' })
  key(buf, 'i', '<C-s>')
  assert(not vim.api.nvim_win_is_valid(win))
  assert(vim.deep_equal(submitted, { ' first line\n\nsecond line ' }))
  close(); assert(cancelled == 0)
  for _, mapping in ipairs({ { 'n', 'q' }, { 'n', '<Esc>' }, { 'i', '<Esc>' } }) do
    buf, win, close = prompt.open(function() error('cancel submitted') end, cancel)
    key(buf, mapping[1], mapping[2]); close()
    assert(not vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_win() == source_win)
  end
  assert(cancelled == 3)
  buf, win, close = prompt.open(function() error('external close submitted') end, cancel)
  vim.api.nvim_win_close(win, true)
  close()
  local later_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[later_buf].bufhidden = 'wipe'
  local later_win = ui.open_popup(later_buf, 'Later popup')
  assert(vim.wait(1000, function() return cancelled == 4 end))
  assert(vim.api.nvim_get_current_win() == later_win, 'late cancellation stole focus')
  vim.api.nvim_win_close(later_win, true)
  vim.api.nvim_set_current_win(source_win)
  buf, win, close = prompt.open(function() error('owner close submitted') end, cancel)
  close(); close(); assert(cancelled == 5)
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  buf, win, close = prompt.open(function() error('callback failed') end, cancel)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'edit' })
  key(buf, 'n', '<C-CR>'); close()
  assert(#notices == 1 and notices[1]:find('callback failed', 1, true))
  assert(not vim.api.nvim_buf_is_valid(buf) and cancelled == 5)
  assert(#vim.api.nvim_get_autocmds({ event = events }) == baseline, 'autocmd leak')
  assert(vim.api.nvim_buf_get_changedtick(source) == tick)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), { 'unsaved source' }))
  print('PASS: editable prompt geometry/resize, multiline/blank, submit/cancel/close once, callback cleanup, source untouched')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
