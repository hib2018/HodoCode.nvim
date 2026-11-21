local M = {}
local uv = vim.uv or vim.loop
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ':h:h:h')
local defaults = {
  backend = { plugin_root .. '/bin/hodocode' }, language = 'auto', root = nil,
  timeout_ms = 120000, max_response_bytes = 8 * 1024 * 1024,
  agent = nil, agent_timeout_ms = 120000, max_agent_bytes = 1024 * 1024,
}
M.config = vim.deepcopy(defaults)

local function notify(message)
  vim.notify('HodoCode: ' .. message, vim.log.levels.ERROR)
end

local function stamp(path)
  local stat = uv.fs_stat(path)
  return stat and table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':') or ''
end

function M.context()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  local path = uv.fs_realpath(name)
  if not path or vim.bo[buf].buftype ~= '' then error('保存済みファイルの通常バッファで実行してください') end
  local root = M.config.root or vim.fs.root(path, { 'go.mod', '.git', 'package.json', 'Cargo.toml', 'pyproject.toml' }) or vim.fs.dirname(path)
  root = uv.fs_realpath(root)
  if not root or path:sub(1, #root + 1) ~= root .. '/' then error('ファイルが解析ルートの外にあります') end
  if vim.bo[buf].modified then error('解析結果は保存済みソース用です。保存してから再実行してください') end
  local languages = { go = 'go', zig = 'zig', ts = 'typescript', rs = 'rust', c = 'c', h = 'c', js = 'javascript', mjs = 'javascript', cjs = 'javascript', py = 'python' }
  local extension = vim.fs.basename(path):match('%.([^.]+)$')
  local language = languages[extension and extension:lower()]
  if not language then
    error('このファイル形式はHodoCodeの解析対象外です（' .. (extension and '.' .. extension or '拡張子なし')
      .. '）。対応言語はGo・Zig・TypeScript・Rust・C・JavaScript・Pythonです。Luaは未対応で、language = "auto"にしても解析できません。', 0)
  end
  local selection = vim.trim(M.config.language):lower()
  selection = ({ ts = 'typescript', js = 'javascript', rs = 'rust', py = 'python', golang = 'go', [''] = 'auto' })[selection] or selection
  if vim.tbl_contains({ 'go', 'zig', 'typescript', 'rust', 'c', 'javascript', 'python' }, selection) and selection ~= language then
    error('language = "' .. selection .. '"ではこの' .. language .. 'ファイルを解析できません。setupのlanguageを"auto"または"' .. language .. '"に変更してください。', 0)
  end
  if language == 'go' then
    if path:match('_test%.go$') then error('Goの_test.goは現在のHodoCodeでは解析対象外です。通常の.goファイルで実行してください。', 0) end
    local module = vim.fs.root(path, 'go.mod')
    if not module or (module ~= root and module:sub(1, #root + 1) ~= root .. '/') then
      error('Goの解析に必要なgo.modが解析範囲内に見つかりません（' .. root
        .. '）。go.mod配下の.goファイルを開いて実行してください。dotfilesなど対象外のディレクトリにgo.modを追加する必要はありません。', 0)
    end
  end
  for _, client in ipairs(vim.lsp.get_clients()) do
    for attached in pairs(client.attached_buffers or {}) do
      if vim.api.nvim_buf_is_valid(attached) then
        local file = uv.fs_realpath(vim.api.nvim_buf_get_name(attached)) or ''
        local language = languages[(vim.fs.basename(file):match('%.([^.]+)$') or ''):lower()]
        if file:sub(1, #root + 1) == root .. '/' and language and language ~= 'go' and (selection == 'auto' or selection == language) then
          error('対象言語のNeovim側LSPが稼働中です。バックエンドLSPとの二重起動を避けるため解析を中止しました。LSPの役割分担を確認してください')
        end
      end
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local ctx = {
    buf = buf, root = root, file = path:sub(#root + 2), path = path,
    row = cursor[1] - 1, column = cursor[2],
    tick = vim.api.nvim_buf_get_changedtick(buf), stamp = stamp(path),
  }
  function ctx.valid()
    return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name
      and vim.api.nvim_buf_get_changedtick(buf) == ctx.tick and not vim.bo[buf].modified
      and stamp(path) == ctx.stamp
  end
  return ctx
end

local function with_context(action)
  local ok, ctx = pcall(M.context)
  if not ok then notify(tostring(ctx)); return end
  local success, err = pcall(function()
    local client = require('hodocode.client').start(ctx.root, M.config)
    -- Reload before each operation so navigation never reuses another file's old snapshot.
    client:request('reload', {}, function(_, reload_err)
      if reload_err then notify(reload_err); return end
      if ctx.valid() then action(ctx, client) end
    end)
  end)
  if not success then notify(tostring(err)) end
end

local function checked(ctx, callback)
  return function(result, err)
    if err then notify(err); return end
    if not ctx.valid() then return end
    callback(result)
  end
end

function M.functions()
  with_context(function(ctx, client)
    client:request('functions', {}, checked(ctx, function(functions)
      vim.ui.select(functions, { prompt = 'HodoCode 関数', format_item = function(f)
        return f.ID .. '  ' .. f.File .. ':' .. f.Line
      end }, function(f)
        if f and ctx.valid() then require('hodocode.ui').jump(ctx.root, f) end
      end)
    end))
  end)
end

local function at_cursor(ctx, client, callback)
  client:request('functions', {}, checked(ctx, function(functions)
    local selected
    for _, f in ipairs(functions) do
      if f.File == ctx.file and f.Line <= ctx.row + 1 and f.End >= ctx.row + 1 then
        if not selected or f.End - f.Line < selected.End - selected.Line then selected = f end
      end
    end
    if not selected then notify('カーソル位置に関数がありません'); return end
    callback(selected)
  end))
end

function M.calls()
  with_context(function(ctx, client)
    at_cursor(ctx, client, function(f)
      local ui = require('hodocode.ui')
      local rows = { '# ' .. f.ID, 'Enter: 展開 / 移動  q: 閉じる', '' }
      local nodes = {}
      local buf, win = ui.float(rows, 'HodoCode 呼び出しツリー', ctx)
      local function expand(id, depth, ancestors, anchor)
        client:request('calls', { ['function'] = id }, checked(ctx, function(result)
          if not vim.api.nvim_buf_is_valid(buf) then return end
          local insert_at = 3
          if anchor then
            for line, node in ipairs(nodes) do
              if node == anchor then insert_at = line; break end
            end
          end
          local additions, added_nodes = {}, {}
          for _, site in ipairs(result.calls) do
            local target = result.Targets[site.To]
            local cycle = ancestors[site.To] == true
            local label = site.To or site.Name or '(unknown)'
            if site.Unknown then
              label = label .. ' [未解決: ' .. (site.Reason or '') .. ']'
              if type(site.Candidates) == 'table' and #site.Candidates > 0 then label = label .. ' 候補: ' .. table.concat(site.Candidates, ', ') end
            elseif cycle then label = label .. ' [循環]' end
            additions[#additions + 1] = string.rep('  ', depth) .. '- ' .. label
            added_nodes[#additions] = { id = site.To, target = target, depth = depth, ancestors = ancestors,
              expandable = not site.Unknown and not cycle and target ~= nil }
          end
          if #additions == 0 then additions = { string.rep('  ', depth) .. '(呼び出しなし)' } end
          for i = #additions, 1, -1 do
            table.insert(rows, insert_at + 1, additions[i])
            table.insert(nodes, insert_at + 1, added_nodes[i] or false)
          end
          vim.bo[buf].modifiable = true
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
          vim.bo[buf].modifiable = false
        end))
      end
      nodes = { false, false, false }
      expand(f.ID, 0, { [f.ID] = true })
      vim.keymap.set('n', '<CR>', function()
        if not ctx.valid() then notify('ソース変更後はツリーを開き直してください'); return end
        local line = vim.api.nvim_win_get_cursor(win)[1]
        local node = nodes[line]
        if not node then return end
        if node.expandable then
          node.expandable = false
          local ancestors = vim.deepcopy(node.ancestors)
          ancestors[node.id] = true
          expand(node.id, node.depth + 1, ancestors, node)
        elseif node.target then
          vim.api.nvim_win_close(win, true)
          ui.jump(ctx.root, node.target)
        end
      end, { buffer = buf })
      vim.keymap.set('n', 'o', function()
        local node = nodes[vim.api.nvim_win_get_cursor(win)[1]]
        if ctx.valid() and node and node.target then vim.api.nvim_win_close(win, true); ui.jump(ctx.root, node.target) end
      end, { buffer = buf })
    end)
  end)
end

function M.syntax()
  with_context(function(ctx, client)
    client:request('syntax', { file = ctx.file, row = ctx.row, column = ctx.column }, checked(ctx, function(help)
      local lines = { '# ' .. help.title, '', help.description }
      for _, field in ipairs({ 'syntax', 'example', 'caution', 'reference' }) do
        if help[field] and help[field] ~= '' then
          vim.list_extend(lines, { '', '## ' .. field })
          vim.list_extend(lines, vim.split(help[field], '\n', { plain = true }))
        end
      end
      -- Help descriptions can contain multiple lines too.
      require('hodocode.ui').float(vim.split(table.concat(lines, '\n'), '\n', { plain = true }), 'HodoCode 構文解説', ctx)
    end))
  end)
end

function M.reload()
  require('hodocode.client').stop_all()
  with_context(function() vim.notify('HodoCode: 再解析しました') end)
end

function M.agent(prompt)
  require('hodocode.agent').run(M.config, prompt)
end

function M.diff()
  require('hodocode.agent').diff()
end

function M.mode()
  require('hodocode.mode').start()
end

function M.exit_mode()
  require('hodocode.mode').stop()
end

function M.setup(options)
  require('hodocode.mode').stop()
  require('hodocode.client').stop_all()
  require('hodocode.agent').stop()
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), options or {})
  assert(type(M.config.backend) == 'table' and #M.config.backend > 0, 'backend must be an argv list')
  for _, key in ipairs({ 'timeout_ms', 'max_response_bytes', 'agent_timeout_ms', 'max_agent_bytes' }) do
    local value = M.config[key]
    assert(type(value) == 'number' and value > 0 and value == math.floor(value), key .. ' must be a positive integer')
  end
  assert(M.config.agent == nil or (type(M.config.agent) == 'table' and #M.config.agent > 0), 'agent must be an argv list')
  for _, argv in ipairs({ M.config.backend, M.config.agent or {} }) do
    for _, arg in ipairs(argv) do assert(type(arg) == 'string', 'command arguments must be strings') end
  end
  local group = vim.api.nvim_create_augroup('HodoCode', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = function()
    require('hodocode.client').stop_all()
  end })
  vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter' }, { group = group, callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if vim.bo[buf].buftype ~= '' or vim.bo[buf].modified then return end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].modified then return end
      local autoread = vim.bo[buf].autoread
      vim.bo[buf].autoread = true
      pcall(vim.cmd, 'silent checktime ' .. buf)
      if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].autoread = autoread end
    end)
  end })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    require('hodocode.client').stop_all()
    require('hodocode.agent').stop()
  end })
end

return M
