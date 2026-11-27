local M = {}
local history, floats = {}, {}
local labels = {
  idle = '待機中', starting = '開始中', waiting = '応答待ち', received = '応答受信',
  validating = '検証中', applying = '反映中', prompt = '指示入力',
  initializing = '初期化中', connecting = '接続中', streaming = '回答受信中',
  reconnecting = '再接続中', cancelling = '中止応答待ち', permission = '権限確認',
  disconnected = '接続切断', cancel_timeout = '中止応答なし', initialization = '初期化失敗',
  busy = '実行中', outside_root = '対象範囲外',
  pending = '待機中', in_progress = '実行中', failed = '失敗',
  resume_failed = '会話の再接続失敗', resume_unsupported = '会話の再接続非対応',
  done = '完了', completed = '完了', cancelled = '中止', error = '失敗',
  sent = '送信済み', applied = '適用済み', nochange = '変更なし',
  timeout = '時間制限超過', process_exit = '異常終了', invalid_response = '不正な応答',
  size_limit = '出力制限超過', invalid_patch = '不正な変更', version_mismatch = 'バージョン不一致',
  conflict = '競合', provider_exit = '接続先エラー', authentication = '認証エラー',
  configuration_error = '設定エラー', invalid_json = '不正なJSON', rate_limit = '利用制限',
  transport = '通信エラー', spawn_failed = '起動失敗', internal_error = '内部エラー',
}

function M.label(value)
  return labels[value] or '処理中'
end

function M.popup_size()
  return math.max(1, math.min(math.floor(vim.o.columns * 0.9), vim.o.columns - 4)),
    math.max(1, math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - 4))
end

function M.markdown(buf)
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_call(buf, function()
    if vim.b.current_syntax ~= 'markdown' then vim.cmd('runtime! syntax/markdown.vim') end
    vim.cmd('highlight default link markdownCode String')
    vim.cmd('highlight default link markdownCodeBlock String')
  end)
end

local function popup_config()
  local width, height = M.popup_size()
  return {
    relative = 'editor', row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height,
    style = 'minimal', border = 'single',
  }
end

function M.open_popup(buf)
  local win = vim.api.nvim_open_win(buf, true, popup_config())
  if vim.bo[buf].filetype == 'markdown' then
    vim.wo[win].wrap, vim.wo[win].linebreak = true, true
    vim.wo[win].conceallevel, vim.wo[win].concealcursor = 2, 'nc'
  end
  local resize = vim.api.nvim_create_autocmd('VimResized', { callback = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, popup_config()) end
  end })
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    vim.api.nvim_del_autocmd(resize)
  end })
  return win
end

function M.scroll(delta)
  if delta == 0 then return false end
  local win = vim.api.nvim_get_current_win()
  if not vim.tbl_contains(floats, win) then
    win = nil
    for i = #floats, 1, -1 do
      if vim.api.nvim_win_is_valid(floats[i]) then win = floats[i]; break end
    end
  end
  if not win or not vim.api.nvim_win_is_valid(win) then return false end
  vim.api.nvim_win_call(win, function()
    local key = delta < 0 and '<C-y>' or '<C-e>'
    vim.cmd('normal! ' .. math.abs(delta) .. vim.api.nvim_replace_termcodes(key, true, false, true))
  end)
  return true
end

function M.float(lines, title, context)
  local source_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  M.markdown(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = M.open_popup(buf, title)
  if context then
    local watch = vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufReadPost', 'BufDelete' }, {
      buffer = context.buf, nested = true, callback = function(event)
        if (event.event == 'BufDelete' or not context.valid()) and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
      pcall(vim.api.nvim_del_autocmd, watch)
    end })
  end
  floats[#floats + 1] = win
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    for i, owned in ipairs(floats) do
      if owned == win then table.remove(floats, i); break end
    end
  end })
  for _, key in ipairs({ 'q', '<Esc>', '<C-c>', '<C-d>' }) do
    vim.keymap.set('n', key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      if vim.api.nvim_win_is_valid(source_win) then vim.api.nvim_set_current_win(source_win) end
      if key == '<C-c>' or key == '<C-d>' then require('hodocode.mode').stop() end
    end, { buffer = buf })
  end
  vim.keymap.set('n', '[', function() M.scroll(-1) end, { buffer = buf })
  vim.keymap.set('n', ']', function() M.scroll(1) end, { buffer = buf })
  return buf, win
end

function M.target(root, f)
  if not f or not f.File or not f.Line then return nil, '移動先の定義がありません' end
  local path = vim.fs.normalize(root .. '/' .. f.File)
  local real = (vim.uv or vim.loop).fs_realpath(path)
  local base = (vim.uv or vim.loop).fs_realpath(root)
  if not real or not base or real:sub(1, #base + 1) ~= base .. '/' then
    return nil, 'project outside target rejected'
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified and (vim.uv or vim.loop).fs_realpath(vim.api.nvim_buf_get_name(buf)) == real then
      return nil, '移動先に未保存の変更があります。保存して再解析してください'
    end
  end
  return real
end

function M.jump(root, f)
  local real, err = M.target(root, f)
  if not real then
    vim.notify('HodoCode: ' .. err, vim.log.levels.ERROR)
    return false
  end
  local mode = require('hodocode.mode')
  local active = mode.active()
  local previous = { buf = vim.api.nvim_get_current_buf(), path = vim.api.nvim_buf_get_name(0), view = vim.fn.winsaveview() }
  local source = previous.path ~= '' and vim.bo.buftype == '' and vim.api.nvim_win_get_config(0).relative == ''
  local ok, failure = pcall(function()
    vim.cmd("normal! m'")
    if (vim.uv or vim.loop).fs_realpath(vim.api.nvim_buf_get_name(0)) ~= real then
      vim.cmd.edit(vim.fn.fnameescape(real))
    end
    vim.api.nvim_win_set_cursor(0, { f.Line, 0 })
  end)
  if active then mode.start() end
  if not ok then
    vim.notify('HodoCode: ' .. tostring(failure), vim.log.levels.ERROR)
    return false
  end
  if source then history[#history + 1] = previous end
  return true
end

function M.back()
  local mode = require('hodocode.mode')
  local active = mode.active()
  for i = #history, 1, -1 do
    local saved = history[i]
    local buf = saved.buf
    if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= saved.path then
      buf = nil
      if saved.path ~= '' and vim.fn.filereadable(saved.path) == 1 then buf = vim.fn.bufadd(saved.path) end
    end
    if buf then
      local ok, err = pcall(function()
        vim.cmd("normal! m'")
        if vim.api.nvim_get_current_buf() ~= buf then vim.cmd.buffer(buf) end
        vim.fn.winrestview(saved.view)
      end)
      if active then mode.start() end
      if not ok then
        vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR)
        return false
      end
      for j = #history, i, -1 do history[j] = nil end
      return true
    end
  end
  return false
end

return M
