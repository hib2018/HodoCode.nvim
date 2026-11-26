local M = {}

function M.open(submit, on_cancel)
  local source = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype = 'wipe', 'text'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
  local win = require('hodocode.ui').open_popup(buf)
  if vim.fn.has('nvim-0.10') == 1 then
    vim.api.nvim_win_set_config(win, { footer = ' Ctrl-s:送信 Esc:取消 ' })
  end
  local done = false
  local function callback(fn, prompt)
    if not fn then return end
    local ok, err = pcall(fn, prompt)
    if not ok then vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR) end
  end
  local function finish(prompt)
    if done then return end
    done = true
    local focused = vim.api.nvim_get_current_win() == win
    if focused then vim.cmd.stopinsert() end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if focused and vim.api.nvim_win_is_valid(source) then vim.api.nvim_set_current_win(source) end
    callback(prompt and submit or on_cancel, prompt)
  end
  local function cancel() finish(nil) end
  local function send()
    if done or not vim.api.nvim_buf_is_valid(buf) then return end
    local prompt = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    if prompt:find('%S') then finish(prompt) end
  end
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    if done then return end
    done = true
    -- WinClosed runs before Neovim finishes restoring the underlying window.
    vim.schedule(function() callback(on_cancel) end)
  end })
  for _, key in ipairs({ '<C-s>', '<C-CR>' }) do
    vim.keymap.set({ 'n', 'i' }, key, send, { buffer = buf, silent = true })
  end
  vim.keymap.set('n', '<CR>', send, { buffer = buf, silent = true })
  vim.keymap.set({ 'n', 'i' }, '<Esc>', cancel, { buffer = buf, silent = true })
  vim.keymap.set('n', 'q', cancel, { buffer = buf, silent = true })
  vim.cmd.startinsert()
  return buf, win, cancel
end

return M
