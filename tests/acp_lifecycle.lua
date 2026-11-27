local uv = vim.uv or vim.loop
local root, server, token, trace

local function events()
  local result = {}
  if trace and vim.fn.filereadable(trace) == 1 then
    for _, line in ipairs(vim.fn.readfile(trace)) do
      local ok, value = pcall(vim.json.decode, line)
      if ok then result[#result + 1] = value end
    end
  end
  return result
end

local function alive(pid)
  return uv.kill(pid, 0) == 0
end

local function owned_pid()
  for _, event in ipairs(events()) do
    if event.event == 'started' and event.token == token and event.cwd == uv.fs_realpath(root .. '/project')
      and type(event.pid) == 'number' and event.pid > 1 and event.pid % 1 == 0 then
      return event.pid
    end
  end
end

local function cleanup()
  local pid = owned_pid()
  if pid and alive(pid) then
    -- Never signal a reused PID unless its command still identifies this fixture.
    local command = vim.system({ 'ps', '-p', tostring(pid), '-o', 'command=' }, { text = true }):wait()
    if command.code == 0 and command.stdout:find(server, 1, true) and command.stdout:find(token, 1, true) then
      uv.kill(pid, 15)
      if not vim.wait(2000, function() return not alive(pid) end, 5) then
        uv.kill(pid, 9)
        assert(vim.wait(2000, function() return not alive(pid) end, 5), 'owned fake server survived cleanup')
      end
    else
      error('PID ownership could not be confirmed; refusing to signal it')
    end
  end
  if root then
    assert(vim.fn.delete(root, 'rf') == 0, 'owned fixture cleanup failed')
    assert(not uv.fs_stat(root), 'owned fixture remains')
  end
end

local function run()
  assert(vim.fn.executable('python3') == 1, 'python3 is required')
  root = vim.fn.tempname()
  token = 'hodocode-acp-lifecycle-' .. tostring(uv.hrtime())
  server, trace = root .. '/fake.py', root .. '/events.jsonl'
  local project, resource = root .. '/project', root .. '/server-owned'
  vim.fn.mkdir(project, 'p')
  vim.fn.writefile({ 'unchanged' }, project .. '/source.txt')
  vim.fn.writefile(vim.split([[import json,os,shutil,signal,sys
log,resource,token=sys.argv[1:]
stopped=False

def event(kind,**fields):
    with open(log,'a') as output:
        output.write(json.dumps(dict(event=kind,token=token,**fields))+'\n')

def cleanup(kind):
    global stopped
    if stopped: return
    stopped=True
    shutil.rmtree(resource)
    event(kind,pid=os.getpid())

def stop(*_):
    cleanup('stopped')
    sys.exit(0)

signal.signal(signal.SIGTERM,stop)
os.mkdir(resource)
with open(os.path.join(resource,'owned'),'w') as output: output.write(token)
event('started',pid=os.getpid(),cwd=os.getcwd())
try:
    for line in sys.stdin:
        request=json.loads(line)
        method=request.get('method')
        event(method or 'response')
        if method=='initialize':
            result={'protocolVersion':1,'agentCapabilities':{'sessionCapabilities':{'close':{}}}}
        elif method=='session/new':
            result={'sessionId':'lifecycle-session','modes':{'currentModeId':'ask'}}
        elif method=='session/prompt':
            continue
        elif method=='session/close':
            result={}
        else:
            continue
        print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
finally:
    cleanup('eof')
]], '\n', { plain = true }), server)

  local child = root .. '/child.lua'
  local script = string.format([[
local function run()
  vim.opt.runtimepath:prepend(%q)
  vim.o.hidden = true
  vim.notify = function() end
  vim.cmd('runtime plugin/hodocode.lua')
  vim.cmd.cd(%q)
  vim.cmd.edit(%q)
  local hc = require('hodocode')
  hc.setup({ root = %q, agent_transport = 'acp', agent = { 'python3', '-u', %q, %q, %q, %q },
    agent_timeout_ms = 30000, acp_cancel_timeout_ms = 1000 })
  local agent, chat = require('hodocode.agent'), require('hodocode.chat')
  local session, acp = require('hodocode.session'), require('hodocode.acp')
  local uv = vim.uv or vim.loop
  local source = vim.api.nvim_get_current_buf()
  assert(acp.info(%q) == nil, 'setup eagerly spawned ACP')
  assert(agent.run(hc.config, 'stay busy', 'chat'))
  local function events()
    local values = {}
    if vim.fn.filereadable(%q) == 1 then
      for _, line in ipairs(vim.fn.readfile(%q)) do values[#values + 1] = vim.json.decode(line) end
    end
    return values
  end
  local pid
  assert(vim.wait(3000, function()
    local prompted = false
    for _, event in ipairs(events()) do
      if event.event == 'started' then pid = event.pid end
      if event.event == 'session/prompt' then prompted = true end
    end
    return pid ~= nil and prompted
  end, 5), 'fake server did not receive prompt')
  local state = session.get().request
  assert(state and state.running and state.cwd == nil)
  assert(chat.visible() and #vim.api.nvim_list_wins() >= 2)
  assert(vim.api.nvim_get_current_buf() ~= source, 'agent window was not selected')
  vim.cmd('q')
  assert(not chat.visible() and vim.api.nvim_get_current_buf() == source)
  vim.wait(30, function() return false end, 5)
  assert(uv.kill(pid, 0) == 0, ':q killed active ACP server')
  assert(session.get().request == state and state.running and not state.cancelled, ':q cancelled request')
  local info = acp.info(%q)
  assert(info and info.alive and info.busy)
  for _, event in ipairs(events()) do
    assert(event.event ~= 'session/cancel' and event.event ~= 'session/close' and event.event ~= 'stopped',
      ':q sent cancellation or closed server')
  end
  vim.fn.writefile({ 'window closed; request and owned server remain active' }, %q)
  vim.api.nvim_create_autocmd('VimLeavePre', { callback = function()
    assert(session.get().request == nil, 'VimLeavePre left active request')
    assert(acp.info(%q) == nil, 'VimLeavePre retained ACP records')
    vim.fn.writefile({ 'VimLeavePre cleared active request and ACP records' }, %q)
  end })
  vim.cmd('qa!')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
]], vim.fn.getcwd(), project, project .. '/source.txt', project, server, trace, resource, token,
    project, trace, trace, project, root .. '/window-closed', project, root .. '/left')
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), child)
  local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', child },
    { text = true, timeout = 8000 }):wait()
  assert(result.code == 0, result.stderr or 'child Neovim failed')
  assert(vim.fn.filereadable(root .. '/window-closed') == 1, 'child did not verify :q continuity')
  assert(vim.fn.filereadable(root .. '/left') == 1, 'actual VimLeavePre did not clear state')
  local pid = assert(owned_pid(), 'missing owned server PID')
  assert(vim.wait(3000, function() return not alive(pid) end, 5), 'Neovim exit left owned server alive')
  local stopped, prompts = false, 0
  for _, event in ipairs(events()) do
    if event.event == 'stopped' then stopped = true end
    if event.event == 'session/prompt' then prompts = prompts + 1 end
  end
  assert(stopped, 'owned server did not handle SIGTERM')
  assert(prompts == 1, 'prompt was unexpectedly replayed')
  assert(not uv.fs_stat(resource), 'owned server temporary resources remain')
  assert(vim.deep_equal(vim.fn.readfile(project .. '/source.txt'), { 'unchanged' }), 'fixture source was changed')
end

local ok, err = xpcall(run, debug.traceback)
local cleaned, cleanup_err = xpcall(cleanup, debug.traceback)
if not ok or not cleaned then
  io.stderr:write((err or '') .. '\n' .. (cleanup_err or '') .. '\n')
  vim.cmd('cquit 1')
else
  print('acp_lifecycle: ok (:q preserves active RPC; actual Neovim exit stops owned server and cleans resources)')
  vim.cmd('qa!')
end
