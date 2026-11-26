local M = {}
local view = { config = {} }
local group
local labels = {
  idle = '待機中', starting = '起動中', waiting = '応答待ち', validating = '検証中',
  done = '完了', completed = '完了', cancelled = '中止', error = '失敗',
  sent = '送信済み', applied = '適用済み', nochange = '変更なし',
  timeout = '時間制限超過', process_exit = '異常終了', invalid_response = '不正な応答',
  size_limit = '出力制限超過', invalid_patch = '不正な変更', version_mismatch = 'バージョン不一致',
  conflict = '競合', provider_exit = '接続先エラー', authentication = '認証エラー',
  configuration_error = '設定エラー', invalid_json = '不正なJSON', rate_limit = '利用制限',
  transport = '通信エラー', spawn_failed = '起動失敗', internal_error = '内部エラー',
}

local function valid_source(target)
  return target and target.buf and vim.api.nvim_buf_is_valid(target.buf)
    and vim.bo[target.buf].buftype == ''
end

local function capture()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype == '' and vim.api.nvim_win_get_config(win).relative == '' then
    return { buf = buf, win = win, cursor = vim.api.nvim_win_get_cursor(win) }
  end
end

function M.source()
  if not valid_source(view.source) then return nil end
  local source = vim.deepcopy(view.source)
  if source.win and vim.api.nvim_win_is_valid(source.win)
    and vim.api.nvim_win_get_buf(source.win) == source.buf then
    source.cursor = vim.api.nvim_win_get_cursor(source.win)
  end
  return source
end

function M.is_view(buf)
  return view.buf ~= nil and view.buf == buf
end

function M.visible()
  return view.win ~= nil and vim.api.nvim_win_is_valid(view.win)
end

function M.hide()
  local win = view.win
  local focused = M.visible() and vim.api.nvim_get_current_win() == win
  view.win = nil
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  local source = M.source()
  if focused and source and source.win and vim.api.nvim_win_is_valid(source.win)
    and vim.api.nvim_win_get_buf(source.win) == source.buf then
    vim.api.nvim_set_current_win(source.win)
  end
  return win ~= nil
end
M.stop = M.hide

local function append(lines, text)
  for _, line in ipairs(vim.split(tostring(text or ''), '\n', { plain = true })) do
    lines[#lines + 1] = line
  end
end

function M.render(force)
  if not view.buf or not vim.api.nvim_buf_is_valid(view.buf) or (force ~= true and not M.visible()) then return end
  local session = require('hodocode.session').get()
  local lines = { '# HodoCode 会話', '',
    'Enter/i: 質問（読み取り専用） | A: 編集依頼 | x: 実行中の依頼を中止',
    '入力: Ctrl-s/Ctrl-Enterで送信 | Esc/q: 会話を隠す',
    '質問への回答は送信時点のコードに基づきます（送信後の変更は含みません）。', '' }
  if type(view.config.agent) ~= 'table' or #view.config.agent == 0 then
    lines[#lines + 1] = '設定: 質問・編集依頼には `agent` にコマンドと引数を設定してください。'
    lines[#lines + 1] = ''
  end
  local request = session.request
  local status = request and require('hodocode.agent').status(request.source) or session.last_status
  if type(status) == 'table' then
    lines[#lines + 1] = ('状態: %s（経過 %.0f秒）%s'):format(labels[status.phase or 'idle'] or '処理中',
      (status.elapsed_ms or 0) / 1000, status.code and (' [' .. (labels[status.code] or '失敗') .. ']') or '')
  else
    lines[#lines + 1] = '状態: ' .. (labels[status or (request and request.phase) or 'idle'] or '処理中')
  end
  for _, entry in ipairs(session.history or {}) do
    lines[#lines + 1] = ''
    lines[#lines + 1] = '## ' .. (entry.role == 'user' and 'あなた' or 'アシスタント')
    if entry.intent or entry.file then
      local intent = entry.intent == 'edit' and '編集依頼' or entry.intent == 'chat' and '質問' or nil
      lines[#lines + 1] = table.concat(vim.tbl_filter(function(value) return value ~= '' end,
        { intent or '', entry.file and ('対象: ' .. entry.file) or '' }), ' | ')
    end
    append(lines, entry.content or entry.message)
    local outcome = entry.outcome or entry.status
    if outcome then lines[#lines + 1] = '[' .. (labels[outcome] or '失敗') .. ']' end
  end
  vim.bo[view.buf].readonly, vim.bo[view.buf].modifiable = false, true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].readonly, vim.bo[view.buf].modifiable = true, false
  vim.bo[view.buf].modified = false
end

local function compose(intent)
  require('hodocode.edit_prompt').open(function(prompt)
    local target = M.source()
    if not target then
      vim.notify('HodoCode: 有効なソースバッファがありません', vim.log.levels.ERROR)
      return
    end
    require('hodocode.agent').run(view.config, prompt, intent, target)
  end)
end

local function setup()
  if group then return end
  group = vim.api.nvim_create_augroup('HodoCodeConversation', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'HodoCodeSessionChanged', callback = M.render,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.shutdown })
end

function M.configure(config)
  view.config = config or {}
  M.render()
end

function M.open(config, target)
  setup()
  if config then M.configure(config) end
  local source = target or capture()
  if valid_source(source) then view.source = vim.deepcopy(source) end
  if not view.buf or not vim.api.nvim_buf_is_valid(view.buf) then
    view.buf = vim.api.nvim_create_buf(false, true)
    local buf = view.buf
    vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'hide', 'markdown'
    vim.bo[buf].swapfile, vim.bo[buf].readonly, vim.bo[buf].undolevels = false, true, -1
    for _, key in ipairs({ 'q', '<Esc>', '<C-c>', '<C-d>' }) do
      vim.keymap.set('n', key, function()
        M.hide()
        if key == '<C-c>' or key == '<C-d>' then require('hodocode.mode').stop() end
      end, { buffer = buf, nowait = true, silent = true })
    end
    for _, key in ipairs({ '<CR>', 'i' }) do
      vim.keymap.set('n', key, function() compose('chat') end, { buffer = buf, silent = true })
    end
    vim.keymap.set('n', 'A', function() compose('edit') end, { buffer = buf, silent = true })
    vim.keymap.set('n', 'x', function() require('hodocode').cancel() end, { buffer = buf, silent = true })
    vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
      if view.buf == buf then view.buf = nil; view.win = nil end
    end })
  end
  M.render(true)
  if M.visible() then
    vim.api.nvim_set_current_win(view.win)
  else
    local win = require('hodocode.ui').open_popup(view.buf, 'HodoCode 会話')
    view.win = win
    vim.wo[win].wrap = true
    vim.api.nvim_create_autocmd('WinClosed', {
      group = group, pattern = tostring(win), once = true, callback = function()
        if view.win == win then view.win = nil end
      end,
    })
  end
  return true
end

function M.shutdown()
  M.hide()
  if view.buf and vim.api.nvim_buf_is_valid(view.buf) then
    vim.api.nvim_buf_delete(view.buf, { force = true })
  end
  view = { config = {} }
  if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
end

return M
