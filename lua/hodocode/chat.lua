local M = {}
local prep = require('hodocode.prepare')
local uv = vim.uv or vim.loop
local active

local function cleanup(state)
  if state.cleaned then return end
  state.cleaned = true
  if state.file then uv.fs_unlink(state.file) end
  prep.remove_dir(state.dir)
end

function M.stop()
  local state = active
  if not state then return false end
  active = nil
  prep.cancel(state)
  if state.job then pcall(vim.fn.jobstop, state.job) end
  if state.win and vim.api.nvim_win_is_valid(state.win) then pcall(vim.api.nvim_win_close, state.win, true) end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then pcall(vim.api.nvim_buf_delete, state.buf, { force = true }) end
  cleanup(state)
  return true
end

local function context_file(state, encoded)
  state.dir = prep.tempdir()
  if not state.dir then return nil end
  state.file = state.dir .. '/context.json'
  local fd = uv.fs_open(state.file, 'wx', 384)
  if not fd then cleanup(state); return nil end
  local written = uv.fs_write(fd, encoded, 0)
  uv.fs_close(fd)
  if written ~= #encoded then cleanup(state); return nil end
  return state.file
end

function M.open(config)
  if active then prep.notify('チャットは実行中です。:HodoCodeCancelで終了できます'); return false end
  if not prep.argv(config.chat) then prep.notify('chat にCLIアダプターのargvを設定してください'); return false end
  if not vim.tbl_contains(config.chat, '{context}') then
    prep.notify('chat argvには独立した {context} 引数が必要です（準備済みJSONのパスへ置換）'); return false
  end
  local ctx, err = prep.capture(config)
  if not ctx then prep.notify(err); return false end
  local state = { ctx = ctx }
  active = state
  local function fail(message)
    if active == state then M.stop() else cleanup(state) end
    prep.notify(message)
  end
  state.on_error = function() fail('Chat UI or callback failed; session cancelled') end
  prep.guard(state, function()
  prep.run(state, config, ctx, 'Read-only trial: explain only; do not modify files.', function(_, prepare_err, encoded)
    if prepare_err then fail(prepare_err); return end
    if not ctx.valid() or vim.api.nvim_get_current_buf() ~= ctx.buf then fail('対象バッファが変更されました'); return end
    local file = context_file(state, encoded)
    if not file then fail('Private chat context could not be created'); return end
    local argv = vim.deepcopy(config.chat)
    for i, arg in ipairs(argv) do if arg == '{context}' then argv[i] = file end end
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = 'wipe'
    state.win = require('hodocode.ui').open_popup(state.buf,
      'Chat (frozen snapshot ' .. ctx.version:sub(1, 12) .. '; read-only trial)')
    -- A private cwd discourages indexing; this is not a sandbox. The CLI can still read files.
    local ok, job = pcall(vim.fn.termopen, argv, { cwd = state.dir, on_exit = function()
      vim.schedule(function()
        if active == state then M.stop() else cleanup(state) end
      end)
    end })
    if not ok or job <= 0 then fail('Chat CLI could not start'); return end
    state.job = job
    vim.keymap.set('n', 'q', M.stop, { buffer = state.buf, nowait = true })
    vim.api.nvim_create_autocmd('BufWipeout', { buffer = state.buf, once = true, nested = true, callback = function()
      if active == state then M.stop() end
    end })
    vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(state.win), once = true, callback = function()
      if active == state then M.stop() end
    end })
    vim.cmd.startinsert()
  end)
  end)()
  return true
end

return M
