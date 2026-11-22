local M = {}
local ns = vim.api.nvim_create_namespace('HodoCodeFunction')
local active

function M.stop()
  local current = active
  active = nil
  if current and vim.api.nvim_buf_is_valid(current.buf) then
    vim.api.nvim_buf_clear_namespace(current.buf, ns, 0, -1)
  end
end

function M.start(buf, group)
  M.stop()
  vim.api.nvim_set_hl(0, 'HodoCodeFunction', { default = true, link = 'Visual' })
  local current = { buf = buf, generation = 0 }
  active = current
  local function clear()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  end
  local function update()
    if active ~= current or vim.api.nvim_get_current_buf() ~= buf then return end
    clear()
    if not current.ctx or not current.ctx.valid() then return end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local selected
    for _, f in ipairs(current.functions or {}) do
      if f.File == current.ctx.file and f.Line <= row and row <= f.End then
        if not selected or f.End - f.Line < selected.End - selected.Line then selected = f end
      end
    end
    if selected and selected.Line >= 1 and selected.End <= vim.api.nvim_buf_line_count(buf) then
      vim.api.nvim_buf_set_extmark(buf, ns, selected.Line - 1, 0, {
        end_row = selected.End, end_col = 0, hl_group = 'HodoCodeFunction', hl_eol = true,
        priority = 90,
      })
    end
  end
  local function refresh()
    if active ~= current or vim.api.nvim_get_current_buf() ~= buf then return end
    current.generation = current.generation + 1
    local generation = current.generation
    current.ctx, current.functions = nil, nil
    clear()
    local hc = require('hodocode')
    local ok, ctx = pcall(hc.context)
    if not ok then return end
    local function valid()
      return active == current and current.generation == generation and ctx.valid()
    end
    -- Unsupported/unsaved buffers can still enter mode for AI operations, without a marker.
    pcall(function()
      local client = require('hodocode.client').start(ctx.root, hc.config)
      client:request('reload', {}, function(_, err)
        if err or not valid() then return end
        client:request('functions', {}, function(functions, functions_err)
          if functions_err or not valid() then return end
          current.ctx, current.functions = ctx, functions
          update()
        end)
      end)
    end)
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, { group = group, buffer = buf, callback = update })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufReadPost', 'BufFilePost' }, {
    group = group, buffer = buf, callback = function()
      current.generation = current.generation + 1
      current.ctx, current.functions = nil, nil
      clear()
      vim.schedule(refresh)
    end,
  })
  refresh()
end

return M
