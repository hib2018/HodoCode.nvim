local M = {}
local state
local actions = {
  n = { 'next_call', '現在の関数内の次の呼び出し名へ' }, N = { 'previous_call', '現在の関数内の前の呼び出し名へ' },
  b = { 'back', '直前の読解位置へ戻る' }, g = { 'function_start', '関数先頭' }, G = { 'function_end', '関数末尾' },
  t = { 'calls', 'ツリー' }, e = { 'chat', '同じエージェント会話を開く・再表示' }, i = { 'chat', '同じエージェント会話を開く（eと同じ）' },
  E = { 'explain_now', '現在の関数のAI行解説を生成' }, c = { 'notes_toggle', '行解説表示切替' },
  ['['] = { 'help_up', 'ポップアップを上へスクロール' }, [']'] = { 'help_down', 'ポップアップを下へスクロール' },
  v = { 'exit_mode', '編集へ戻る' },
  f = { 'functions', '関数一覧' }, s = { 'syntax', '構文・関数・変数情報' }, r = { 'reload', '再解析' },
  a = { 'explain_line', 'カーソル行を解説（指示可・空欄で通常解説）' }, A = { 'agent', 'AIでバッファを編集（指示入力）' }, x = { 'cancel', 'AI中止' }, d = { 'diff', '保存済み基準の行直下diffをオン・オフ' },
  ['<CR>'] = { 'follow', '呼び出し先' }, m = { 'graph', '図' },
  z = { 'notes_clear', '注釈消去' }, K = { 'notes_show', '注釈全文' },
  ['?'] = { 'help', '操作一覧' },
}
local sections = {
  { '基本の移動', { 'n', 'N', '<CR>', 'b', 'g', 'G' } },
  { '表示と読解', { 't', 'f', 's', 'm', 'K', 'c', 'z', '[', ']', 'r', '?' } },
  { 'AI', { 'E', 'a', 'A', 'e', 'i', 'x', 'd' } },
  { '終了', { 'v' } },
}
local exits = { ['<Esc>'] = true, q = true, ['<C-c>'] = true, ['<C-d>'] = true }

function M.active()
  return state ~= nil
end

function M.stop()
  if not state then return end
  local current = state
  state = nil
  require('hodocode.marker').stop()
  vim.api.nvim_del_augroup_by_id(current.group)
  if vim.api.nvim_buf_is_valid(current.buf) then
    vim.api.nvim_buf_call(current.buf, function()
      for key, binding in pairs(current.bindings) do
        local mapping = vim.fn.maparg(key, 'n', false, true)
        -- Keep a new mapping installed by the user while the mode was active.
        if mapping.buffer == 1 and mapping.callback == binding.callback then
          vim.keymap.del('n', key, { buffer = current.buf })
          if binding.previous then vim.fn.mapset('n', false, binding.previous) end
        end
      end
    end)
  end
  if current.help and vim.api.nvim_win_is_valid(current.help) then vim.api.nvim_win_close(current.help, true) end
  if current.guide and vim.api.nvim_win_is_valid(current.guide) then vim.api.nvim_win_close(current.guide, true) end
end

