local M = {}
local rpc = require('hodocode.acp_rpc')
local uv = vim.uv or vim.loop
local records = {}
local shutting_down = false
local instructions = [[You are answering inside HodoCode. You may use only read_file, grep_files and glob_files to discover and read relevant source files inside Metadata.repository_root, on demand. Respect .gitignore; skip .git, node_modules, build, dist, target, .cache, credentials (.env files and private keys), binary files and files larger than 1 MiB. Never use filesystem writes, shell commands, MCP or other tools. Embedded source snapshots are authoritative, including unsaved changes: never replace them with disk versions. Metadata.path is the only editable file; all other files and snapshots are read-only context. Do not modify files directly. For chat, answer naturally in Markdown. For edit, after any read tools finish, return only strict JSON: {"message":"explanation","edits":[{"old_text":"exact source","new_text":"replacement"}]}, or {"message":"explanation","content":"complete replacement"}. Never use Markdown fences. At most 256 edits.]]

local function call(callback, ...)
  if callback then return pcall(callback, ...) end
  return true
end
local function now() return uv.hrtime() / 1000000 end
local function root_path(root)
  if type(root) ~= 'string' or root:sub(1, 1) ~= '/' or root:find('\0', 1, true) then return nil end
  return uv.fs_realpath(root) or vim.fs.normalize(root)
end
local function stop_timer(timer)
  if timer then timer:stop(); if not timer:is_closing() then timer:close() end end
end
local function timer(ms, callback)
  local t = uv.new_timer()
  t:start(ms, 0, vim.schedule_wrap(callback))
  return t
end
local function bounded(value, limit)
  return type(value) == 'string' and not value:find('\0', 1, true) and #value <= limit
end
local function keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end
local function response(text, payload, limit)
  if payload.intent == 'chat' then
    if not bounded(text, limit) then return nil, 'invalid_response' end
    return { message = text }
  end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= 'table' or not keys(value, { message = true, edits = true, content = true })
    or not bounded(value.message, limit) or (value.content ~= nil and value.edits ~= nil) then
    return nil, 'invalid_response'
  end
  if value.content ~= nil and not bounded(value.content, limit) then return nil, 'invalid_response' end
  if value.edits ~= nil then
    if type(value.edits) ~= 'table' or not vim.islist(value.edits) or #value.edits > 256 then return nil, 'invalid_response' end
    for _, edit in ipairs(value.edits) do
      if type(edit) ~= 'table' or not keys(edit, { old_text = true, new_text = true })
        or not bounded(edit.old_text, limit) or not bounded(edit.new_text, limit) then return nil, 'invalid_response' end
    end
  end
  value.version = vim.fn.sha256(payload.buffer.content)
  return value
end
local function deny(respond) respond({ outcome = { outcome = 'cancelled' } }) end
local function flush_permissions(record)
  local pending = record.permissions
  record.permissions = {}
  for _, respond in pairs(pending) do deny(respond) end
end
local function close_record(record)
  local peer, sid, caps = record.peer, record.sid, record.caps
  record.peer, record.connection = nil, nil
  flush_permissions(record)
  if peer then
    if peer.alive() and sid and caps and caps.close then
      peer.request('session/close', { sessionId = sid }, function() end)
    end
    peer.close()
  end
end

