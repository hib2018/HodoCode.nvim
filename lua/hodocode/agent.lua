local M = {}
local ui = require('hodocode.ui')
local prepare = require('hodocode.prepare')
local events = require('hodocode.edit_events')
local uv = vim.uv or vim.loop
local active, snapshots, views, undo_eol = nil, {}, {}, {}
local statuses = {}

local restoring_eol = false
vim.api.nvim_create_autocmd('OptionSet', { pattern = 'endofline', callback = function()
  if restoring_eol then return end
  -- OptionSet has no target buffer for every API caller; invalidate conservatively.
  for _, record in pairs(undo_eol) do record.values = {} end
end })

local function track_eol(buf, before_seq, before_eol, after_seq, after_eol)
  if not undo_eol[buf] then
    undo_eol[buf] = { values = {}, expected = after_eol }
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        -- Undo restores text, but Neovim does not restore the endofline option.
        vim.schedule(function()
          local record = undo_eol[buf]
          if not vim.api.nvim_buf_is_valid(buf) or not record then return end
          if vim.bo[buf].endofline ~= record.expected then record.values = {}; return end
          vim.api.nvim_buf_call(buf, function()
            local eol = record.values[vim.fn.undotree().seq_cur]
            if eol ~= nil then
              restoring_eol = true
              vim.bo[buf].endofline = eol
              restoring_eol = false
              record.expected = eol
            end
          end)
        end)
      end,
      on_detach = function() undo_eol[buf] = nil end,
    })
  end
  local record = undo_eol[buf]
  record.values[before_seq], record.values[after_seq] = before_eol, after_eol
  record.expected = after_eol
end

local function error_message(message)
  vim.notify('HodoCode: ' .. message, vim.log.levels.ERROR)
end

