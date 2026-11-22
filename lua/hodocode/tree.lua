local M = {}
local saved = {}
local uv = vim.uv or vim.loop

local function notify(message)
  vim.notify('HodoCode: ' .. tostring(message), vim.log.levels.WARN)
end

local function stamp(path)
  local s = uv.fs_stat(path)
  return s and table.concat({ s.size, s.mtime.sec, s.mtime.nsec, s.ctime.sec, s.ctime.nsec }, ':') or ''
end

local function unchanged(files)
  for path, old in pairs(files) do
    local buf = vim.fn.bufnr(path)
    if stamp(path) ~= old or (buf >= 0 and vim.bo[buf].modified) then return false end
  end
  return true
end

local function blocked(n)
  return n.unknown or not n.target
end

local function label(n)
  local text = n.id or n.sites[1].Name or '(unknown)'
  if blocked(n) then
    text = text .. ' [未解決: ' .. (n.reason or '定義なし') .. ']'
    if #n.candidates > 0 then text = text .. ' 候補: ' .. table.concat(n.candidates, ', ') end
  elseif n.cycle then text = text .. ' [循環]' end
  if #n.sites > 1 then text = text .. ' (' .. #n.sites .. ' sites)' end
  if n.loading then text = text .. ' [loading]' end
  if n.error then text = text .. ' [error: ' .. tostring(n.error) .. ']' end
  return text
end

local function rows(state)
  local result = {}
  local function visit(n, depth)
    local marker = blocked(n) and '× ' or n.cycle and '↻ ' or n.open and '− '
      or n.loaded and #n.children == 0 and '· ' or '+ '
    result[#result + 1] = { node = n, text = string.rep('  ', depth) .. marker .. label(n) }
    if n.open then for _, child in ipairs(n.children or {}) do visit(child, depth + 1) end end
  end
  visit(state.root, 0)
  return result
end

local function find(n, id)
  if n.id == id and not blocked(n) then return n end
  for _, child in ipairs(n.children or {}) do
    local found = find(child, id)
    if found then return found end
  end
end

local function native(controller)
  local ui = require('hodocode.ui')
  local buf, win = ui.float({ 'Loading' }, 'HodoCode 呼び出しツリー [native fallback]', controller.ctx)
  local view = { buf = buf, win = win, renderer = 'native' }
  function view:alive() return vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf) end
  function view:close() if self:alive() then vim.api.nvim_win_close(win, true) end end
  local visible = {}
  function view:render()
    if not self:alive() then return end
    visible = rows(controller.state)
    local lines = { 'Space/Tab: 開閉  Enter/o: 移動  h/l: 閉じる/展開  q: 閉じる' }
    local selected = 2
    for i, row in ipairs(visible) do
      lines[#lines + 1] = row.text
      if row.node == controller.state.selected then selected = i + 1 end
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.7)))
    vim.api.nvim_win_set_height(win, height)
    vim.api.nvim_win_set_cursor(win, { selected, 0 })
  end
  local function current()
    if not vim.api.nvim_win_is_valid(win) then return end
    local row = visible[vim.api.nvim_win_get_cursor(win)[1] - 1]
    return row and row.node
  end
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = buf, callback = function()
    if view:alive() and current() then controller.state.selected = current() end
  end })
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    local n = current()
    if n then controller.state.selected = n end
    controller.closed = true
  end })
  for key, action in pairs({ ['<Space>'] = 'toggle', ['<Tab>'] = 'toggle', ['<CR>'] = 'jump', o = 'jump', h = 'collapse', l = 'expand' }) do
    vim.keymap.set('n', key, function() controller:act(action, current()) end, { buffer = buf })
  end
  return view
end

local function snacks(controller, picker)
  local view = { renderer = 'snacks' }
  local refreshing = true
  function view:alive() return self.picker and not self.picker.closed end
  function view:close() if self:alive() then self.picker:close() end end
  local function restore(p)
    if p.closed then return end
    refreshing = true
    local index = 1
    for i, item in ipairs(p:items()) do if item.node == controller.state.selected then index = i; break end end
    p:action('list_top')
    for _ = 2, index do p:action('list_down') end
    refreshing = false
  end
  function view:render()
    if not self:alive() then return end
    refreshing = true
    self.picker:find({ refresh = true, on_done = function()
      restore(self.picker)
    end })
  end
  local keys = {
    ['<Space>'] = 'tree_toggle', ['<Tab>'] = 'tree_toggle', h = 'tree_collapse', l = 'tree_expand',
    o = 'confirm', q = 'close', ['<Esc>'] = 'close',
  }
  local actions = {}
  for name, action in pairs({ tree_toggle = 'toggle', tree_expand = 'expand', tree_collapse = 'collapse' }) do
    actions[name] = function(p, item) controller:act(action, (item or p:current() or {}).node) end
  end
  view.picker = picker.pick({
    title = 'HodoCode 呼び出しツリー [Snacks] · Space: 開閉 · Enter: 移動',
    finder = function() return rows(controller.state) end,
    format = function(item) return { { item.text } } end,
    sort = { fields = { 'idx' } },
    matcher = { sort_empty = false },
    layout = { preset = 'select', hidden = { 'input', 'preview' },
      layout = { width = 0.9, height = 0.8, min_width = 1, max_width = math.huge } },
    focus = 'list', show_delay = 0, actions = actions,
    win = { list = { keys = keys } },
    confirm = function(p, item) controller:act('jump', (item or p:current() or {}).node) end,
    on_show = restore,
    on_change = function(_, item)
      if not refreshing and item then controller.state.selected = item.node end
    end,
    on_close = function(p)
      if not refreshing then
        local item = p:current()
        if item then controller.state.selected = item.node end
      end
      controller.closed = true
    end,
  })
  return view
