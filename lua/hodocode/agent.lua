local M = {}
local ui = require('hodocode.ui')
local prepare = require('hodocode.prepare')
local uv = vim.uv or vim.loop
local active, snapshots, views, undo_eol = nil, {}, {}, {}

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

local function cancel(state)
  state.cancelled = true
  if active == state then active = nil end
  if state.process then state.process:kill(15) end
  prepare.clean_cwd(state)
end

function M.stop()
  if not active then return end
  local state = active
  cancel(state)
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { 'エージェント要求を中止しました。' })
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
  state.buf = output_buf
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
  local function stream(field)
    return function(err, chunk)
      if err then state.failure = 'エージェント出力を読み取れません' end
      if chunk then
        state[field] = state[field] .. chunk
        if #state[field] > config.max_agent_bytes then
          state[field] = state[field]:sub(1, config.max_agent_bytes)
          state.failure = 'エージェント出力がサイズ制限を超えています'
          if state.process then state.process:kill(15) end
        end
      end
    end
  end
  local ok, process = pcall(vim.system, config.agent, {
    cwd = state.cwd, stdin = payload .. '\n', text = true,
    timeout = config.agent_timeout_ms, stdout = stream('output'), stderr = stream('stderr'),
  }, vim.schedule_wrap(function(result)
    prepare.clean_cwd(state)
    if state.cancelled then return end
    if active == state then active = nil end
    if not vim.api.nvim_win_is_valid(output_win) then return end
    if state.failure or result.code ~= 0 then
      local message = state.failure or ('agent exited (' .. tostring(result.code) .. ')')
      render({ message }); error_message(message); return
    end
    local decoded, response = pcall(vim.json.decode, state.output)
    if not decoded or type(response) ~= 'table' or type(response.message) ~= 'string'
      or response.message:find('\0', 1, true)
      or (response.content ~= nil and type(response.content) ~= 'string') then
      render({ '不正なエージェント応答です。messageと任意のcontentを含むJSONが必要です。' }); return
    end
    local lines = vim.split(response.message, '\n', { plain = true })
    if response.content ~= nil then
      if not supported(response.content) then render({ '不正な変更です。UTF-8とunix/dos改行のみ対応しています' }); return end
      if not ctx.valid() then
        lines[#lines + 1] = '競合: 実行中にバッファまたはファイルが変更されたため、変更を適用していません。'
      else
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
          lines[#lines + 1] = 'バッファへ反映しました（未保存）。qで戻り、:HodoCodeDiffで保存済み内容との差分を確認できます。'
        end
      end
    end
    render(lines)
  end))
  if not ok then cancel(state); error_message('エージェントを起動できません'); return end
  state.process = process
  if state.failure or state.cancelled then process:kill(15) end
end

function M.run(config, prompt)
  if active then error_message('エージェントは実行中です。:HodoCodeCancelで中止できます'); return end
  if not prepare.argv(config.agent) then
    error_message('AI接続先が未設定です。setup({ agent = { 実行ファイル, 引数... } })でJSONアダプターを指定してください'); return
  end
  local ctx, err = capture()
  if not ctx then error_message(err); return end
  local state = { output = '', stderr = '', cancelled = false }
  active = state
  if not prompt or prompt == '' then
    vim.ui.input({ prompt = 'HodoCode エージェントへの指示: ' }, function(value)
      if state.cancelled then return end
      if not value or value == '' then cancel(state); return end
      launch(config, value, state, ctx)
    end)
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
