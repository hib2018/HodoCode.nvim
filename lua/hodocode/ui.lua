local M = {}

function M.float(lines, title, context)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.7)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor', row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)), width = width,
    height = height, style = 'minimal', border = 'rounded', title = ' ' .. title .. ' ',
  })
  vim.wo[win].wrap = true
  if context then
    local watch = vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufReadPost', 'BufDelete' }, {
      buffer = context.buf, callback = function(event)
        if (event.event == 'BufDelete' or not context.valid()) and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end,
    })
    vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function()
      pcall(vim.api.nvim_del_autocmd, watch)
    end })
  end
  vim.keymap.set('n', 'q', function() if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end end, { buffer = buf })
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
    return
  end
  vim.cmd("normal! m'")
  if (vim.uv or vim.loop).fs_realpath(vim.api.nvim_buf_get_name(0)) ~= real then
    vim.cmd.edit(vim.fn.fnameescape(real))
  end
  vim.api.nvim_win_set_cursor(0, { f.Line, 0 })
end

return M