function M.help()
  local current = state or {}
  if current.help and vim.api.nvim_win_is_valid(current.help) then vim.api.nvim_set_current_win(current.help); return end
  local lines = {
    '# HodoCode 操作一覧', '',
    '基本: n/N で呼び出し名を選ぶ → Enter で定義へ進む → b で読解履歴を戻る。',
    '以下の専用キーは読解モード中のソース上で有効。h/j/k/l と / 検索はNeovim標準です（? は操作一覧）。',
    '下線は関数名、黄色の強調はジャンプ可能な呼び出し名です。',
    'n/N は現在の関数内だけを移動し、未解決・外部の呼び出し名も含みます。',
    'Enter は確定したローカル定義だけへ移動します。3n などの回数指定も使えます。',
    'g/G はファイルではなく現在の関数の先頭／末尾です。',
    ':HodoCode で分類付きの操作を選択（キー操作はモード中のみ）。',
    '読解: :write → n/N → Enter → b。s は構文・変数情報、m は図。',
    '未保存でも編集・E/a の解説・A のAI編集・d の差分を利用できます。',
    '解析・移動・図は保存済みソース用です。必要なら :write してください。自動保存しません。',
    '会話: e/i → Enterで質問。Aは同じ会話への編集指示。Eは関数全体、aはカーソル行の解説。',
    '編集: A → 🤖 → dで行直下diffを切替 → uでundo／:writeで保存。旧行は実際の行の下に表示。',
    'Esc・画面を閉じる・モード終了でも依頼と履歴は継続。xだけが実行中止（履歴は保持）。',
  }
  for _, section in ipairs(sections) do
    lines[#lines + 1], lines[#lines + 2] = '', '## ' .. section[1]
    for _, key in ipairs(section[2]) do
      lines[#lines + 1] = string.format('  %-8s %s', key == '<CR>' and 'Enter' or key, actions[key][2])
    end
    if section[1] == '終了' then
      lines[#lines + 1] = '  q / Esc / Ctrl+C / Ctrl+D  モード終了（Neovimは終了しない）'
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '?:この操作一覧。操作一覧は q / Esc / ? で閉じてソースへ戻る。Ctrl+C/D はモードも終了。'
  local _, win = require('hodocode.ui').float(lines, 'HodoCode 操作一覧')
  current.help = win
  for _, key in ipairs({ '<Esc>', '?' }) do
    vim.keymap.set('n', key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end, { buffer = vim.api.nvim_win_get_buf(win), nowait = true })
  end
end

function M.actions()
  local win = state and state.win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= '' then
    vim.notify('HodoCode: ソースバッファで実行してください', vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= '' then return end
  local tick, name = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_buf_get_name(buf)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local items = { { method = 'mode', label = 'モード | :HodoCodeMode / <leader>h — 読解モード開始' } }
  for _, section in ipairs(sections) do
    for _, key in ipairs(section[2]) do
      items[#items + 1] = { method = actions[key][1], label = section[1] .. ' | ' .. key .. ' — ' .. actions[key][2] }
    end
  end
  vim.ui.select(items, { prompt = 'HodoCode 操作（解析は :write 後 / 自動保存なし）',
    format_item = function(item) return item.label end }, function(item)
    if not item then return end
    if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf)
      or vim.api.nvim_win_get_buf(win) ~= buf or vim.api.nvim_buf_get_name(buf) ~= name
      or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      or not vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor) then
      vim.notify('HodoCode: 選択中にソースが変わったため操作を中止しました', vim.log.levels.WARN)
      return
    end
    vim.api.nvim_set_current_win(win)
    local ok, err = pcall(function()
      if item.method == 'help' then M.help() else require('hodocode')[item.method]() end
    end)
    if not ok then vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR) end
  end)
end

local function guide(current)
  local width = math.max(1, math.min(90, vim.o.columns - 4))
  local config = require('hodocode').config
  local agent = require('hodocode.agent')
  local conversation = require('hodocode.session').get()
  local request = conversation.request
  local status = agent.status and agent.status(request and request.source or current.buf)
  if request and not status then status = conversation.last_status end
  local file = vim.bo[current.buf].modified and '未保存' or '保存済み'
  local configured = type(config.agent) == 'table' and type(config.agent[1]) == 'string' and config.agent[1] ~= ''
  local phase = status and require('hodocode.ui').label(status.phase) or (configured and '待機' or '未設定')
  local line = width >= 56 and ('?:操作一覧 q/Esc:編集 | ' .. file .. ' | AI:' .. phase)
    or (width >= 24 and ('?:操作 q:編集 | ' .. file) or '? q')
  while vim.fn.strdisplaywidth(line) > width do line = vim.fn.strcharpart(line, 0, vim.fn.strchars(line) - 1) end
  local lines, height = { line }, 1
  local exists = current.guide and vim.api.nvim_win_is_valid(current.guide)
  local buf = exists and vim.api.nvim_win_get_buf(current.guide) or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'hodocode-mode'
  if not exists or current.guide_text ~= line then
    vim.bo[buf].readonly, vim.bo[buf].modifiable = false, true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
    current.guide_text = line
  end
  local config = {
    relative = 'editor', row = math.max(0, vim.o.lines - vim.o.cmdheight - height - 1),
    col = math.max(0, vim.o.columns - width - 2), width = width, height = height,
    style = 'minimal', border = 'none', focusable = false, zindex = 40,
  }
  local layout = table.concat({ vim.o.columns, vim.o.lines, vim.o.cmdheight }, ':')
  if exists then
    if current.guide_layout ~= layout then vim.api.nvim_win_set_config(current.guide, config) end
  else
    current.guide = vim.api.nvim_open_win(buf, false, config)
    vim.wo[current.guide].wrap = false
    vim.api.nvim_create_autocmd('WinClosed', { group = current.group, pattern = tostring(current.guide), nested = true, callback = M.stop })
  end
  current.guide_layout = layout
end

function M.start()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' or vim.api.nvim_win_get_config(0).relative ~= '' then
    vim.notify('HodoCode: モードは通常の編集バッファで開始してください', vim.log.levels.ERROR)
    return
  end
  if state and state.buf == buf then return end
  M.stop()
  local current = { buf = buf, win = vim.api.nvim_get_current_win(), bindings = {}, group = vim.api.nvim_create_augroup('HodoCodeMode', { clear = true }) }
  state = current
  for key in pairs(vim.tbl_extend('force', actions, exits)) do
    local previous = vim.fn.maparg(key, 'n', false, true)
    local callback = function()
      if state ~= current or vim.api.nvim_get_current_buf() ~= buf then return end
      if exits[key] then M.stop(); return end
      local ok, err = pcall(function()
        local method = actions[key][1]
        if method == 'help' then M.help() else require('hodocode')[method]() end
      end)
      if not ok then vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR) end
    end
    current.bindings[key] = { callback = callback, previous = previous.buffer == 1 and previous or nil }
    vim.keymap.set('n', key, callback, {
      buffer = buf, nowait = true, silent = true, desc = 'HodoCode: ' .. (actions[key] and actions[key][2] or 'モード終了'),
    })
  end
  vim.api.nvim_create_autocmd('BufEnter', { group = current.group, nested = true, callback = function()
    if vim.api.nvim_get_current_buf() ~= buf and vim.api.nvim_win_get_config(0).relative == '' then M.stop() end
  end })
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'BufDelete', 'BufWipeout' }, {
    group = current.group, buffer = buf, nested = true, callback = M.stop,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = current.group, callback = M.stop })
  vim.api.nvim_create_autocmd('VimResized', { group = current.group, callback = function()
    if state == current then guide(current) end
  end })
  vim.api.nvim_create_autocmd('BufModifiedSet', { group = current.group, buffer = buf, callback = function()
    if state == current then guide(current) end
  end })
  vim.api.nvim_create_autocmd('User', { group = current.group, pattern = 'HodoCodeAgentStatus', callback = function(event)
    if state == current and event.data then guide(current) end
  end })
  guide(current)
  require('hodocode.marker').start(buf, current.group)
end

return M
