local M = {}
local clients = {}

local function fail(self, message)
  local pending = self.pending
  self.pending = {}
  for _, entry in pairs(pending) do
    entry.timer:stop()
    entry.timer:close()
    entry.callback(nil, message)
  end
end

function M.start(root, config)
  local key = root
  if clients[key] and not clients[key].closed then return clients[key] end
  local self = { root = root, pending = {}, next_id = 0, partial = '', closed = false }
  function self:request(method, params, callback)
    if self.closed then callback(nil, 'backend stopped'); return end
    self.next_id = self.next_id + 1
    local id = self.next_id
    local timer = (vim.uv or vim.loop).new_timer()
    self.pending[id] = { callback = callback, timer = timer }
    timer:start(config.timeout_ms, 0, vim.schedule_wrap(function()
      if self.pending[id] then
        self:stop('backend request timed out; restart with :HodoCodeReload')
      end
    end))
    local ok, err = pcall(vim.fn.chansend, self.job, vim.json.encode({ id = id, method = method, params = params and next(params) and params or vim.empty_dict() }) .. '\n')
    if not ok then self:stop(tostring(err)) end
    return id
  end
  function self:stop(reason)
    if self.closed then return end
    self.closed = true
    fail(self, reason or 'backend stopped')
    if self.job and self.job > 0 then vim.fn.jobstop(self.job) end
    clients[key] = nil
  end
  local command = vim.deepcopy(config.backend)
  vim.list_extend(command, { 'serve', '--root', root, '--language', config.language })
  self.job = vim.fn.jobstart(command, {
    cwd = root, stdout_buffered = false,
    on_stdout = function(_, data)
      if self.closed then return end
      local text = self.partial .. table.concat(data, '\n')
      self.partial = ''
      while true do
        local boundary = text:find('\n', 1, true)
        if not boundary then self.partial = text; break end
        local line = text:sub(1, boundary - 1)
        text = text:sub(boundary + 1)
        if #line > config.max_response_bytes then self:stop('backend response too large'); return end
        local ok, response = pcall(vim.json.decode, line)
        if not ok or type(response) ~= 'table' or type(response.id) ~= 'number' then
          self:stop('malformed backend response'); return
        end
        local entry = self.pending[response.id]
        if entry then
          self.pending[response.id] = nil
          entry.timer:stop()
          entry.timer:close()
          local err = type(response.error) == 'string' and response.error or nil
          entry.callback(response.result, err)
        end
      end
      if #self.partial > config.max_response_bytes then self:stop('backend response too large') end
    end,
    on_stderr = function(_, data)
      self.stderr = ((self.stderr or '') .. table.concat(data, '\n')):sub(-8192)
    end,
    on_exit = function(_, code)
      if not self.closed then self:stop('backend exited (' .. code .. '): ' .. (self.stderr or '')) end
    end,
  })
  if self.job <= 0 then
    self.closed = true
    error('HodoCode backend could not start: ' .. command[1])
  end
  clients[key] = self
  return self
end

function M.stop_all()
  local current = vim.tbl_values(clients)
  for _, client in ipairs(current) do client:stop() end
end

return M