local function stamp(stat)
  if not stat then return '' end
  return table.concat({ stat.type, stat.dev, stat.ino, stat.mode, stat.size,
    stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':')
end

local function supported(bytes)
  local without_crlf = bytes:gsub('\r\n', '')
  if bytes:find('\0', 1, true) or without_crlf:find('\r', 1, true)
    or (bytes:find('\r\n', 1, true) and without_crlf:find('\n', 1, true)) then return false end
  local i = 1
  while i <= #bytes do
    local a, b = bytes:byte(i, i + 1)
    local size = a < 128 and 1 or (a >= 194 and a <= 223 and 2)
      or (a >= 224 and a <= 239 and 3) or (a >= 240 and a <= 244 and 4)
    if not size then return false end
    for offset = 1, size - 1 do
      local value = bytes:byte(i + offset)
      if not value or value < 128 or value > 191 then return false end
    end
    if (a == 224 and b < 160) or (a == 237 and b >= 160)
      or (a == 240 and b < 144) or (a == 244 and b >= 144) then return false end
    i = i + size
  end
  return true
end

local function supported_buffer(buf)
  return (vim.bo[buf].fileencoding == '' or vim.bo[buf].fileencoding:lower() == 'utf-8')
    and (vim.bo[buf].fileformat == 'unix' or vim.bo[buf].fileformat == 'dos')
end

local function disk(path)
  local link, _, code = uv.fs_lstat(path)
  if not link then
    if code == 'ENOENT' then return { path = path, content = '', identity = 'missing', missing = true } end
    return nil, '保存済みファイルを確認できません'
  end
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return nil, '通常の読み取り可能なファイルが必要です' end
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then return nil, '保存済みファイルを読み取れません' end
  local opened = uv.fs_fstat(fd)
  local bytes = opened and uv.fs_read(fd, opened.size, 0)
  local after = uv.fs_fstat(fd)
  uv.fs_close(fd)
  if not bytes or stamp(stat) ~= stamp(opened) or stamp(opened) ~= stamp(after)
    or stamp(uv.fs_stat(path)) ~= stamp(stat) or stamp(uv.fs_lstat(path)) ~= stamp(link) then
    return nil, '読み取り中にファイルが変更されました'
  end
  if not supported(bytes) then return nil, 'UTF-8（任意のBOM）とunix/dos改行のみ対応しています' end
  return { path = path, content = bytes, identity = stamp(link) .. '/' .. stamp(stat) }
end

local function logical(bytes)
  local bom = bytes:sub(1, 3) == '\239\187\191'
  if bom then bytes = bytes:sub(4) end
  local format = bytes:find('\r\n', 1, true) and 'dos' or 'unix'
  bytes = bytes:gsub('\r\n', '\n')
  local eol = bytes:sub(-1) == '\n'
  local lines = vim.split(bytes, '\n', { plain = true })
  if eol then table.remove(lines) end
  if #lines == 0 then lines = { '' } end
  return { lines = lines, endofline = eol, fileformat = format, bomb = bom }
end

local option_names = { 'buftype', 'modifiable', 'readonly', 'endofline', 'fileformat', 'bomb',
  'fileencoding', 'fixendofline', 'binary', 'filetype', 'modified' }
local function options(buf)
  local result = {}
  for _, name in ipairs(option_names) do result[name] = vim.bo[buf][name] end
  return result
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

local function capture()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or path == '' or not vim.bo[buf].modifiable then
    return nil, '編集可能な通常のファイルバッファで実行してください'
  end
  if not supported_buffer(buf) or not supported(text(buf)) then
    return nil, 'UTF-8（任意のBOM）とunix/dos改行のみ対応しています'
  end
  local saved, err = disk(path)
  if not saved then return nil, err end
  local ctx = { buf = buf, win = vim.api.nvim_get_current_win(), path = path, saved = saved, content = text(buf),
    options = options(buf), tick = vim.api.nvim_buf_get_changedtick(buf), cursor = vim.api.nvim_win_get_cursor(0) }
  function ctx.valid()
    if not vim.api.nvim_win_is_valid(ctx.win) or vim.api.nvim_win_get_buf(ctx.win) ~= buf
      or not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= path
      or vim.api.nvim_buf_get_changedtick(buf) ~= ctx.tick or not vim.deep_equal(options(buf), ctx.options) then return false end
    local now = disk(path)
    return now and now.identity == saved.identity and now.content == saved.content
  end
  return ctx
end

local function elapsed(state)
  return state.started and math.floor((uv.hrtime() - state.started) / 1000000) or 0
end

local function status(state, phase, running, code)
  local changed = state.phase ~= phase or state.running ~= running or state.code ~= code
  state.phase, state.running, state.code = phase, running, code
  if state.started and vim.api.nvim_buf_is_valid(state.source) then
    statuses[state.source] = { phase = phase, elapsed_ms = elapsed(state), running = running, code = code }
  end
  if changed then
    vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeAgentStatus',
      data = { buf = state.source, phase = phase, running = running } })
  end
end

function M.status(buf)
  if active and active.started and active.source == buf then
    return { phase = active.phase, elapsed_ms = elapsed(active), running = active.running, code = active.code }
  end
  return statuses[buf] and vim.deepcopy(statuses[buf]) or nil
end

local function finish_status(state, code)
  if state.timer then state.timer:stop(); state.timer:close(); state.timer = nil end
  local phase = code == 'cancelled' and 'cancelled' or (code and 'error' or 'done')
  if active == state then active = nil end
  status(state, phase, false, code)
end

local failures = {
  timeout = '応答が時間制限を超えました。要求を短くするか制限時間を増やして再実行してください。',
  cancelled = 'エージェント要求を中止しました。必要なら再実行してください。',
  process_exit = 'エージェントが異常終了しました。接続先の設定を確認して再実行してください。',
  invalid_response = '不正なエージェント応答です。JSON/NDJSON形式を確認してください。',
  size_limit = 'エージェント出力がサイズ制限を超えています。要求を小さくしてください。',
  invalid_patch = '不正な変更です。変更を適用せず終了しました。再実行してください。',
  version_mismatch = '応答のバージョンが要求と一致しません。変更せず終了しました。再実行してください。',
  conflict = '競合: 対象バッファまたはファイルが変更されたため、変更を適用していません。再実行してください。',
  provider_exit = 'AI接続先でエラーが発生しました。接続設定を確認して再実行してください。',
  authentication = 'AI接続先の認証設定を確認して再実行してください。',
  configuration_error = 'エージェントの設定を確認して再実行してください。',
  invalid_json = '不正なJSON応答です。エージェントの出力形式を確認して再実行してください。',
  rate_limit = 'AI接続先の利用制限です。時間をおいて再実行してください。',
  transport = 'AI接続先との通信に失敗しました。接続を確認して再実行してください。',
  spawn_failed = 'エージェントを起動できません。実行ファイルの設定を確認してください。',
  internal_error = 'エージェント内部エラーです。設定を確認して再実行してください。',
}
local function failure_text(state, code, detail)
  local message = failures[code] or failures.process_exit
  if code == 'invalid_patch' and type(detail) == 'string' then message = message .. ' ' .. detail end
  return message .. ('（経過 %.1f秒）'):format(elapsed(state) / 1000)
