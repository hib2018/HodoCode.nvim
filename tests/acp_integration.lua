local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  vim.notify = function() end
  package.loaded['hodocode.chat'] = { open = function() end }
  local refreshes, stops, cancels = 0, 0, 0
  package.loaded['hodocode.inline_diff'] = { visible = function() return true end,
    refresh = function(_, baseline) assert(baseline.lines[1] == 'disk'); refreshes = refreshes + 1 end }
  local calls = {}
  local connection = {}
  package.loaded['hodocode.acp'] = {
    prompt = function(config, payload, callbacks)
      if payload.prompt == 'launch failure' then return nil, 'configuration_error' end
      assert(config.agent_transport == 'acp')
      assert(payload.history == nil and payload.session_id == nil)
      local call = { payload = payload, callbacks = callbacks, connection = connection }
      calls[#calls + 1] = call
      return { cancel = function() cancels = cancels + 1 end }
    end,
    shutdown = function() stops = stops + 1 end,
  }
  local permission
  package.loaded['hodocode.acp_permission'] = { request = function(params, done)
    permission = params
    done({ outcome = { outcome = 'cancelled' } })
  end }
  local agent, session = require('hodocode.agent'), require('hodocode.session')
  local temp = vim.fn.tempname()
  local function project(name, marker)
    local root = temp .. '/' .. name
    vim.fn.mkdir(root .. '/nested', 'p')
    vim.fn.writefile({}, root .. '/' .. marker)
    vim.fn.writefile({ 'disk' }, root .. '/nested/source.txt')
    local buf = vim.fn.bufadd(root .. '/nested/source.txt')
    vim.fn.bufload(buf)
    return (vim.uv or vim.loop).fs_realpath(root), buf, { buf = buf }
  end
  local a, abuf, atarget = project('a', 'go.mod')
  local b, bbuf, btarget = project('b', 'package.json')
  local config = { agent_transport = 'acp', agent = { 'fake-acp' }, max_agent_bytes = 1024 * 1024,
    agent_timeout_ms = 1000, acp_cancel_timeout_ms = 30 }
  local function body(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local function last() return calls[#calls].callbacks end
  assert(session.project(config, abuf) == a)
  assert(session.project(config, bbuf) == b)
  local outside, reason = session.project({ root = a }, bbuf)
  assert(outside == nil and reason == 'outside_root')
  local history = session.history
  session.history = function() error('ACP must not copy conversation history') end
  assert(agent.run(config, 'edit A', 'edit', atarget))
  session.history = history
  local ast = session.get()
  assert(ast.request.history == nil)
  assert(ast.root == a and ast.request.cwd == nil)
  assert(calls[1].payload.root == a and calls[1].payload.buffer.content == 'disk\n')
  local changes, changed = 0, session.changed
  session.changed = function() changes = changes + 1; changed() end
  last().on_chunk('partial ')
  assert(ast.request.phase == 'streaming' and changes == 1)
  last().on_status('thinking')
  last().on_chunk('answer')
  assert(ast.request.phase == 'thinking' and changes == 3)
  session.changed = changed
  last().on_tool({ title = 'Inspect', status = 'in_progress' })
  assert(ast.request.stream == 'partial answer' and ast.request.tool.title == 'Inspect')
  assert(body(abuf) == 'disk' and #ast.history == 1)
  last().on_permission({ options = {} }, function(result) assert(result.outcome.outcome == 'cancelled') end)
  assert(permission)
  local selected, err = session.activate(config, bbuf)
  assert(selected == nil and err == 'busy' and session.get() == ast)
  last().on_done({ message = 'changed', content = 'AI', version = vim.fn.sha256('disk\n') })
  assert(body(abuf) == 'AI' and not vim.bo[abuf].endofline)
  assert(ast.request == nil and ast.history[2].status == 'applied' and refreshes == 1)
  assert(agent.baseline(abuf).lines[1] == 'disk')
  vim.api.nvim_buf_call(abuf, function() vim.cmd.undo() end)
  vim.wait(30, function() return vim.bo[abuf].endofline end, 1)
  assert(body(abuf) == 'disk' and vim.bo[abuf].endofline)
  assert(agent.run(config, 'ask B', 'chat', btarget))
  local bst = session.get()
  assert(bst ~= ast and bst.root == b and #bst.history == 1)
  last().on_done({ message = 'B answer' })
  assert(session.activate(config, abuf) == ast and #session.history() == 2)
  local aid = ast.id
  assert(session.activate(config, abuf).id == aid)
  assert(agent.run(config, 'cancel A', 'edit', atarget))
  assert(calls[1].connection == calls[3].connection)
  local cancelled = last()
  local request = ast.request
  agent.stop(); agent.stop()
  assert(cancels == 1 and request.cancelled and request.phase == 'cancelling' and request.running)
  assert(ast.request == request and ast.history[#ast.history].status == 'cancelled')
  local count = #calls
  assert(not agent.run(config, 'blocked', 'edit', atarget) and #calls == count)
  assert(select(2, session.activate(config, bbuf)) == 'busy')
  cancelled.on_chunk('late'); cancelled.on_tool({ title = 'late' })
  cancelled.on_done({ message = 'too late', content = 'NO\n' })
  assert(ast.request == nil and body(abuf) == 'disk')
  local history = #ast.history
  cancelled.on_done({ message = 'again', content = 'NO\n' })
  assert(#ast.history == history)
  assert(agent.run(config, 'conflict', 'edit', atarget))
  vim.api.nvim_buf_set_lines(abuf, 0, -1, false, { 'mine' })
  last().on_done({ message = 'bad', content = 'NO\n' })
  assert(body(abuf) == 'mine' and ast.history[#ast.history].status == 'conflict')
  assert(agent.run(config, 'bad question', 'chat', atarget))
  last().on_done({ message = 'bad', edits = { { start_line = 1, end_line = 1, text = 'NO' } } })
  assert(ast.history[#ast.history].status == 'invalid_patch')
  assert(agent.run(config, 'version', 'edit', atarget))
  last().on_done({ message = 'bad', version = 'wrong', content = 'NO\n' })
  assert(ast.history[#ast.history].status == 'version_mismatch')
  assert(not agent.run(config, 'launch failure', 'edit', atarget))
  assert(ast.request == nil and ast.history[#ast.history].status == 'configuration_error')
  for code, expected in pairs({ resume_failed = '依頼は再送していません', resume_unsupported = 'Neovimを再起動' }) do
    assert(agent.run(config, code, 'edit', atarget))
    local count = #calls
    last().on_done(nil, code)
    local turn = ast.history[#ast.history]
    assert(turn.status == code and turn.content:find(expected, 1, true))
    assert(ast.request == nil and #calls == count and body(abuf) == 'mine')
  end
  local hook = vim.api.nvim_create_autocmd('User', { pattern = 'HodoCodeAgentStatus', callback = function(ev)
    if ev.data.phase == 'validating' then vim.api.nvim_buf_set_lines(abuf, 0, -1, false, { 'callback edit' }) end
  end })
  assert(agent.run(config, 'late validation', 'edit', atarget))
  last().on_done({ message = 'bad', content = 'NO\n' })
  assert(ast.history[#ast.history].status == 'conflict' and body(abuf) == 'callback edit')
  vim.api.nvim_del_autocmd(hook)
  vim.api.nvim_buf_set_lines(abuf, 0, -1, false, { 'mine' })
  assert(agent.run(config, 'timeout', 'edit', atarget))
  agent.stop()
  last().on_done(nil, 'cancel_timeout')
  assert(ast.request == nil and agent.status(abuf).code == 'cancel_timeout')
  assert(agent.run(config, 'shutdown', 'edit', atarget))
  local late = last()
  agent.stop(); agent.shutdown()
  assert(stops == 1 and session.get().request == nil and #session.history() == 0)
  late.on_done({ message = 'late shutdown', content = 'NO\n' })
  assert(#session.history() == 0 and body(abuf) == 'mine')
  -- JSON still has one global session regardless of project or explicit root.
  local legacy = session.activate({}, abuf)
  session.append('user', 'legacy')
  assert(session.activate({ root = a }, bbuf) == legacy and #session.history() == 1)
  vim.fn.delete(temp, 'rf')
  print('acp_integration: ok')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
