local M = {}
local state
local actions = {
  n = { 'next_call', '現在の関数内の次の呼び出し名へ' }, N = { 'previous_call', '現在の関数内の前の呼び出し名へ' },
  b = { 'back', '直前の読解位置へ戻る' }, g = { 'function_start', '関数先頭' }, G = { 'function_end', '関数末尾' },
  t = { 'calls', 'ツリー' }, e = { 'chat', 'CLIチャットを開く' }, i = { 'chat', 'CLIチャットを開く（eと同じ）' },
  E = { 'explain_now', '現在の関数のAI行解説を生成' }, c = { 'notes_toggle', '行解説表示切替' },
  ['['] = { 'help_up', 'ポップアップを上へスクロール' }, [']'] = { 'help_down', 'ポップアップを下へスクロール' },
  v = { 'exit_mode', '編集へ戻る' },
  f = { 'functions', '関数一覧' }, s = { 'syntax', '構文・関数・変数情報' }, r = { 'reload', '再解析' },
  a = { 'explain_line', 'カーソル行を解説（指示可・空欄で通常解説）' }, x = { 'cancel', 'AI中止' }, d = { 'diff', '従来のAI編集前との差分' },
  ['<CR>'] = { 'follow', '呼び出し先' }, m = { 'graph', '図' },
  z = { 'notes_clear', '注釈消去' }, K = { 'notes_show', '注釈全文' },
  ['?'] = { 'help', '操作一覧' },
}
local sections = {
  { '基本の移動', { 'n', 'N', '<CR>', 'b', 'g', 'G' } },
  { '表示と読解', { 't', 'f', 's', 'm', 'K', 'c', 'z', '[', ']', 'r', '?' } },
  { 'AI', { 'E', 'a', 'e', 'i', 'x', 'd' } },
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
  local current = state
  if not current then return end
  if current.help and vim.api.nvim_win_is_valid(current.help) then vim.api.nvim_set_current_win(current.help); return end
  local lines = {
    '# HodoCode 操作一覧', '',
    '基本: n/N で呼び出し名を選ぶ → Enter で定義へ進む → b で読解履歴を戻る。',
    '以下のキーはソースバッファ上で有効。h/j/k/l と / 検索はNeovim標準です（? は操作一覧）。',
    '下線は関数名、黄色の強調はジャンプ可能な呼び出し名です。',
    'n/N は現在の関数内だけを移動し、未解決・外部の呼び出し名も含みます。',
    'Enter は確定したローカル定義だけへ移動します。3n などの回数指定も使えます。',
    'g/G はファイルではなく現在の関数の先頭／末尾です。',
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

local function guide(current)
  local width = math.max(1, math.min(90, vim.o.columns - 4))
  local lines
  if width >= 86 then
    lines = { 'HodoCode MODE | ?:操作一覧 | q/Esc:終了 v:編集',
      '移動 n/N:呼出名 → Enter:定義(黄色) → b:戻る | g/G:関数先頭/末尾',
      '表示 t:ツリー f:関数一覧 s:構文 K:注釈全文',
      'AI E:関数解説 a:行解説 e:チャット x:中止' }
  elseif width >= 56 then
    lines = { 'HodoCode MODE | ?:操作一覧 | q/Esc:終了',
      '移動 n/N:選択 Enter:定義 b:戻る',
      '表示 t:ツリー f:一覧 K:注釈',
      'AI E:関数解説 e:チャット x:中止' }
  elseif width >= 24 then
    lines = { 'HodoCode | ?:操作一覧', 'n/N → Enter → b', 'q/Esc:終了 v:編集' }
  else
    lines = { '? help', 'n/N Enter b', 'q exit' }
  end
  local height = math.max(1, math.min(#lines, vim.o.lines - vim.o.cmdheight - 3))
  if height == 1 then lines = { width >= 8 and '?:help q' or 'q ?' }
  elseif height < #lines then lines[height] = 'q/Esc:終了 | ?:操作一覧' end
  for i = #lines, height + 1, -1 do lines[i] = nil end
  for i, line in ipairs(lines) do
    while vim.fn.strdisplaywidth(line) > width do line = vim.fn.strcharpart(line, 0, vim.fn.strchars(line) - 1) end
    lines[i] = line
  end
  local exists = current.guide and vim.api.nvim_win_is_valid(current.guide)
  local buf = exists and vim.api.nvim_win_get_buf(current.guide) or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'hodocode-mode'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  local config = {
    relative = 'editor', row = math.max(0, vim.o.lines - vim.o.cmdheight - height - 3),
    col = math.max(0, vim.o.columns - width - 2), width = width, height = height,
    style = 'minimal', border = 'rounded', focusable = false, zindex = 40,
  }
  if exists then vim.api.nvim_win_set_config(current.guide, config)
  else
    current.guide = vim.api.nvim_open_win(buf, false, config)
    vim.wo[current.guide].wrap = false
    vim.api.nvim_create_autocmd('WinClosed', { group = current.group, pattern = tostring(current.guide), nested = true, callback = M.stop })
  end
end

function M.start()
  local buf = vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= '' or vim.api.nvim_win_get_config(0).relative ~= '' then
    vim.notify('HodoCode: モードは通常の編集バッファで開始してください', vim.log.levels.ERROR)
    return
  end
  if state and state.buf == buf then return end
  M.stop()
  local current = { buf = buf, bindings = {}, group = vim.api.nvim_create_augroup('HodoCodeMode', { clear = true }) }
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
  guide(current)
  require('hodocode.marker').start(buf, current.group)
end

return M
