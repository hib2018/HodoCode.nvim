local M = {}
local uv = vim.uv or vim.loop
local source = debug.getinfo(1, 'S').source:sub(2)
local plugin_root = vim.fn.fnamemodify(source, ':h:h:h')
local defaults = {
  backend = { plugin_root .. '/bin/hodocode' }, language = 'auto', root = nil,
  timeout_ms = 120000, max_response_bytes = 8 * 1024 * 1024,
  agent = nil, agent_timeout_ms = 120000, max_agent_bytes = 1024 * 1024,
  tree = 'auto', graph_renderer = nil, explain_agent = nil, chat = nil, excludes = {},
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
    buf = buf, win = vim.api.nvim_get_current_win(), root = root, file = path:sub(#root + 2), path = path,
    row = cursor[1] - 1, column = cursor[2],
    tick = vim.api.nvim_buf_get_changedtick(buf), stamp = stamp(path),
  }
  function ctx.valid()
    return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name
      and vim.api.nvim_buf_get_changedtick(buf) == ctx.tick and not vim.bo[buf].modified
      and stamp(path) == ctx.stamp
  end
  function ctx.focused()
    if vim.api.nvim_get_current_win() ~= ctx.win or vim.api.nvim_get_current_buf() ~= ctx.buf then return false end
    local cursor = vim.api.nvim_win_get_cursor(0)
    return cursor[1] == ctx.row + 1 and cursor[2] == ctx.column
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
      if ctx.valid() and ctx.focused() then action(ctx, client) end
    end)
  end)
  if not success then notify(tostring(err)) end
end

local function checked(ctx, callback)
  return function(result, err)
    if err then notify(err); return end
    if not ctx.valid() or not ctx.focused() then return end
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
      require('hodocode.tree').open(ctx, client, f, M.config)
    end)
  end)
end

function M.follow()
  with_context(function(ctx, client)
    at_cursor(ctx, client, function(f)
      client:request('calls', { ['function'] = f.ID }, checked(ctx, function(result)
        if vim.api.nvim_get_current_buf() ~= ctx.buf then return end
        local cursor = vim.api.nvim_win_get_cursor(0)
        if cursor[1] ~= ctx.row + 1 or cursor[2] ~= ctx.column then return end
        local matches = {}
        for _, site in ipairs(result.calls) do
          if site.Line == ctx.row + 1 and site.Column <= ctx.column + 1 and ctx.column + 1 < site.EndColumn then
            matches[#matches + 1] = site
          end
        end
        if #matches ~= 1 then notify(#matches == 0 and 'カーソルを呼び出し名の上に置いてください' or '複数の呼び出し候補が重なるため移動できません'); return end
        local site = matches[1]
        if site.Unknown then
          local reason = site.Reason and site.Reason ~= '' and site.Reason or ((site.Name or '') .. ' の呼び出し先を確定できません')
          if type(site.Candidates) == 'table' and #site.Candidates > 0 then reason = reason .. ' 候補: ' .. table.concat(site.Candidates, ', ') end
          notify('未解決: ' .. reason); return
        end
        local target = result.Targets[site.To]
        if not target then notify('呼び出し先はローカルの解析対象外です'); return end
        require('hodocode.ui').jump(ctx.root, target)
      end))
    end)
  end)
end

function M.graph()
  with_context(function(ctx, client)
    client:request('functions', {}, checked(ctx, function(functions)
      local current
      for _, f in ipairs(functions) do
        if f.File == ctx.file and f.Line <= ctx.row + 1 and f.End >= ctx.row + 1 then
          if not current or f.End - f.Line < current.End - current.Line then current = f end
        end
      end
      require('hodocode.graph').open(ctx, client, current, M.config)
    end))
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
  require('hodocode.tree').clear()
  require('hodocode.client').stop_all()
  with_context(function() vim.notify('HodoCode: 再解析しました') end)
end

function M.agent(prompt)
  require('hodocode.agent').run(M.config, prompt)
end

function M.diff()
  require('hodocode.agent').diff()
end

function M.explain(prompt)
  require('hodocode.explain').run(M.config, prompt)
end

function M.chat()
  require('hodocode.chat').open(M.config)
end

function M.notes_toggle()
  require('hodocode.explain').toggle()
end

function M.notes_clear()
  require('hodocode.explain').clear()
end

function M.notes_show()
  require('hodocode.explain').show()
end

function M.cancel()
  require('hodocode.agent').stop()
  require('hodocode.explain').stop()
  require('hodocode.chat').stop()
end

function M.mode()
  require('hodocode.mode').start()
end

function M.exit_mode()
  require('hodocode.mode').stop()
end

function M.setup(options)
  require('hodocode.mode').stop()
  require('hodocode.tree').clear()
  require('hodocode.client').stop_all()
  M.cancel()
  require('hodocode.explain').clear()
  M.config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), options or {})
  assert(type(M.config.backend) == 'table' and #M.config.backend > 0, 'backend must be an argv list')
  for _, key in ipairs({ 'timeout_ms', 'max_response_bytes', 'agent_timeout_ms', 'max_agent_bytes' }) do
    local value = M.config[key]
    assert(type(value) == 'number' and value > 0 and value == math.floor(value), key .. ' must be a positive integer')
  end
  for _, key in ipairs({ 'backend', 'agent', 'explain_agent', 'chat' }) do
    local argv = M.config[key]
    assert(argv == nil or (type(argv) == 'table' and #argv > 0 and type(argv[1]) == 'string' and argv[1] ~= ''), key .. ' must be an argv list')
    for _, arg in ipairs(argv or {}) do assert(type(arg) == 'string', 'command arguments must be strings') end
  end
  assert(vim.tbl_contains({ 'auto', 'native', 'snacks' }, M.config.tree), 'tree must be auto, native or snacks')
  assert(M.config.graph_renderer == nil or type(M.config.graph_renderer) == 'function', 'graph_renderer must be a function')
  assert(type(M.config.excludes) == 'table', 'excludes must be a list')
  for _, pattern in ipairs(M.config.excludes) do assert(type(pattern) == 'string', 'excludes must contain strings') end
  local group = vim.api.nvim_create_augroup('HodoCode', { clear = true })
  vim.api.nvim_create_autocmd('BufWritePost', { group = group, callback = function()
    require('hodocode.tree').clear()
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
    M.cancel()
  end })
end

return M
