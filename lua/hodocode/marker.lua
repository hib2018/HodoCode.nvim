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

local function context_function()
  local current = active
  if not current or vim.api.nvim_get_current_buf() ~= current.buf or not current.ctx or not current.ctx.valid() then
    vim.notify('HodoCode: 保存済みソースの解析完了後に実行してください', vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local selected
  for _, f in ipairs(current.functions or {}) do
    if f.File == current.ctx.file and f.Line <= row and row <= f.End then
      if not selected or f.End - f.Line < selected.End - selected.Line then selected = f end
    end
  end
  if not selected then
    vim.notify('HodoCode: カーソル位置に関数がありません', vim.log.levels.WARN)
    return
  end
  return current, selected
end

function M.move(delta, count)
  local current, f = context_function()
  if not current then return end
  local sites = current.calls[f.ID]
  if not sites then vim.notify('HodoCode: 呼び出し箇所を解析中です', vim.log.levels.WARN); return end
  if #sites == 0 then vim.notify('HodoCode: この関数に呼び出し箇所はありません', vim.log.levels.INFO); return end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local index
  if delta > 0 then
    for i, site in ipairs(sites) do
      if site.Line > cursor[1] or (site.Line == cursor[1] and site.Column - 1 > cursor[2]) then index = i; break end
    end
    index = math.min(#sites, (index or #sites) + (count or 1) - 1)
  else
    for i = #sites, 1, -1 do
      local site = sites[i]
      if site.Line < cursor[1] or (site.Line == cursor[1] and site.EndColumn - 1 <= cursor[2]) then index = i; break end
    end
    index = math.max(1, (index or 1) - (count or 1) + 1)
  end
  local site = sites[index]
  vim.api.nvim_win_set_cursor(0, { site.Line, site.Column - 1 })
  vim.cmd('normal! zv')
end

function M.edge(last)
  local current, f = context_function()
  if not current then return end
  vim.api.nvim_win_set_cursor(0, { last and f.End or f.Line, 0 })
  vim.cmd('normal! zv')
end

function M.start(buf, group)
  M.stop()
  vim.api.nvim_set_hl(0, 'HodoCodeFunctionName', { default = true, underline = true })
  vim.api.nvim_set_hl(0, 'HodoCodeFunction', {
    default = true, fg = '#1c1c1c', bg = '#ffd75f', bold = true, underline = true,
    ctermfg = 234, ctermbg = 221,
  })
  local current = { buf = buf, generation = 0, ranges = {} }
  active = current
  local function clear()
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  end
  local function update()
    if active ~= current then return end
    clear()
    if not current.ctx or not current.ctx.valid() then return end
    local targets, names = {}, {}
    local function add(site, highlight)
      names[table.concat({ site.Line, site.Column, site.EndColumn }, ':')] = { site = site, highlight = highlight }
    end
    for _, site in ipairs(current.names or {}) do add(site, 'HodoCodeFunctionName') end
    for _, sites in pairs(current.calls or {}) do
      for _, site in ipairs(sites) do add(site, 'HodoCodeFunctionName') end
    end
    for _, entry in ipairs(current.ranges) do
      local site, target = entry.site, entry.target
      if targets[site.To] == nil then targets[site.To] = require('hodocode.ui').target(current.ctx.root, target) or false end
      if targets[site.To] then add(site, 'HodoCodeFunction') end
    end
    for _, entry in pairs(names) do
      local site = entry.site
      vim.api.nvim_buf_set_extmark(buf, ns, site.Line - 1, site.Column - 1, {
        end_row = site.Line - 1, end_col = site.EndColumn - 1,
        hl_group = entry.highlight, priority = entry.highlight == 'HodoCodeFunction' and 150 or 140,
      })
    end
  end
  local function refresh()
    if active ~= current or vim.api.nvim_get_current_buf() ~= buf then return end
    current.generation = current.generation + 1
    local generation = current.generation
    current.ctx, current.ranges, current.names, current.loading, current.calls = nil, {}, {}, false, {}
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
          current.ctx, current.functions = ctx, functions
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
                local sites, seen = {}, {}
                for _, site in ipairs(result.calls) do
                  local line = lines[site.Line]
                  local key = table.concat({ site.Line, site.Column }, ':')
                  if line and site.Column >= 1 and site.EndColumn > site.Column and site.EndColumn <= #line + 1
                    and owner(site.Line) == f.ID and not seen[key] then
                    sites[#sites + 1], seen[key] = site, true
                  end
                end
                table.sort(sites, function(a, b) return a.Line < b.Line or (a.Line == b.Line and a.Column < b.Column) end)
                current.calls[f.ID] = sites
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
          client:request('function-names', { file = ctx.file }, function(names, names_err)
            if names_err or not valid() then return end
            current.names = {}
            for _, site in ipairs(names) do
              local line = lines[site.Line]
              if line and site.Column >= 1 and site.EndColumn > site.Column and site.EndColumn <= #line + 1 then
                current.names[#current.names + 1] = site
              end
            end
            update()
          end)
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
      current.ctx, current.ranges, current.names, current.loading, current.calls = nil, {}, {}, false, {}
      clear()
      vim.schedule(refresh)
    end,
  })
  refresh()
end

return M
