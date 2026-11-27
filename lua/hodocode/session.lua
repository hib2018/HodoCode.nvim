local M = {}
local uv = vim.uv or vim.loop
local serial = 0
local function fresh(root)
  serial = serial + 1
  return { id = tostring(uv.hrtime()) .. '-' .. serial, history = {}, request = nil, last_status = nil, root = root }
end
local legacy = fresh()
local current, projects = legacy, {}

local function real(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p')):gsub('/+$', '')
  if path == '' then return '/' end
  local resolved = uv.fs_realpath(path)
  if resolved then return vim.fs.normalize(resolved) end
  local parent = vim.fs.dirname(path)
  if parent == path then return path end
  return vim.fs.joinpath(real(parent), vim.fs.basename(path))
end

local function contains(root, path)
  return path == root or path:sub(1, #root + (root == '/' and 0 or 1)) == (root == '/' and '/' or root .. '/')
end

function M.project(config, buf)
  if not vim.api.nvim_buf_is_valid(buf) then return nil, 'invalid_buffer' end
  local path = vim.api.nvim_buf_get_name(buf)
  if path == '' then return nil, 'invalid_buffer' end
  path = real(path)
  if config.root and config.root ~= '' then
    local root = real(config.root)
    if not contains(root, path) then return nil, 'outside_root' end
    return root
  end
  local dir = vim.fs.dirname(path)
  local marker = vim.fs.find({ '.git', 'go.mod', 'package.json', 'Cargo.toml', 'pyproject.toml' }, { path = dir, upward = true })[1]
  return marker and real(vim.fs.dirname(marker)) or dir
end

function M.get() return current end
function M.history(target) return vim.deepcopy((target or current).history) end
function M.changed()
  vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeSessionChanged', modeline = false })
end
function M.select(root)
  if current.root == root then return current end
  if current.request or legacy.request then return nil, 'busy' end
  for _, state in pairs(projects) do if state.request then return nil, 'busy' end end
  projects[root] = projects[root] or fresh(root)
  current = projects[root]
  M.changed()
  return current
end
function M.activate(config, buf)
  if config.agent_transport ~= 'acp' then
    if current ~= legacy and current.request then return nil, 'busy' end
    current = legacy
    return current
  end
  local root, err = M.project(config, buf)
  if not root then return nil, err end
  return M.select(root)
end
function M.append(role, content, metadata, target)
  local turn = vim.deepcopy(metadata or {})
  turn.role, turn.content = role, content
  target = target or current
  target.history[#target.history + 1] = turn
  return turn
end
function M.reset()
  legacy = fresh()
  current, projects = legacy, {}
  M.changed()
end
return M
