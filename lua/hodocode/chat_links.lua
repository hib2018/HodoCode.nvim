local M = {}
local uv = vim.uv or vim.loop
local realpath = require('hodocode.session').realpath

local function contains(root, path)
  return path == root or path:sub(1, #root + (root == '/' and 0 or 1)) == (root == '/' and '/' or root .. '/')
end

local function valid_line(line)
  return type(line) == 'number' and line >= 1 and line <= 2147483647 and line == math.floor(line)
end

local function root_path(root)
  if type(root) == 'string' and root ~= '' then return realpath(root) end
end

local function target(root, path)
  return path:sub(1, 1) == '/' and path or root .. '/' .. path
end

-- Columns are Lua byte offsets converted to Neovim's zero-based convention.
local function parse(lines, root, references)
  local links = {}
  if type(root) ~= 'string' or root == '' then return links end
  local function add(row, text, first, last, quoted)
    local token = text:sub(first, last)
    if token:find('://', 1, true) then return end
    local path, digits, finish = token:match('^(.-):(%d+)()')
    if not path or path == '' or #path > 4096 or path:find(':', 1, true) or path:find('[%z\r\n]') then return end
    local suffix = token:sub(finish, finish)
    if suffix ~= '' and not suffix:match('[%p]') then return end
    if not quoted and path:find('%s') then return end
    local literal = path .. ':' .. digits
    links[#links + 1] = { row = row, col = first - 1, end_col = first + finish - 2,
      path = path, line = tonumber(digits), root = root, reference = references and references[literal] }
  end
  for row, text in ipairs(lines) do
    local cursor = 1
    while cursor <= #text do
      local first, last = text:find('`[^`]+`', cursor)
      local stop = first and first - 1 or #text
      local pos = cursor
      while pos <= stop do
        local a, b = text:find("[^%s`<>%[%]%(%){}\"',;!?*]+", pos)
        if not a or a > stop then break end
        b = math.min(b, stop)
        add(row, text, a, b, false)
        pos = b + 1
      end
      if not first then break end
      add(row, text, first + 1, last - 1, true)
      cursor = last + 1
    end
  end
  return links
end

local function snapshot(content)
  local lines = vim.split(content, '\n', { plain = true })
  if content:sub(-1) == '\n' then table.remove(lines) end
  if #lines == 0 then lines = { '' } end
  return lines
end

local function anchor(reference, lines, version, row)
  if not valid_line(row) or row > #lines then reference.invalid_line = true; return end
  local first, last = math.max(1, row - 2), math.min(#lines, row + 2)
  reference.version = version
  reference.context, reference.offset = {}, row - first
  for i = first, last do reference.context[#reference.context + 1] = lines[i] end
end

function M.capture(message, root, sources)
  root = root_path(root)
  if not root then return {} end
  local known, prepared, targets, references = {}, {}, {}, {}
  for path, content in pairs(sources or {}) do
    if type(path) == 'string' and path:sub(1, 1) == '/' and type(content) == 'string' then
      known[realpath(path)] = content
    end
  end
  local lines = vim.split(message or '', '\n', { plain = true })
  for _, link in ipairs(parse(lines, root)) do
    if not targets[link.path] then targets[link.path] = realpath(target(root, link.path)) end
    local path = targets[link.path]
    local reference = { root = root, path = path }
    local content = contains(root, path) and known[path]
    if content then
      if not prepared[path] then prepared[path] = { lines = snapshot(content), version = vim.fn.sha256(content) } end
      local source = prepared[path]
      anchor(reference, source.lines, source.version, link.line)
    end
    references[lines[link.row]:sub(link.col + 1, link.end_col)] = reference
  end
  return references
end

function M.scan(lines, root, references)
  return parse(lines, root, references)
end

local function resolve(link)
  if type(link) ~= 'table' or not valid_line(link.line) then return nil, '行番号が不正です' end
  if type(link.path) ~= 'string' or link.path == '' or #link.path > 4096 or link.path:find('%z') then
    return nil, 'パスが不正です'
  end
  local reference = link.reference
  if reference and reference.invalid_line then return nil, '回答時のソースに存在しない行番号です' end
  local recorded = reference and reference.root or link.root
  if type(recorded) ~= 'string' or recorded == '' or recorded:sub(1, 1) ~= '/' then
    return nil, '回答のプロジェクトルートがありません'
  end
  local root = uv.fs_realpath(recorded)
  if not root or root ~= recorded or not uv.fs_stat(root) or uv.fs_stat(root).type ~= 'directory' then
    return nil, 'プロジェクトルートが変更または削除されています'
  end
  local path = uv.fs_realpath(target(root, link.path))
  if not path or not contains(root, path) then return nil, 'ファイルが存在しないかプロジェクト外です' end
  if reference and reference.path ~= path then return nil, 'リンク先が変更されています' end
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return nil, '通常のファイルではありません' end
  local buf
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(candidate) and vim.bo[candidate].buftype == '' then
      local name = vim.api.nvim_buf_get_name(candidate)
      if name ~= '' and uv.fs_realpath(name) == path then buf = candidate; break end
    end
  end
  if not buf then
    buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
  end
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= '' then return nil, 'ファイルを読み込めません' end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row = link.line
  if reference and reference.version then
    local content = table.concat(lines, '\n') .. (vim.bo[buf].endofline and '\n' or '')
    if vim.fn.sha256(content) ~= reference.version then
      local context, found = reference.context, nil
      if type(context) ~= 'table' or #context == 0 then return nil, '移動先の文脈がありません' end
      for first = 1, #lines - #context + 1 do
        local matches = true
        for i, text in ipairs(context) do if lines[first + i - 1] ~= text then matches = false; break end end
        if matches then
          if found then return nil, '移動先の文脈が複数あります' end
          found = first + reference.offset
        end
      end
      if not found then return nil, '変更により移動先の文脈が見つかりません' end
      row = found
    end
  end
  if not valid_line(row) or row > #lines then return nil, '行番号がファイルの範囲外です' end
  return { buf = buf, row = row, path = path }
end

function M.resolve(link)
  local ok, result, err = pcall(resolve, link)
  if not ok then return nil, 'リンク先を開けません: ' .. tostring(result) end
  return result, err
end

return M
