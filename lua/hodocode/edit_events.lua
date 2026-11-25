local M = {}

M.codes = { timeout = true, cancelled = true, authentication = true, rate_limit = true,
  transport = true, provider_exit = true, invalid_json = true, invalid_response = true,
  size_limit = true, spawn_failed = true, invalid_patch = true, version_mismatch = true,
  conflict = true, process_exit = true, configuration_error = true, internal_error = true }
local phases = { starting = true, waiting = true, received = true, validating = true }
local function elapsed(value)
  return value == nil or (type(value) == 'number' and value >= 0 and value < math.huge)
end
local function keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end
local function response(value, terminal)
  if type(value) ~= 'table' or type(value.message) ~= 'string' or value.message:find('\0', 1, true)
    or (value.content ~= nil and type(value.content) ~= 'string')
    or (value.edits ~= nil and type(value.edits) ~= 'table')
    or (value.content ~= nil and value.edits ~= nil) then return false end
  if value.version ~= nil and (type(value.version) ~= 'string' or not value.version:match('^[0-9a-f]+$') or #value.version ~= 64) then return false end
  if (terminal or value.edits ~= nil) and value.version == nil then return false end
  return not terminal or keys(value, { event = true, version = true, message = true, edits = true, content = true })
end

function M.new(limit, on_status)
  local parser = { bytes = 0, pending = '', legacy = '', mode = nil }
  function parser:line(line)
    if self.failure then return end
    local ok, value = pcall(vim.json.decode, line)
    if not ok or type(value) ~= 'table' or self.terminal then self.failure = 'invalid_response'; return end
    if value.event == 'status' and phases[value.phase] and elapsed(value.elapsed_ms)
      and keys(value, { event = true, phase = true, elapsed_ms = true }) then
      if on_status then on_status(value.phase) end
    elseif value.event == 'result' and response(value, true) then
      self.terminal = value
    elseif value.event == 'error' and M.codes[value.code] and elapsed(value.elapsed_ms)
      and keys(value, { event = true, code = true, message = true, elapsed_ms = true }) then
      self.terminal = value
    else self.failure = 'invalid_response' end
  end
  function parser:feed(chunk)
    if self.failure then return nil, self.failure end
    self.bytes = self.bytes + #chunk
    if self.bytes > limit then self.failure = 'size_limit'; return nil, self.failure end
    if self.mode == 'legacy' then self.legacy = self.legacy .. chunk; return true end
    self.pending = self.pending .. chunk
    while true do
      local ending = self.pending:find('\n', 1, true)
      if not ending then break end
      local line = self.pending:sub(1, ending - 1)
      self.pending = self.pending:sub(ending + 1)
      if self.mode == nil then
        local ok, value = pcall(vim.json.decode, line)
        if ok and type(value) == 'table' and value.event ~= nil then self.mode = 'events'
        else self.mode = 'legacy'; self.legacy = line .. '\n' .. self.pending; self.pending = ''; return true end
      end
      self:line(line)
      if self.failure then return nil, self.failure end
    end
    return true
  end
  function parser:finish()
    if self.failure then return nil, self.failure end
    if self.mode == 'events' then
      if self.pending ~= '' then self:line(self.pending) end
      if self.failure or not self.terminal then return nil, self.failure or 'invalid_response' end
      return self.terminal
    end
    local ok, value = pcall(vim.json.decode, self.mode == 'legacy' and self.legacy or self.pending)
    if ok and type(value) == 'table' and value.event ~= nil then
      self:line(self.pending)
      if not self.failure and self.terminal then return self.terminal end
    elseif ok and response(value, false) then return value end
    return nil, 'invalid_response'
  end
  return parser
end
return M
