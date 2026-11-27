local M = {}

local function integer(value)
  return type(value) == 'number' and value == value and math.abs(value) <= 9007199254740991
    and value % 1 == 0
end

local function rpc_error(value)
  return type(value) == 'table' and integer(value.code) and type(value.message) == 'string'
end

function M.start(argv, cwd, opts)
  opts = opts or {}
  if type(opts) ~= 'table' then return nil, 'invalid_options' end
  local limit = opts.max_bytes == nil and 1024 * 1024 or opts.max_bytes
  if type(argv) ~= 'table' or not vim.islist(argv) or #argv == 0
    or (cwd ~= nil and type(cwd) ~= 'string') or not integer(limit) or limit < 1 then
    return nil, 'invalid_options'
  end
  for _, name in ipairs({ 'on_notification', 'on_request', 'on_exit', 'on_error' }) do
    if opts[name] ~= nil and type(opts[name]) ~= 'function' then return nil, 'invalid_options' end
  end
  for _, arg in ipairs(argv) do
    if type(arg) ~= 'string' or arg:find('\0', 1, true) then return nil, 'invalid_options' end
  end
  local peer, pending = {}, {}
  local job, closed, exited = nil, false, false
  local next_id, count, partial, stderr_bytes = 0, 0, '', 0
  local fail

  local function invoke(callback, ...)
    if callback and not pcall(callback, ...) then fail('callback_failed') end
  end

  local function shutdown(reason)
    if closed then return end
    closed, partial = true, ''
    local waiting = pending
    pending, count = {}, 0
    if job then pcall(vim.fn.jobstop, job) end
    for _, callback in pairs(waiting) do pcall(callback, nil, reason) end
  end

  fail = function(code)
    if closed then return end
    shutdown(code)
    if opts.on_error then pcall(opts.on_error, code) end
  end

  local function send(message)
    if closed then return nil, 'closed' end
    local ok, text = pcall(vim.json.encode, message)
    if not ok then fail('invalid_message'); return nil, 'invalid_message' end
    if #text > limit then fail('message_too_large'); return nil, 'message_too_large' end
    local written
    ok, written = pcall(vim.fn.chansend, job, text .. '\n')
    if not ok or type(written) ~= 'number' or written ~= #text + 1 then
      fail('write_failed')
      return nil, 'write_failed'
    end
    return true
  end

  function peer.request(method, params, callback)
    if type(callback) ~= 'function' then return nil, 'invalid_message' end
    local reason = closed and 'closed' or count >= 16 and 'pending_limit'
      or (type(method) ~= 'string' or (params ~= nil and type(params) ~= 'table')) and 'invalid_message'
    if reason then invoke(callback, nil, reason); return nil, reason end
    next_id = next_id + 1
    pending[next_id], count = callback, count + 1
    local id = next_id
    local ok, err = send({ jsonrpc = '2.0', id = id, method = method, params = params })
    if not ok then return nil, err end
    return id
  end

  function peer.notify(method, params)
    if type(method) ~= 'string' or (params ~= nil and type(params) ~= 'table') then
      return nil, 'invalid_message'
    end
    return send({ jsonrpc = '2.0', method = method, params = params })
  end

  function peer.close() shutdown('closed') end
  function peer.alive() return not closed end

  local function receive(line)
    local ok, message = pcall(vim.json.decode, line)
    if not ok or type(message) ~= 'table' or message.jsonrpc ~= '2.0' then
      fail('invalid_message'); return
    end
    local id, method = message.id, message.method
    local has_result, has_error = message.result ~= nil, message.error ~= nil
    if method ~= nil then
      if type(method) ~= 'string' or has_result or has_error
        or (id ~= nil and not integer(id) and not (type(id) == 'string' and #id <= 256))
        or (message.params ~= nil and type(message.params) ~= 'table') then
        fail('invalid_message'); return
      end
      if id == nil then
        invoke(opts.on_notification, method, message.params)
      else
        local responded = false
        local function respond(result, err)
          if closed then return nil, 'closed' end
          if responded then return nil, 'already_responded' end
          responded = true
          if err ~= nil and not rpc_error(err) then fail('invalid_message'); return nil, 'invalid_message' end
          local response = { jsonrpc = '2.0', id = id }
          if err ~= nil then response.error = err else response.result = result == nil and vim.NIL or result end
          return send(response)
        end
        if opts.on_request then
          invoke(opts.on_request, method, message.params, respond)
        else
          respond(nil, { code = -32601, message = 'Method not found' })
        end
      end
    else
      if not integer(id) or has_result == has_error or (has_error and not rpc_error(message.error))
        or message.params ~= nil or not pending[id] then
        fail('invalid_message'); return
      end
      local callback = pending[id]
      pending[id], count = nil, count - 1
      invoke(callback, message.result, message.error)
    end
  end

  local ok, result = pcall(vim.fn.jobstart, argv, {
    cwd = cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if closed then return end
      for index, piece in ipairs(data) do
        if #partial + #piece > limit then fail('message_too_large'); return end
        partial = partial .. piece
        if index < #data then
          local line = partial
          partial = ''
          receive(line)
          if closed then return end
        end
      end
    end,
    on_stderr = function(_, data)
      if closed then return end
      for index, piece in ipairs(data) do
        stderr_bytes = stderr_bytes + #piece + (index < #data and 1 or 0)
        if stderr_bytes > limit then fail('stderr_limit'); return end
      end
    end,
    on_exit = function(_, code)
      if exited then return end
      exited = true
      if not closed then fail('process_exited') end
      if opts.on_exit then pcall(opts.on_exit, code) end
    end,
  })
  if not ok or type(result) ~= 'number' or result <= 0 then
    closed = true
    return nil, 'start_failed'
  end
  job = result
  return peer
end

return M