function M.prompt(config, payload, opts)
  if shutting_down then return nil, 'cancelled' end
  opts = opts or {}
  if type(config) ~= 'table' or type(payload) ~= 'table' or type(opts) ~= 'table' then return nil, 'configuration_error' end
  if config.acp_mode ~= nil and config.acp_mode ~= 'ask' then return nil, 'configuration_error' end
  local root = root_path(payload.root)
  local argv, limit = config.agent, config.max_agent_bytes or 1024 * 1024
  local timeout, cancel_timeout = config.agent_timeout_ms or 120000, config.acp_cancel_timeout_ms or 3000
  if not root or type(argv) ~= 'table' or not vim.islist(argv) or #argv == 0
    or type(limit) ~= 'number' or limit < 1 or limit >= math.huge or limit % 1 ~= 0
    or type(timeout) ~= 'number' or timeout <= 0 or timeout >= math.huge
    or type(cancel_timeout) ~= 'number' or cancel_timeout <= 0 or cancel_timeout >= math.huge
    or not bounded(payload.prompt, limit) or (payload.intent ~= 'chat' and payload.intent ~= 'edit')
    or type(payload.buffer) ~= 'table' or not bounded(payload.buffer.content, limit)
    or type(opts.on_done) ~= 'function' then return nil, 'configuration_error' end
  for _, arg in ipairs(argv) do
    if not bounded(arg, 65536) then return nil, 'configuration_error' end
  end
  for _, name in ipairs({ 'on_chunk', 'on_status', 'on_tool', 'on_permission', 'on_disconnect' }) do
    if opts[name] ~= nil and type(opts[name]) ~= 'function' then return nil, 'configuration_error' end
  end
  payload = { root = root, prompt = payload.prompt, intent = payload.intent, request_id = payload.request_id,
    buffer = vim.deepcopy(payload.buffer) }
  local context, context_error = require('hodocode.repository').snapshots(root, type(payload.buffer.path) == 'string' and payload.buffer.path or root .. '/buffer', limit)
  if not context then return nil, context_error end
  payload.context = context
  if #vim.json.encode(payload) > limit then return nil, 'size_limit' end
  local signature = vim.json.encode(argv)
  local record = records[root]
  if record and record.busy then return nil, 'busy' end
  if record and record.signature ~= signature then
    close_record(record)
    records[root], record = nil, nil
  end
  if not record then
    record = { root = root, signature = signature, permissions = {} }
    records[root] = record
  end
  local handle = { metrics = {} }
  local began, chunks, bytes, tools, tool_count = now(), {}, 0, {}, 0
  local done, cancelled, prompt_sent = false, nil, false
  record.busy, record.metrics = handle, handle.metrics
  local finish, cancel
  finish = function(value, err)
    if done then return end
    if cancelled then value, err = nil, cancelled end
    done = true
    stop_timer(handle.timer); stop_timer(handle.cancel_timer)
    handle.timer, handle.cancel_timer = nil, nil
    handle.metrics.complete_ms = now() - began
    flush_permissions(record)
    if record.busy == handle then record.busy = nil end
    call(opts.on_done, value, err)
  end
  local function disconnect(code)
    if record.busy ~= handle or done then return end
    call(opts.on_disconnect, code)
    finish(nil, cancelled or code)
  end
  cancel = function(reason)
    if done or cancelled then return end
    cancelled = reason
    flush_permissions(record)
    if done then return end
    if record.peer and record.sid then record.peer.notify('session/cancel', { sessionId = record.sid }) end
    if done then return end
    if not prompt_sent then
      close_record(record)
      finish(nil, reason)
    else
      handle.cancel_timer = timer(cancel_timeout, function()
        if done then return end
        close_record(record)
        finish(nil, reason)
      end)
    end
  end
  function handle.cancel() cancel('cancelled') end
  handle.timer = timer(timeout, function() cancel('timeout') end)
  call(opts.on_status, 'starting')
  if done then return handle end

  local function send_prompt()
    if done or cancelled then return end
    handle.metrics.startup_ms = now() - began
    local metadata = { intent = payload.intent, path = payload.buffer.path, cursor = payload.buffer.cursor,
      request_id = payload.request_id, repository_root = root }
    local content = { { type = 'text', text = 'Current request: ' .. payload.prompt .. '\nMetadata: ' .. vim.json.encode(metadata) } }
    local function snapshot(path, text)
      if record.caps.embeddedContext then
        content[#content + 1] = { type = 'resource', resource = {
          uri = 'file://' .. path:gsub('[^%w%-%._~/]', function(c) return string.format('%%%02X', c:byte()) end),
          mimeType = 'text/plain', text = text,
        } }
      else
        content[#content + 1] = { type = 'text', text = 'Authoritative source snapshot (' .. path .. '):\n' .. text }
      end
    end
    snapshot(type(payload.buffer.path) == 'string' and payload.buffer.path or root .. '/buffer', payload.buffer.content)
    for _, source in ipairs(payload.context) do snapshot(source.path, source.content) end
    -- Agents without the systemPrompt extension still receive the same constraints each turn.
    if not record.caps.systemPrompt then table.insert(content, 1, { type = 'text', text = instructions }) end
    prompt_sent = true
    call(opts.on_status, 'waiting')
    if done or cancelled then return end
    record.peer.request('session/prompt', { sessionId = record.sid, prompt = content }, function(result, err)
      if done then return end
      if cancelled then finish(nil, cancelled); return end
      if err then finish(nil, type(err) == 'table' and 'provider_exit' or 'transport'); return end
      if type(result) ~= 'table' or result.stopReason ~= 'end_turn' then
        finish(nil, type(result) == 'table' and result.stopReason == 'cancelled' and 'cancelled' or 'invalid_response')
        return
      end
      call(opts.on_status, 'received')
      local value, code = response(table.concat(chunks), payload, limit)
      finish(value, code)
    end)
  end
  local peer = record.peer
  local hooks = {
    on_notification = function(method, params)
      if done or cancelled or method ~= 'session/update' or type(params) ~= 'table'
        or params.sessionId ~= record.sid or not prompt_sent or type(params.update) ~= 'table' then return end
      local update = params.update
      if update.sessionUpdate == 'agent_message_chunk' then
        local chunk = update.content
        if type(chunk) ~= 'table' or chunk.type ~= 'text' or type(chunk.text) ~= 'string' then return end
        bytes = bytes + #chunk.text
        if bytes > limit then cancel('size_limit'); return end
        chunks[#chunks + 1] = chunk.text
        if not handle.metrics.first_chunk_ms then handle.metrics.first_chunk_ms = now() - began end
        call(opts.on_chunk, chunk.text)
      elseif update.sessionUpdate == 'notice' then
        call(opts.on_tool, { sessionUpdate = 'notice' })
      elseif update.sessionUpdate == 'tool_call' or update.sessionUpdate == 'tool_call_update' then
        -- Only the answer after the last tool call is an edit result, not progress prose.
        if update.sessionUpdate == 'tool_call' and payload.intent == 'edit' then chunks = {} end
        local id = update.toolCallId
        if not bounded(id, 256) then return end
        if not tools[id] then
          if tool_count >= 256 then return end
          tools[id], tool_count = {}, tool_count + 1
        end
        local safe = tools[id]
        safe.toolCallId, safe.sessionUpdate = id, update.sessionUpdate
        for _, key in ipairs({ 'title', 'kind', 'status' }) do
          if bounded(update[key], 512) then safe[key] = update[key] end
        end
        call(opts.on_tool, vim.deepcopy(safe))
      end
    end,
    on_request = function(method, params, respond)
      if method ~= 'session/request_permission' then
        respond(nil, { code = -32601, message = 'Method not found' }); return
      end
      if done or cancelled or not prompt_sent or type(params) ~= 'table' or params.sessionId ~= record.sid or not opts.on_permission then
        deny(respond); return
      end
      local count = 0
      for _ in pairs(record.permissions) do count = count + 1 end
      if count >= 16 then deny(respond); return end
      local key = {}
      local answered = false
      local function answer(value)
        if answered then return end
        answered = true
        record.permissions[key] = nil
        if done or cancelled or type(value) ~= 'table' then deny(respond) else respond(value) end
      end
      local ui
      record.permissions[key] = function(value)
        if not answered then
          answered = true
          if type(ui) == 'table' and type(ui.cancel) == 'function' then pcall(ui.cancel) end
          respond(value)
        end
      end
      local ok
      ok, ui = call(opts.on_permission, params, answer)
      if not ok then answer(nil) end
    end,
    on_error = function() if record.peer == peer then record.peer = nil end; disconnect('transport') end,
    on_exit = function() if record.peer == peer then record.peer = nil end; disconnect('transport') end,
  }
  record.hooks = hooks
  if peer and peer.alive() and record.sid then send_prompt(); return handle end
  local connection = {}
  record.connection = connection
  peer = rpc.start(argv, root, {
    max_bytes = math.max(limit * 12 + 65536, 1024 * 1024),
    on_notification = function(...) if record.connection == connection then record.hooks.on_notification(...) end end,
    on_request = function(...) if record.connection == connection then record.hooks.on_request(...) end end,
    on_error = function(...) if record.connection == connection then record.hooks.on_error(...) end end,
    on_exit = function(...) if record.connection == connection then record.hooks.on_exit(...) end end,
  })
  if not peer then
    finish(nil, 'spawn_failed')
    return handle
  end
  record.peer = peer
  peer.request('initialize', {
    protocolVersion = 1,
    clientInfo = { name = 'HodoCode.nvim', version = '1' },
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false, session = { notices = vim.empty_dict() } },
  }, function(result, err)
    if done then return end
    if err then close_record(record); finish(nil, 'transport'); return end
    if type(result) ~= 'table' or result.protocolVersion ~= 1 or type(result.agentCapabilities) ~= 'table' then
      close_record(record); finish(nil, 'invalid_response'); return
    end
    local caps = result.agentCapabilities
    if (caps.sessionCapabilities ~= nil and type(caps.sessionCapabilities) ~= 'table')
      or (caps.promptCapabilities ~= nil and type(caps.promptCapabilities) ~= 'table') then
      close_record(record); finish(nil, 'invalid_response'); return
    end
    local sessions = type(caps.sessionCapabilities) == 'table' and caps.sessionCapabilities or {}
    local prompts = type(caps.promptCapabilities) == 'table' and caps.promptCapabilities or {}
    if prompts.embeddedContext ~= nil and type(prompts.embeddedContext) ~= 'boolean' then
      close_record(record); finish(nil, 'invalid_response'); return
    end
    for _, feature in ipairs({ 'resume', 'close', 'systemPrompt' }) do
      if sessions[feature] ~= nil and type(sessions[feature]) ~= 'table' then
        close_record(record); finish(nil, 'invalid_response'); return
      end
    end
    record.caps = { embeddedContext = prompts.embeddedContext == true,
      resume = type(sessions.resume) == 'table', close = type(sessions.close) == 'table',
      systemPrompt = type(sessions.systemPrompt) == 'table' }
    record.agentInfo = nil
    if type(result.agentInfo) == 'table' then
      record.agentInfo = {}
      for _, key in ipairs({ 'name', 'version', 'title' }) do
        if bounded(result.agentInfo[key], 256) then record.agentInfo[key] = result.agentInfo[key] end
      end
    end
    local method, params = 'session/new', { cwd = root, mcpServers = {} }
    if record.sid then
      if not record.caps.resume then close_record(record); finish(nil, 'resume_unsupported'); return end
      method, params.sessionId = 'session/resume', record.sid
    elseif record.caps.systemPrompt then params.systemPrompt = { { type = 'text', text = instructions } } end
    peer.request(method, params, function(session, session_err)
      if done then return end
      if session_err then close_record(record); finish(nil, method == 'session/resume' and 'resume_failed' or 'provider_exit'); return end
      if type(session) ~= 'table'
        or (method == 'session/new' and (not bounded(session.sessionId, 1024) or session.sessionId == ''))
        or (method == 'session/resume' and session.sessionId ~= nil and session.sessionId ~= record.sid) then
        close_record(record); finish(nil, 'invalid_response'); return
      end
      if type(session.modes) == 'table' and session.modes.currentModeId ~= nil and session.modes.currentModeId ~= 'ask' then
        close_record(record); finish(nil, 'configuration_error'); return
      end
      if type(session.configOptions) == 'table' then
        for _, option in ipairs(session.configOptions) do
          if type(option) == 'table' and (option.id == 'mode' or option.category == 'mode')
            and option.currentValue ~= nil and option.currentValue ~= 'ask' then
            close_record(record); finish(nil, 'configuration_error'); return
          end
        end
      end
      record.sid = session.sessionId or record.sid
      send_prompt()
    end)
  end)
  return handle
end

function M.info(root)
  local record = records[root_path(root)]
  if not record then return nil end
  return { root = record.root, sessionId = record.sid, alive = record.peer ~= nil and record.peer.alive(),
    busy = record.busy ~= nil, caps = vim.deepcopy(record.caps), agentInfo = vim.deepcopy(record.agentInfo),
    metrics = vim.deepcopy(record.metrics) }
end
function M.shutdown()
  shutting_down = true
  local old = records
  records = {}
  for _, record in pairs(old) do
    if record.busy then record.busy.cancel() end
    close_record(record)
  end
  shutting_down = false
end
return M
