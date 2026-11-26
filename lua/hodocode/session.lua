local M = {}
local serial = 0
local function fresh()
  serial = serial + 1
  return { id = tostring((vim.uv or vim.loop).hrtime()) .. '-' .. serial, history = {}, request = nil, last_status = nil }
end
local current = fresh()

function M.get() return current end
function M.history() return vim.deepcopy(current.history) end
function M.changed()
  vim.api.nvim_exec_autocmds('User', { pattern = 'HodoCodeSessionChanged', modeline = false })
end
function M.append(role, content, metadata)
  local turn = vim.deepcopy(metadata or {})
  turn.role, turn.content = role, content
  current.history[#current.history + 1] = turn
  return turn
end
function M.reset()
  current = fresh()
  M.changed()
end
return M
