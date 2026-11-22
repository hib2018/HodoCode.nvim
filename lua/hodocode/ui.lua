local M = {}
local history, floats = {}, {}

function M.popup_size()
  return math.max(1, math.min(math.floor(vim.o.columns * 0.9), vim.o.columns - 4)),
    math.max(1, math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - 4))
end

local function popup_config(title)
  local width, height = M.popup_size()
  return {
    relative = 'editor', row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width, height = height,
    style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ',
  }
end

function M.open_popup(buf, title)
  local win = vim.api.nvim_open_win(buf, true, popup_config(title))
  local resize = vim.api.nvim_create_autocmd('VimResized', { callback = function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_set_config(win, popup_config(title)) end
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
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local win = M.open_popup(buf, title)
  vim.wo[win].wrap = true
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
  for _, key in ipairs({ 'q', '<C-c>', '<C-d>' }) do
    vim.keymap.set('n', key, function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      if key ~= 'q' then require('hodocode.mode').stop() end
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
