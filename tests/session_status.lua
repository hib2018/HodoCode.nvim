local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local agent, session = require('hodocode.agent'), require('hodocode.session')
  local uv = vim.uv or vim.loop
  vim.notify = function() end
  local path = vim.fn.tempname()
  vim.fn.writefile({ 'source' }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  local ticks, latest, changes = 0, nil, 0
  local hook = vim.api.nvim_create_autocmd('User', {
    pattern = 'HodoCodeSessionChanged', callback = function()
      changes = changes + 1
      local request = session.get().request
      if request and request.phase == 'waiting' then
        local current = agent.status(request.source)
        if current.elapsed_ms >= 900 then ticks = ticks + 1; latest = current end
      end
    end,
  })
  local config = {
    agent = { 'python3', '-c', 'import json,sys,time; json.load(sys.stdin); time.sleep(1.2); print(json.dumps({"message":"answer"}))' },
    max_agent_bytes = 1024 * 1024, agent_timeout_ms = 4000,
  }
  agent.run(config, 'question', 'chat')
  local request = assert(session.get().request)
  assert(request.source == buf and request.started <= uv.hrtime())
  assert(vim.wait(5000, function() return session.get().request == nil end, 5))
  assert(ticks > 0 and latest.running, 'elapsed timer must emit session-change events')
  local history = session.get().history
  assert(history[1].role == 'user' and history[1].content == 'question')
  assert(history[2].role == 'assistant' and history[2].content == 'answer')
  assert(history[2].outcome == 'nochange' and history[2].status == 'nochange')
  assert(session.get().last_status.phase == 'done' and session.get().last_status.elapsed_ms >= 900)
  local stopped_changes = changes
  vim.wait(1100, function() return false end, 10)
  assert(changes == stopped_changes, 'finished requests must stop periodic events')
  vim.api.nvim_del_autocmd(hook)
  local real_system, output = vim.system
  vim.system = function(_, opts)
    output = opts.stdout
    return { kill = function() end }
  end
  local received = 0
  hook = vim.api.nvim_create_autocmd('User', { pattern = 'HodoCodeSessionChanged', callback = function()
    local current = session.get().request
    if current and current.phase == 'received' then received = received + 1 end
  end })
  agent.run(config, 'next question', 'chat', { buf = buf, cursor = { 1, 0 } })
  assert(output, 'mock request did not start')
  output(nil, '{"event":"status","phase":"received"}\n')
  assert(vim.wait(1000, function() return received > 0 end, 1))
  assert(received == 1, 'one status event triggered duplicate redraw notifications')
  agent.stop()
  vim.system = real_system
  vim.api.nvim_del_autocmd(hook)
  agent.shutdown()
  vim.fn.delete(path)
  print('session status: ok')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