end

local function cancel(state, code)
  state.cancelled = true
  finish_status(state, code or 'cancelled')
  local close = state.prompt_close
  state.prompt_close = nil
  if close then close() end
  if state.process then state.process:kill(15) end
  prepare.clean_cwd(state)
end

function M.stop()
  if not active then return end
  local state = active
  cancel(state)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { failure_text(state, 'cancelled') })
    vim.bo[state.buf].modifiable = false
  end
end

local function launch(config, prompt, state, ctx)
  if state.cancelled or active ~= state then return end
  if vim.api.nvim_get_current_buf() ~= ctx.buf or not ctx.valid() then
    cancel(state); error_message('競合: 対象バッファまたはファイルが変更されました。再実行してください'); return
  end
  local payload = vim.json.encode({ prompt = prompt, buffer = {
    path = ctx.path, content = ctx.content, modified = ctx.options.modified,
    filetype = ctx.options.filetype, cursor = ctx.cursor,
  } })
  if #payload > config.max_agent_bytes then cancel(state); error_message('送信サイズ制限を超えています'); return end
  state.cwd = prepare.tempdir()
  if not state.cwd then cancel(state); error_message('専用作業ディレクトリを作成できません'); return end
  local output_buf, output_win = ui.float({ '# エージェント', '', '実行中…' }, 'HodoCode エージェント')
  state.buf, state.source, state.started = output_buf, ctx.buf, uv.hrtime()
  if not statuses[ctx.buf] then
    vim.api.nvim_create_autocmd('BufWipeout', { buffer = ctx.buf, once = true, callback = function() statuses[ctx.buf] = nil end })
  end
  local function closed()
    if active == state then cancel(state) end
  end
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(output_win), once = true, callback = closed })
  vim.api.nvim_create_autocmd('BufWipeout', { buffer = output_buf, once = true, callback = closed })
  local function render(lines)
    if vim.api.nvim_buf_is_valid(output_buf) then
      vim.bo[output_buf].modifiable = true
      vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
      vim.bo[output_buf].modifiable = false
    end
  end
  local labels = { starting = '開始中', waiting = '応答待ち', received = '応答受信', validating = '変更を検証中' }
  local function progress()
    if state.running and not state.cancelled then
      render({ '# エージェント', '', ('実行中… %s（経過 %.1f秒）'):format(labels[state.phase] or '応答待ち', elapsed(state) / 1000) })
    end
  end
  status(state, 'starting', true)
  if state.cancelled or active ~= state then return end
  state.timer = uv.new_timer()
  state.timer:start(1000, 1000, vim.schedule_wrap(progress))
  local parser = events.new(config.max_agent_bytes, function(phase)
    vim.schedule(function()
      if active == state and state.running and not state.cancelled then status(state, phase, true); progress() end
    end)
  end)
  local bytes = 0
  local function stream(stdout)
    return function(err, chunk)
      if err then state.failure = 'process_exit' end
      if chunk then
        bytes = bytes + #chunk
        if bytes > config.max_agent_bytes then state.failure = 'size_limit'
        elseif stdout then
          local _, parse_error = parser:feed(chunk)
          if parse_error then state.failure = parse_error end
        end
        if state.failure and state.process then state.process:kill(15) end
      end
    end
  end
  local ok, process = pcall(vim.system, config.agent, {
    cwd = state.cwd, stdin = payload .. '\n', text = true,
    timeout = config.agent_timeout_ms, env = {
      HODOCODE_AGENT_TIMEOUT_MS = tostring(config.agent_timeout_ms), HODOCODE_EDIT_PROTOCOL = '2',
    },
    stdout = stream(true), stderr = stream(false),
  }, vim.schedule_wrap(function(result)
    prepare.clean_cwd(state)
    if state.cancelled then return end
    local response, parse_error = parser:finish()
    local code = state.failure
    if result.code == 124 or (result.signal and result.signal ~= 0 and elapsed(state) >= config.agent_timeout_ms) then code = 'timeout' end
    if not code and response and response.event == 'error' then code = response.code end
    if not code and result.code ~= 0 then code = 'process_exit' end
    if not code then code = parse_error end
    local function fail(reason, detail)
      local message = failure_text(state, reason, detail)
      finish_status(state, reason)
      render({ message }); error_message(message)
    end
    if code then fail(code); return end
    if not vim.api.nvim_win_is_valid(output_win) then finish_status(state, 'cancelled'); return end
    status(state, 'validating', true)
    if state.cancelled or active ~= state then return end
    if response.version ~= nil and response.version ~= vim.fn.sha256(ctx.content) then fail('version_mismatch'); return end
    if response.edits ~= nil then
      local content, patch_error = require('hodocode.edit_patch').apply(ctx.content, response.edits, config.max_agent_bytes)
      if not content or patch_error then fail('invalid_patch', patch_error); return end
      response.content = content
    end
    if not ctx.valid() then fail('conflict'); return end
    if response.content ~= nil and not supported(response.content) then fail('invalid_patch'); return end
    local lines = vim.split(response.message, '\n', { plain = true })
    if response.content ~= nil then
      if not ctx.valid() then fail('conflict'); return end
      local replacement = logical(response.content)
      local changed = not vim.deep_equal(replacement.lines, vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false))
        or replacement.endofline ~= vim.bo[ctx.buf].endofline
      if changed then
        vim.api.nvim_buf_call(ctx.buf, function()
          -- Break the undo block without discarding the user's earlier unsaved edits.
          vim.cmd('let &l:undolevels = &l:undolevels')
          local before_seq, before_eol = vim.fn.undotree().seq_cur, vim.bo[ctx.buf].endofline
          vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, replacement.lines)
          restoring_eol = true
          vim.bo[ctx.buf].endofline = replacement.endofline
          restoring_eol = false
          track_eol(ctx.buf, before_seq, before_eol, vim.fn.undotree().seq_cur, replacement.endofline)
        end)
        if not snapshots[ctx.buf] then
          vim.api.nvim_create_autocmd('BufWipeout', { buffer = ctx.buf, once = true, callback = function() snapshots[ctx.buf] = nil end })
        end
        snapshots[ctx.buf] = ctx.saved
        require('hodocode.edit_marks').set(ctx.buf, ctx.content, text(ctx.buf))
        finish_status(state)
        local focused = vim.api.nvim_get_current_win() == output_win
        if vim.api.nvim_win_is_valid(output_win) then vim.api.nvim_win_close(output_win, true) end
        if focused and vim.api.nvim_win_is_valid(ctx.win) then vim.api.nvim_set_current_win(ctx.win) end
        vim.cmd.redraw()
        vim.notify('HodoCode: バッファを更新しました（未保存）。🤖が変更行です。dで差分を確認できます。')
        return
      end
    end
    finish_status(state)
    render(lines)
  end))
  if not ok then
    local message = failure_text(state, 'spawn_failed')
    cancel(state, 'spawn_failed'); render({ message }); error_message(message); return
  end
  state.process = process
  if active == state and state.running and state.phase == 'starting' then status(state, 'waiting', true) end
  if state.failure or state.cancelled then process:kill(15) end
