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
  local current = { buf = buf, generation = 0, ranges = {} }
  active = current
  local function clear()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  end
  local function update()
    if active ~= current then return end
    clear()
    if not current.ctx or not current.ctx.valid() then return end
    local targets, seen = {}, {}
    for _, entry in ipairs(current.ranges) do
      local site, target = entry.site, entry.target
      if targets[site.To] == nil then targets[site.To] = require('hodocode.ui').target(current.ctx.root, target) or false end
      local key = table.concat({ site.Line, site.Column, site.EndColumn }, ':')
      if targets[site.To] and not seen[key] then
        seen[key] = true
        vim.api.nvim_buf_set_extmark(buf, ns, site.Line - 1, site.Column - 1, {
          end_row = site.Line - 1, end_col = site.EndColumn - 1,
          hl_group = 'HodoCodeFunction', priority = 150,
        })
      end
    end
  end
  local function refresh()
    if active ~= current or vim.api.nvim_get_current_buf() ~= buf then return end
    current.generation = current.generation + 1
    local generation = current.generation
    current.ctx, current.ranges, current.loading = nil, {}, false
    clear()
    local hc = require('hodocode')
    local ok, ctx = pcall(hc.context)
    if not ok then return end
    local function valid()
      return active == current and current.generation == generation and ctx.valid()
    end
    -- Unsupported/unsaved buffers can still enter mode for AI operations, without markers.
    current.loading = true
    local started = pcall(function()
      local client = require('hodocode.client').start(ctx.root, hc.config)
      client:request('reload', {}, function(_, err)
        if not valid() then return end
        if err then current.loading = false; return end
        client:request('functions', {}, function(functions, functions_err)
          if not valid() then return end
          current.loading = false
          if functions_err then return end
          current.ctx = ctx
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local function owner(row)
            local selected
            for _, f in ipairs(functions) do
              if f.File == ctx.file and f.Line <= row and row <= f.End then
                if not selected or f.End - f.Line < selected.End - selected.Line then selected = f end
              end
            end
            return selected and selected.ID
          end
          for _, f in ipairs(functions) do
            if f.File == ctx.file then
              client:request('calls', { ['function'] = f.ID }, function(result, calls_err)
                if calls_err or not valid() then return end
                for _, site in ipairs(result.calls) do
                  local line = lines[site.Line]
                  local target = result.Targets[site.To]
                  if not site.Unknown and target and line and site.Column >= 1 and site.EndColumn > site.Column
                    and site.EndColumn <= #line + 1 and owner(site.Line) == f.ID then
                    local overlaps = 0
                    for _, other in ipairs(result.calls) do
                      if other.Line == site.Line and other.EndColumn > other.Column
                        and other.Column < site.EndColumn and site.Column < other.EndColumn then
                        overlaps = overlaps + 1
                      end
                    end
                    if overlaps == 1 then current.ranges[#current.ranges + 1] = { site = site, target = target } end
                  end
                end
                update()
              end)
            end
          end
        end)
      end)
    end)
    if not started then current.loading = false end
  end
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'BufEnter' }, { group = group, buffer = buf, callback = function()
    if not current.ctx and not current.loading then refresh() else update() end
  end })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufReadPost', 'BufFilePost' }, {
    group = group, buffer = buf, callback = function()
      current.generation = current.generation + 1
      current.ctx, current.ranges, current.loading = nil, {}, false
      clear()
      vim.schedule(refresh)
    end,
  })
  refresh()
end

return M
