local M = {}
local state
local actions = {
  f = { 'functions', '関数' }, c = { 'calls', 'ツリー' }, s = { 'syntax', '構文' },
  r = { 'reload', '再解析' }, a = { 'explain', 'AI解説' }, x = { 'cancel', 'AI中止' }, d = { 'diff', '差分' },
  ['<CR>'] = { 'follow', '呼び出し先' }, g = { 'graph', '図' }, t = { 'chat', 'チャット' },
  v = { 'notes_toggle', '注釈表示切替' }, z = { 'notes_clear', '注釈消去' }, K = { 'notes_show', '注釈全文' },
}

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
  if current.guide and vim.api.nvim_win_is_valid(current.guide) then vim.api.nvim_win_close(current.guide, true) end
end

local function guide(current)
  local width = math.max(1, math.min(78, vim.o.columns - 4))
  local lines = { 'HodoCode MODE  |  Esc: 終了  Enter:呼び出し先',
    'f:関数 c:ツリー s:構文 r:再解析 g:図 d:差分',
    'a:AI解説 t:チャット x:中止 v:注釈表示 z:注釈消去 K:注釈全文' }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'hodocode-mode'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  current.guide = vim.api.nvim_open_win(buf, false, {
    relative = 'editor', row = math.max(0, vim.o.lines - vim.o.cmdheight - 6),
    col = math.max(0, vim.o.columns - width - 2), width = width, height = 3,
    style = 'minimal', border = 'rounded', focusable = false, zindex = 40,
  })
  vim.wo[current.guide].wrap = false
  vim.api.nvim_create_autocmd('WinClosed', { group = current.group, pattern = tostring(current.guide), callback = M.stop })
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
  for _, key in ipairs({ 'f', 'c', 's', 'r', 'a', 'x', 'd', 'g', 't', 'v', 'z', 'K', '<CR>', '<Esc>' }) do
    local previous = vim.fn.maparg(key, 'n', false, true)
    local callback = function()
      if state ~= current or vim.api.nvim_get_current_buf() ~= buf then return end
      if key == '<Esc>' then M.stop(); return end
      local ok, err = pcall(function()
        local method = actions[key][1]
        require('hodocode')[method]()
      end)
      if not ok then vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR) end
    end
    current.bindings[key] = { callback = callback, previous = previous.buffer == 1 and previous or nil }
    vim.keymap.set('n', key, callback, {
      buffer = buf, nowait = true, silent = true, desc = 'HodoCode: ' .. (actions[key] and actions[key][2] or 'モード終了'),
    })
  end
  vim.api.nvim_create_autocmd('BufEnter', { group = current.group, callback = function()
    if vim.api.nvim_get_current_buf() ~= buf and vim.api.nvim_win_get_config(0).relative == '' then M.stop() end
  end })
  vim.api.nvim_create_autocmd({ 'InsertEnter', 'BufDelete', 'BufWipeout' }, {
    group = current.group, buffer = buf, callback = M.stop,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = current.group, callback = M.stop })
  vim.api.nvim_create_autocmd('VimResized', { group = current.group, callback = function()
    if current.guide and vim.api.nvim_win_is_valid(current.guide) then
      local width = math.max(1, math.min(78, vim.o.columns - 4))
      vim.api.nvim_win_set_config(current.guide, {
        relative = 'editor', row = math.max(0, vim.o.lines - vim.o.cmdheight - 6),
        col = math.max(0, vim.o.columns - width - 2), width = width, height = 3,
      })
    end
  end })
  guide(current)
  require('hodocode.marker').start(buf, current.group)
end

return M
