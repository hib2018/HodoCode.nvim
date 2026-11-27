local acp, root
local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  acp = require('hodocode.acp')
  root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local script = root .. '/fake.py'
  vim.fn.writefile(vim.split([[import json,os,sys
mode=sys.argv[1] if len(sys.argv)>1 else 'embedded'
sid='native-'+os.path.basename(os.getcwd())
count=0
held=None
log=os.path.join(os.getcwd(),'log')
def emit(m):
    print(json.dumps(dict(jsonrpc='2.0',**m)),flush=True)
def result(m,r): emit(dict(id=m['id'],result=r))
def chunk(text,which=None): emit(dict(method='session/update',params=dict(sessionId=which or sid,update=dict(sessionUpdate='agent_message_chunk',content=dict(type='text',text=text)))))
for line in sys.stdin:
    m=json.loads(line)
    with open(log,'a') as f: f.write(json.dumps(dict(pid=os.getpid(),message=m))+'\n')
    method=m.get('method'); p=m.get('params',{})
    if method=='initialize':
        assert p['protocolVersion']==1
        assert p['clientCapabilities']['fs']['writeTextFile']==False
        assert isinstance(p['clientCapabilities']['session']['notices'],dict)
        result(m,dict(protocolVersion=1,agentInfo=dict(name='fake',version='1'),agentCapabilities=dict(promptCapabilities=dict(embeddedContext=mode!='fallback'),sessionCapabilities=dict(resume={},close={},systemPrompt={}))))
    elif method in ['session/new','session/resume']:
        assert p['cwd']==os.getcwd() and p['mcpServers']==[]
        if method=='session/new':
            assert isinstance(p['systemPrompt'],list)
            policy=p['systemPrompt'][0]['text']
            assert 'read_file, grep_files and glob_files' in policy
            assert 'Metadata.path is the only editable file' in policy
            assert 'Never use filesystem writes, shell commands, MCP' in policy
        else:
            assert p['sessionId']==sid
            chunk('REPLAY')
            if mode=='resume_fail':
                emit(dict(id=m['id'],error=dict(code=-1,message='private'))); continue
        result(m,dict(**({} if method=='session/resume' else dict(sessionId=sid)),modes=dict(currentModeId='code' if mode=='unsafe' else 'ask')))
    elif method=='session/prompt':
        count+=1
        request=p['prompt'][0]['text']
        assert json.loads(request.split('\nMetadata: ',1)[1])['repository_root']==os.getcwd()
        if 'die' in request: sys.exit(7)
        if 'hold' in request: held=m; continue
        if 'error' in request:
            emit(dict(id=m['id'],error=dict(code=-1,message='PRIVATE'))); continue
        if 'permission' in request:
            snapshots=[entry['resource']['text'] for entry in p['prompt'] if entry['type']=='resource']
            assert 'unsaved helper\n' in snapshots and 'disk helper\n' not in snapshots
            emit(dict(id=700+count,method='session/request_permission',params=dict(sessionId=sid,options=[dict(optionId='allow',kind='allow_once',name='Allow')],toolCall=dict(toolCallId='t',kind='read'))))
            emit(dict(id=800+count,method='fs/write_text_file',params={}))
        emit(dict(method='session/update',params=dict(sessionId=sid,update=dict(sessionUpdate='notice',title='Skill warning',text='NOT AN ANSWER'))))
        if '"intent":"edit"' in request: chunk('Inspecting the repository first.')
        emit(dict(method='session/update',params=dict(sessionId=sid,update=dict(sessionUpdate='tool_call',toolCallId='t',title='Read',kind='read',status='pending',rawInput='PRIVATE'))))
        chunk('WRONG','other')
        emit(dict(method='session/update',params=dict(sessionId=sid,update=dict(sessionUpdate='agent_thought_chunk',content=dict(type='text',text='THOUGHT')))))
        text='answer-'+str(count)
        if '"intent":"edit"' in request: text='{"message":"change","edits":[{"old_text":"source","new_text":"changed"}]}'
        if 'badjson' in request: text='```json\n{}\n```'
        if 'oversize' in request: text='x'*3000
        chunk(text[:3]); chunk(text[3:])
        result(m,dict(stopReason='max_tokens' if 'truncate' in request else 'end_turn'))
    elif method=='session/cancel':
        if mode!='ignore_cancel' and held:
            chunk('LATE')
            result(held,dict(stopReason='end_turn')); held=None
    elif method=='session/close': result(m,{})
]], '\n', { plain = true }), script)
  local config = { agent = { 'python3', '-u', script }, max_agent_bytes = 2048, agent_timeout_ms = 2000, acp_cancel_timeout_ms = 60 }
  local function payload(prompt, intent, project)
    return { root = project or root, prompt = prompt, intent = intent or 'chat', buffer = { path = root .. '/source', content = 'source', cursor = { 1, 0 } }, history = { { content = 'DO NOT REPLAY' } } }
  end
  local function wait(test) assert(vim.wait(3000, test, 5), 'timed out') end
  local function request(prompt, intent, options, project)
    local value, code, calls = nil, nil, 0
    options = options or {}
    options.on_done = function(v, e) value, code, calls = v, e, calls + 1 end
    local h, err = acp.prompt(config, payload(prompt, intent, project), options)
    assert(h, err)
    wait(function() return calls > 0 end)
    assert(calls == 1)
    return value, code, h
  end
  local helper_path = root .. '/helper.go'
  vim.fn.writefile({ 'disk helper' }, helper_path)
  local helper = vim.fn.bufadd(helper_path)
  vim.fn.bufload(helper)
  vim.api.nvim_buf_set_lines(helper, 0, -1, false, { 'unsaved helper' })
  local chunks, tools, permissions = {}, {}, 0
  local value, code, h = request('permission', 'edit', {
    on_chunk = function(text) chunks[#chunks + 1] = text end,
    on_tool = function(tool)
      assert(not tool.rawInput)
      if tool.sessionUpdate == 'notice' then
        assert(#chunks == 0 and acp.info(root).metrics.first_chunk_ms == nil)
      end
      tools[#tools + 1] = tool
    end,
    on_permission = function(params, done)
      assert(params.options[1].optionId == 'allow'); permissions = permissions + 1
      done({ outcome = { outcome = 'selected', optionId = 'allow' } })
    end,
  })
  assert(value.message == 'change' and not code and chunks[1] == 'Inspecting the repository first.')
  assert(vim.json.decode(table.concat(chunks, '', 2)).message == 'change', 'progress prose entered the final JSON')
  assert(value.edits[1].new_text == 'changed' and value.version == vim.fn.sha256('source'))
  assert(permissions == 1 and #tools == 2 and h.metrics.first_chunk_ms and h.metrics.complete_ms)
  assert(vim.fn.readfile(helper_path)[1] == 'disk helper' and vim.bo[helper].modified)
  local id = acp.info(root).sessionId
  value = request('second')
  assert(value.message == 'answer-2' and acp.info(root).sessionId == id)
  value = request('change', 'edit')
  assert(value.edits[1].new_text == 'changed' and value.version == vim.fn.sha256('source'))
  local logs = vim.fn.readfile(root .. '/log')
  local pid, news, prompts, unknown = nil, 0, 0, false
  for _, line in ipairs(logs) do
    local log = vim.json.decode(line); pid = pid or log.pid; assert(pid == log.pid)
    local m = log.message
    if m.method == 'session/new' then news = news + 1 end
    if m.method == 'session/prompt' then
      prompts = prompts + 1
      assert(#m.params.prompt == 3 and m.params.prompt[2].type == 'resource')
      assert(m.params.prompt[3].resource.text == 'unsaved helper\n')
      assert(not line:find('DO NOT REPLAY', 1, true))
    end
    if m.error then assert(m.error.code == -32601); unknown = true end
  end
  assert(news == 1 and prompts == 3 and unknown)
  for _, prompt in ipairs({ 'badjson', 'truncate' }) do
    value, code = request(prompt, 'edit'); assert(not value and code == 'invalid_response')
  end
  value, code = request('error'); assert(not value and code == 'provider_exit')
  value, code = request('oversize'); assert(not value and code == 'size_limit')
  local completed, cancel_code, got_chunk = 0, nil, false
  h = assert(acp.prompt(config, payload('hold'), { on_done = function(_, e) completed, cancel_code = completed + 1, e end,
    on_chunk = function() got_chunk = true end }))
  wait(function() return h.metrics.startup_ms ~= nil end)
  local busy, busy_code = acp.prompt(config, payload('busy'), { on_done = function() end })
  assert(not busy and busy_code == 'busy')
  h.cancel(); assert(completed == 0 and acp.info(root).busy)
  wait(function() return completed == 1 end)
  assert(cancel_code == 'cancelled' and not got_chunk and not acp.info(root).busy)
  value, code = request('die'); assert(not value and code == 'transport' and acp.info(root).sessionId == id)
  value = request('resumed'); assert(value.message == 'answer-1')
  local resumed = false
  for _, line in ipairs(vim.fn.readfile(root .. '/log')) do
    if vim.json.decode(line).message.method == 'session/resume' then resumed = true end
  end
  assert(resumed)
  local other = root .. '/other'; vim.fn.mkdir(other, 'p')
  value = request('cross root', nil, nil, other)
  assert(value.message == 'answer-1' and acp.info(other).sessionId ~= id)
  config.agent = { 'python3', '-u', script, 'fallback' }
  value = request('fallback'); assert(value.message == 'answer-1')
  local last
  for _, line in ipairs(vim.fn.readfile(root .. '/log')) do
    local m = vim.json.decode(line).message
    if m.method == 'session/prompt' then last = m end
  end
  assert(last.params.prompt[2].type == 'text')
  config.agent = { 'python3', '-u', script, 'resume_fail' }
  value = request('start'); assert(value.message == 'answer-1')
  value, code = request('die'); assert(code == 'transport')
  value, code = request('resume failure'); assert(not value and code == 'resume_failed')
  assert(acp.info(root).sessionId == id and not acp.info(root).alive)
  config.agent = { 'python3', '-u', script, 'unsafe' }
  value, code = request('unsafe'); assert(not value and code == 'configuration_error')
  config.agent = { 'python3', '-u', script, 'ignore_cancel' }
  value, code, h = request('hold', nil, nil)
  assert(not value and code == 'timeout' and h.metrics.complete_ms < 2600 and not acp.info(root).alive)
  config.agent_timeout_ms = 2000
  completed = 0
  h = assert(acp.prompt(config, payload('hold'), { on_done = function(_, e) completed, cancel_code = completed + 1, e end }))
  wait(function() return h.metrics.startup_ms ~= nil end)
  h.cancel()
  wait(function() return completed == 1 end)
  assert(cancel_code == 'cancelled' and not acp.info(root).alive)
  completed = 0
  h = assert(acp.prompt(config, payload('hold'), { on_done = function(_, e) assert(e == 'cancelled'); completed = completed + 1 end }))
  wait(function() return h.metrics.startup_ms ~= nil end)
  acp.shutdown()
  wait(function() return completed == 1 end)
  assert(acp.info(root) == nil and acp.info(other) == nil)
  -- Deterministically deliver an old process exit after a synchronous reconnect.
  local real_rpc = package.loaded['hodocode.acp_rpc']
  local peers = {}
  package.loaded['hodocode.acp_rpc'] = { start = function(_, _, hooks)
    local peer = { live = true, requests = {}, hooks = hooks }
    peer.alive = function() return peer.live end
    peer.notify = function() return true end
    peer.request = function(method, params, cb)
      peer.requests[method] = { callback = cb, params = params }
      return 1
    end
    peer.close = function()
      peer.live = false
      local waiting = peer.requests; peer.requests = {}
      for _, req in pairs(waiting) do req.callback(nil, 'closed') end
    end
    peers[#peers + 1] = peer
    return peer
  end }
  package.loaded['hodocode.acp'] = nil
  acp = require('hodocode.acp')
  local function answer(peer, method, value, err)
    local req = assert(peer.requests[method], method)
    peer.requests[method] = nil
    req.callback(value, err)
  end
  local caps = { protocolVersion = 1, agentCapabilities = { sessionCapabilities = { resume = {} } } }
  local function ready(peer)
    answer(peer, 'initialize', caps)
    local method = peer.requests['session/resume'] and 'session/resume' or 'session/new'
    answer(peer, method, { sessionId = 'stable' })
  end
  local second, second_done
  acp.prompt(config, payload('first'), { on_done = function(_, err)
    assert(err == 'transport')
    second = assert(acp.prompt(config, payload('second'), { on_done = function(v, e) second_done = { v, e } end }))
  end })
  ready(peers[1])
  peers[1].live = false
  answer(peers[1], 'session/prompt', nil, 'process_exited')
  assert(second and #peers == 2)
  peers[1].hooks.on_error('process_exited')
  peers[1].hooks.on_exit(7)
  assert(peers[2].live and not second_done)
  ready(peers[2])
  peers[2].hooks.on_notification('session/update', { sessionId = 'stable', update = { sessionUpdate = 'agent_message_chunk', content = { type = 'text', text = 'healthy' } } })
  answer(peers[2], 'session/prompt', { stopReason = 'end_turn' })
  assert(second_done[1].message == 'healthy')
  acp.shutdown()
  -- A bad initialize result closes its own peer before invoking a reentrant caller.
  local replacement
  acp.prompt(config, payload('bad init'), { on_done = function(_, err)
    assert(err == 'invalid_response')
    replacement = assert(acp.prompt(config, payload('replacement'), { on_done = function() end }))
  end })
  answer(peers[3], 'initialize', { protocolVersion = 2, agentCapabilities = {} })
  assert(replacement and #peers == 4 and peers[4].live)
  acp.shutdown()
  local startup_done
  local startup = assert(acp.prompt(config, payload('startup cancel'), { on_done = function(_, err) startup_done = err end }))
  startup.cancel()
  assert(startup_done == 'cancelled' and not peers[5].live)
  config.agent_timeout_ms = 15
  startup_done = nil
  acp.prompt(config, payload('startup timeout'), { on_done = function(_, err) startup_done = err end })
  wait(function() return startup_done ~= nil end)
  assert(startup_done == 'timeout' and not peers[6].live)
  config.agent_timeout_ms = 2000
  local dialogs, cancelled_dialogs, permission_replies, late = 0, 0, 0, {}
  local pending_done
  local pending = assert(acp.prompt(config, payload('permission pending'), {
    on_done = function(_, err) pending_done = err end,
    on_permission = function(_, answer_permission)
      dialogs = dialogs + 1; late[#late + 1] = answer_permission
      return { cancel = function() cancelled_dialogs = cancelled_dialogs + 1 end }
    end,
  }))
  ready(peers[7])
  for _ = 1, 17 do
    peers[7].hooks.on_request('session/request_permission', { sessionId = 'stable' }, function(result)
      assert(result.outcome.outcome == 'cancelled'); permission_replies = permission_replies + 1
    end)
  end
  assert(dialogs == 16 and permission_replies == 1)
  pending.cancel()
  assert(cancelled_dialogs == 16 and permission_replies == 17 and not pending_done)
  for _, answer_permission in ipairs(late) do answer_permission({ outcome = { outcome = 'selected', optionId = 'late' } }) end
  assert(permission_replies == 17)
  answer(peers[7], 'session/prompt', { stopReason = 'end_turn' })
  assert(pending_done == 'cancelled')
  acp.shutdown()
  package.loaded['hodocode.acp_rpc'] = real_rpc
  print('acp: ok')
end
local ok, err = xpcall(run, debug.traceback)
if acp then acp.shutdown() end
if root then vim.fn.delete(root, 'rf') end
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