end

--- Open an outgoing call tree; config.tree is 'auto' (default), 'snacks', or 'native'.
--- Returns a controller with state, view, act(action, node), and close().
function M.open(ctx, client, f, config)
  config = config or {}
  assert(config.tree == nil or config.tree == 'auto' or config.tree == 'snacks' or config.tree == 'native', 'tree must be auto, snacks or native')
  if not ctx.valid() then return end
  local previous = saved[ctx.root]
  local reusable = previous and previous.ctx.valid() and unchanged(previous.files)
  if previous and previous.controller then previous.controller:close() end
  local state = reusable and previous or nil
  local current = state and find(state.root, f.ID)
  local reveal_current = not current or state.current ~= f.ID
  if not current then
    current = { id = f.ID, target = f, sites = {}, candidates = {}, children = {} }
    state = { root = current, selected = current, files = {} }
  elseif state.current ~= f.ID then
    state.selected = current
  end
  local function reset_pending(n)
    n.loading = false
    for _, child in ipairs(n.children or {}) do reset_pending(child) end
  end
  reset_pending(state.root)
  local parent = state.selected.parent
  while parent do parent.open = true; parent = parent.parent end
  state.ctx, state.current = ctx, f.ID
  saved[ctx.root] = state
  local controller = { ctx = ctx, state = state, client = client }
  state.controller = controller
  local function remember(target)
    if target and target.File then
      local path = ctx.root .. '/' .. target.File
      state.files[path] = stamp(path)
    end
  end
  remember(f)
  function controller:valid()
    if self.closed or not ctx.valid() then return false end
    return unchanged(state.files)
  end
  function controller:close()
    if self.view then self.view:close() end
    self.closed = true
  end
  function controller:render()
    if self:valid() and self.view then self.view:render() end
  end
  function controller:expand(n)
    if blocked(n) or n.cycle then return end
    n.open = true
    if n.loaded or n.loading then self:render(); return end
    n.loading, n.error = true, nil
    self:render()
    client:request('calls', { ['function'] = n.id }, function(result, err)
      if not self:valid() then return end
      n.loading = false
      if err then n.error = err; notify(err); self:render(); return end
      if type(result) ~= 'table' or type(result.calls) ~= 'table' then
        n.error = 'invalid calls response'; notify(n.error); self:render(); return
      end
      local targets = type(result.Targets) == 'table' and result.Targets or {}
      local children, edges = {}, {}
      for _, site in ipairs(result.calls) do
        local id = type(site.To) == 'string' and site.To or nil
        local key = (site.From or n.id) .. '\0' .. (id or site.Name or '(unknown)')
        local child = edges[key]
        if not child then
          local target = id and targets[id]
          child = { id = id, parent = n, target = type(target) == 'table' and target or nil,
            sites = {}, candidates = {}, children = {} }
          edges[key], children[#children + 1] = child, child
          remember(child.target)
          local ancestor = n
          while ancestor do
            if id and ancestor.id == id then child.cycle = true; break end
            ancestor = ancestor.parent
          end
        end
        child.sites[#child.sites + 1] = site
        if site.Unknown == true then child.unknown = true end
        if type(site.Reason) == 'string' and site.Reason ~= '' then
          child.reason = child.reason and child.reason .. '; ' .. site.Reason or site.Reason
        end
        if type(site.Candidates) == 'table' then
          for _, candidate in ipairs(site.Candidates) do
            if type(candidate) == 'string' and not vim.tbl_contains(child.candidates, candidate) then
              child.candidates[#child.candidates + 1] = candidate
            end
          end
        end
      end
      n.children, n.loaded = children, true
      self:render()
    end)
  end
  function controller:act(action, n)
    if not self:valid() then notify('ソース変更後はツリーを開き直してください'); return end
    if not n then return end
    state.selected = n
    if action == 'jump' then
      if not blocked(n) then self:close(); require('hodocode.ui').jump(ctx.root, n.target) end
    elseif action == 'collapse' or (action == 'toggle' and n.open) then
      n.open = false
      self:render()
    elseif action == 'expand' or action == 'toggle' then self:expand(n) end
  end
  local ok, picker = false, nil
  if config.tree ~= 'native' then ok, picker = pcall(require, 'snacks.picker') end
  if ok and type(picker.pick) == 'function' then
    controller.view = snacks(controller, picker)
  else
    if config.tree ~= 'native' then notify('Snacks picker unavailable; using native fallback') end
    controller.view = native(controller)
  end
  if reveal_current then current.open = true end
  controller:render()
  local function resume(n)
    if not n.open then return end
    controller:expand(n)
    for _, child in ipairs(n.children or {}) do resume(child) end
  end
  resume(state.root)
  return controller
end

--- Close all trees and discard cached branches after configuration/source invalidation.
function M.clear()
  local previous = saved
  saved = {}
  for _, state in pairs(previous) do
    if state.controller then state.controller:close() end
  end
end

return M
