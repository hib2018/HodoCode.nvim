local M = {}
local uv = vim.uv or vim.loop

function M.notify(message)
  vim.notify('HodoCode: ' .. message, vim.log.levels.ERROR)
end

function M.argv(argv)
  if type(argv) ~= 'table' or #argv == 0 then return false end
  for _, arg in ipairs(argv) do
    if type(arg) ~= 'string' or arg:find('\0', 1, true) then return false end
  end
  return true
end

local function disk(path)
  local stat = uv.fs_stat(path)
  return stat and table.concat({ stat.dev, stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.ctime.sec, stat.ctime.nsec }, ':') or ''
end

local function identity(path)
  local stat = uv.fs_stat(path)
  return stat and (stat.dev .. ':' .. stat.ino) or ''
end

function M.capture(config)
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or name == '' then return nil, '通常の名前付きファイルバッファで実行してください' end
  local path = vim.fs.normalize(name)
  local root = config.root or vim.fs.root(vim.fs.dirname(path), { '.git', 'go.mod', 'package.json', 'Cargo.toml', 'pyproject.toml' }) or vim.fs.dirname(path)
  root = uv.fs_realpath(root)
  if not root then return nil, '解析ルートが存在しません' end
  -- Keep child aliases intact: prepare-buffer must see and reject symlinks below root.
  local prefix = root == '/' and '/' or root .. '/'
  if path:sub(1, #prefix) ~= prefix then return nil, 'ファイルが解析ルートの外にあります' end
  local root_identity = identity(root)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local eol, tick, stamp = vim.bo[buf].endofline, vim.api.nvim_buf_get_changedtick(buf), disk(path)
  local content = table.concat(lines, '\n') .. (eol and '\n' or '')
  if content:find('\0', 1, true) then return nil, 'NULを含むソースは送信できません' end
  local ctx = { buf = buf, root = root, file = path:sub(#prefix + 1), content = content, count = #lines,
    version = vim.fn.sha256(content) }
  function ctx.valid()
    return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name
      and vim.bo[buf].buftype == '' and vim.bo[buf].endofline == eol
      and vim.api.nvim_buf_get_changedtick(buf) == tick and disk(path) == stamp and identity(root) == root_identity
  end
  return ctx
end

function M.guard(state, callback)
  return function(...)
    local ok = pcall(callback, ...)
    if not ok then
      M.cancel(state)
      if state.on_error then state.on_error() else M.notify('AI trial callback failed') end
    end
  end
end

-- Streaming callbacks bound retained output, including stderr, before JSON decoding.
function M.system(state, argv, options, limit, callback, prepare_errors)
  callback = M.guard(state, callback)
  local stdout, stderr, failure = '', '', nil
  local function stream(which)
    return function(err, chunk)
      if err then failure = 'CLI stream error' end
      if chunk and not failure then
        local old = which == 'stdout' and stdout or stderr
        if #old + #chunk > limit then failure = 'CLI output exceeds size limit'
        elseif which == 'stdout' then stdout = old .. chunk else stderr = old .. chunk end
      end
      if failure and state.process then state.process:kill(9) end
    end
  end
  options.stdout, options.stderr = stream('stdout'), stream('stderr')
  local ok, process = pcall(vim.system, argv, options, vim.schedule_wrap(function(result)
    state.process = nil
    if state.cancelled then return end
    if failure then callback(nil, failure); return end
    -- Never echo CLI stderr: it can contain a provider's accidental raw context.
    if result.code ~= 0 then
      local reason = 'CLI exited (' .. result.code .. ')'
      if prepare_errors then
        local diagnostics = {
          { 'unsupported source file', 'Unsupported source language; choose a supported source file' },
          { 'excluded or blocked', 'File is excluded or blocked; check excludes and the source path' },
          { 'must not contain symlinks', 'Source path contains a symlink; open a non-aliased project path' },
          { 'exceeds', 'Prepare size limit exceeded (source/prepared JSON: 128 KiB)' },
          { 'exclude', 'Invalid excludes; use project-relative glob patterns' },
          { 'redact:', 'Source masking failed; check source syntax' },
          { 'no function at cursor', 'カーソル位置に関数がありません。関数内で実行してください' },
        }
        for _, entry in ipairs(diagnostics) do
          if stderr:find(entry[1], 1, true) then reason = entry[2]; break end
        end
      end
      callback(nil, reason); return
    end
    local decoded, value = pcall(vim.json.decode, stdout)
    if not decoded then callback(nil, 'CLI returned invalid JSON'); return end
    callback(value)
  end))
  if not ok then callback(nil, 'CLI could not start'); return end
  state.process = process
  if failure or state.cancelled then process:kill(9) end
end

function M.tempdir()
  local dir = uv.fs_mkdtemp(vim.fn.stdpath('cache') .. '/hodocode-ai-XXXXXX')
  if dir and not uv.fs_chmod(dir, 448) then uv.fs_rmdir(dir); return nil end
  return dir
end

function M.remove_dir(dir)
  if dir and not uv.fs_rmdir(dir) then
    vim.notify('HodoCode: adapter directory remains; inspect and remove manually: ' .. dir, vim.log.levels.WARN)
  end
end

function M.clean_cwd(state)
  M.remove_dir(state.cwd)
  state.cwd = nil
end

function M.cancel(state)
  if not state then return false end
  state.cancelled = true
  if state.process then state.process:kill(9) end
  M.clean_cwd(state)
  return true
end

function M.run(state, config, ctx, purpose, callback, row, scope)
  if not M.argv(config.backend) then callback(nil, 'backend must be an argv list'); return end
  local payload = vim.json.encode({ file = ctx.file, content = ctx.content, purpose = purpose,
    excludes = config.excludes or {}, row = scope ~= 'line' and row or nil })
  if #purpose > 8192 or #payload > 1024 * 1024 then callback(nil, 'prepare request exceeds size limit'); return end
  local argv = vim.deepcopy(config.backend)
  vim.list_extend(argv, { 'prepare-buffer', '--root', ctx.root })
  M.system(state, argv, { cwd = ctx.root, stdin = payload, text = true, timeout = config.timeout_ms or 120000 },
    math.min(config.max_agent_bytes or 131072, 131072) + 1, function(result, err)
      if err then callback(nil, err); return end
      if not ctx.valid() then callback(nil, 'ソースが変更されました。再実行してください'); return end
      if type(result) ~= 'table' or result.file ~= ctx.file or result.version ~= ctx.version
        or result.purpose ~= purpose or type(result.language) ~= 'string' or type(result.content) ~= 'string'
        or type(result.line_count) ~= 'number' or result.line_count ~= select(2, ctx.content:gsub('\n', '')) + 1
        or result.content:find('\0', 1, true) then
        callback(nil, 'Invalid prepare-buffer response'); return
      end
      local envelope = { prompt = purpose, buffer = { file = result.file, path = result.file,
        content = result.content, version = result.version, language = result.language } }
      if row then
        local first, last = result.start_line, result.end_line
        if scope == 'line' then first, last = row, row end
        if type(first) ~= 'number' or type(last) ~= 'number' or first ~= math.floor(first) or last ~= math.floor(last)
          or first < 1 or first > row or last < row or last > ctx.count then
          callback(nil, 'Invalid function scope; rebuild the HodoCode backend'); return
        end
        local lines = vim.split(result.content, '\n', { plain = true })
        if #lines < last then callback(nil, 'Invalid function scope'); return end
        envelope.buffer.content = table.concat(vim.list_slice(lines, first, last), '\n')
        envelope.buffer.start_line, envelope.buffer.end_line = first, last
      end
      local encoded = vim.json.encode(envelope)
      if #encoded > math.min(config.max_agent_bytes or 131072, 131072) then
        callback(nil, 'Prepared context exceeds size limit'); return
      end
      callback(envelope, nil, encoded)
    end, true)
end

return M