end

function M.run(config, prompt)
  if active then error_message('エージェントは実行中です。:HodoCodeCancelで中止できます'); return end
  if not prepare.argv(config.agent) then
    error_message('AI接続先が未設定です。setup({ agent = { 実行ファイル, 引数... } })でJSONアダプターを指定してください'); return
  end
  local ctx, err = capture()
  if not ctx then error_message(err); return end
  local state = { cancelled = false, source = ctx.buf }
  active = state
  if not prompt or prompt == '' then
    local _, _, close = require('hodocode.edit_prompt').open(function(value)
      if state.cancelled then return end
      state.prompt_close = nil
      launch(config, value, state, ctx)
    end, function()
      if not state.cancelled then cancel(state) end
    end)
    state.prompt_close = close
  else
    launch(config, prompt, state, ctx)
  end
end

local function metadata(value)
  return value.fileformat .. ', EOL=' .. tostring(value.endofline) .. ', BOM=' .. tostring(value.bomb)
end

function M.diff()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' or vim.bo[buf].buftype ~= '' then error_message('通常の名前付きファイルバッファで実行してください'); return end
  if not supported_buffer(buf) or not supported(text(buf)) then
    error_message('UTF-8（任意のBOM）とunix/dos改行のみ対応しています'); return
  end
  local snapshot, err = snapshots[buf]
  if snapshot and snapshot.path ~= path then snapshot = nil end
  local request_baseline = snapshot ~= nil
  if not snapshot then snapshot, err = disk(path) end
  if not snapshot then error_message(err); return end
  if views[buf] then views[buf]() end
  local saved = logical(snapshot.content)
  local before = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(before, 'hodocode://saved/' .. before .. '/' .. path)
  vim.api.nvim_buf_set_lines(before, 0, -1, false, saved.lines)
  vim.bo[before].filetype = vim.bo[buf].filetype
  vim.bo[before].endofline = saved.endofline
  vim.bo[before].fileformat = saved.fileformat
  vim.bo[before].bomb = saved.bomb
  vim.bo[before].bufhidden = 'wipe'
  vim.bo[before].modifiable = false
  vim.bo[before].readonly = true
  local original_winbar = vim.wo.winbar
  vim.cmd('tab split')
  local left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left, before)
  vim.cmd.diffthis()
  vim.cmd('rightbelow vsplit')
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right, buf)
  vim.cmd.diffthis()
  local function labels()
    if vim.api.nvim_win_is_valid(left) then
      local label = request_baseline and '保存済み（要求開始時）: ' or '保存済み（diff表示時）: '
      vim.wo[left].winbar = (label .. path .. (snapshot.missing and ' (new file, empty)' or '') .. ' [' .. metadata(saved) .. ']'):gsub('%%', '%%%%')
    end
    if vim.api.nvim_win_is_valid(right) then
      vim.wo[right].winbar = ('現在のバッファ: ' .. path .. ' [' .. metadata(options(buf)) .. ']'):gsub('%%', '%%%%')
    end
  end
  labels()
  local hooks, closing = {}, nil
  local function clean_hooks()
    for _, hook in ipairs(hooks) do pcall(vim.api.nvim_del_autocmd, hook) end
    hooks = {}
  end
  local function close()
    if closing then return end
    closing = true
    views[buf] = nil
    clean_hooks()
    for _, win in ipairs({ right, left }) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_call(win, function() vim.cmd('diffoff') end)
        vim.wo[win].winbar = original_winbar
        local only_dirty_view = win == right and vim.api.nvim_buf_is_valid(buf)
          and vim.bo[buf].modified and #vim.fn.win_findbuf(buf) == 1
        local expected = win == right and buf or before
        if vim.api.nvim_win_get_buf(win) == expected and not only_dirty_view then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    if vim.api.nvim_buf_is_valid(before) then pcall(vim.api.nvim_buf_delete, before, { force = true }) end
  end
  views[buf] = close
  vim.keymap.set('n', 'q', close, { buffer = before, nowait = true })
  hooks[#hooks + 1] = vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'OptionSet' }, { callback = function()
    if vim.api.nvim_buf_is_valid(buf) then labels() end
  end })
  hooks[#hooks + 1] = vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(right), once = true, callback = function() clean_hooks(); vim.schedule(close) end })
  hooks[#hooks + 1] = vim.api.nvim_create_autocmd('BufWipeout', { buffer = before, once = true, callback = function() clean_hooks(); vim.schedule(close) end })
  hooks[#hooks + 1] = vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufFilePost' }, { buffer = buf, once = true, callback = function() clean_hooks(); vim.schedule(close) end })
end

return M
