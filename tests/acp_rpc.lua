local peers, root = {}, nil
local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local rpc = require('hodocode.acp_rpc')
  root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local script = root .. '/fake.py'
  vim.fn.writefile(vim.split([[import json,os,sys,time

def emit(value):
    os.write(1,(json.dumps(value,ensure_ascii=False)+'\n').encode())
for line in sys.stdin:
    m=json.loads(line)
    if 'method' not in m:
        emit({'jsonrpc':'2.0','method':'answered','params':m})
        continue
    method=m['method']
    if method=='split':
        payload=(json.dumps({'jsonrpc':'2.0','id':m['id'],'result':'日本語'},ensure_ascii=False)+'\n').encode()
        for byte in payload:
            os.write(1,bytes([byte])); time.sleep(.001)
        os.write(1,b'{"jsonrpc":"2.0","method":"one"}\n{"jsonrpc":"2.0","method":"two"}\n')
    elif method=='server':
        emit({'jsonrpc':'2.0','id':700,'method':'permission','params':{'ok':True}})
        emit({'jsonrpc':'2.0','id':701,'method':'denied'})
        emit({'jsonrpc':'2.0','id':m['id'],'result':None})
    elif method=='server_string':
        for request_id in ['', '700', 'x'*256]:
            emit({'jsonrpc':'2.0','id':request_id,'method':'permission','params':{'ok':True}})
        emit({'jsonrpc':'2.0','id':'denied','method':'denied'})
        emit({'jsonrpc':'2.0','id':m['id'],'result':None})
    elif method=='longid': emit({'jsonrpc':'2.0','id':'x'*257,'method':'permission'})
    elif method=='notify':
        emit({'jsonrpc':'2.0','method':'noticed','params':m.get('params')})
    elif method=='error':
        emit({'jsonrpc':'2.0','id':m['id'],'error':{'code':-1,'message':'denied'}})
    elif method=='malformed': os.write(1,b'PRIVATE SOURCE\n')
    elif method=='oversize': os.write(1,b'x'*300)
    elif method=='stderr': os.write(2,b'PRIVATE STDERR'*30)
    elif method=='eof': os.write(1,b'{'); sys.exit(0)
    elif method=='death': sys.exit(7)
    elif method=='both': emit({'jsonrpc':'2.0','id':m['id'],'result':1,'error':{'code':-1,'message':'no'}})
    elif method=='stringid': emit({'jsonrpc':'2.0','id':str(m['id']),'result':1})
    elif method=='fraction': emit({'jsonrpc':'2.0','id':1.5,'result':1})
    elif method=='unknown': emit({'jsonrpc':'2.0','id':9000,'result':1})
    elif method=='baderror': emit({'jsonrpc':'2.0','id':m['id'],'error':'PRIVATE'})
    elif method=='version': emit({'id':m['id'],'result':1})
    elif method=='duplicate':
        emit({'jsonrpc':'2.0','id':m['id'],'result':1})
        emit({'jsonrpc':'2.0','id':m['id'],'result':2})
    elif method=='hold': pass
    elif method=='first': first=m['id']
    elif method=='second':
        emit({'jsonrpc':'2.0','id':m['id'],'result':'second'})
        emit({'jsonrpc':'2.0','id':first,'result':'first'})
    elif method=='partial_limit':
        os.write(1,b'x'*200); time.sleep(.02); os.write(1,b'y'*100)
    else: emit({'jsonrpc':'2.0','id':m['id'],'result':m.get('params')})
]], '\n', { plain = true }), script)

  local function wait(predicate)
    assert(vim.wait(3000, predicate, 5), 'timed out')
  end
  local function start(opts)
    local peer, err = rpc.start({ 'python3', '-u', script }, root, opts)
    assert(peer, err)
    peers[#peers + 1] = peer
    return peer
  end
  local notifications, answered, responses = {}, {}, 0
  local peer = start({
    on_notification = function(method, params)
      notifications[method] = true
      if method == 'answered' then answered[params.id] = params end
    end,
    on_request = function(method, params, respond)
      if method == 'permission' then
        assert(params.ok)
        assert(respond({ allowed = true }))
        local ok, err = respond({ allowed = false })
        assert(not ok and err == 'already_responded')
      else
        assert(respond(nil, { code = -32000, message = 'denied' }))
      end
    end,
  })
  local id = peer.request('split', {}, function(result, err)
    assert(result == '日本語' and err == nil)
    responses = responses + 1
  end)
  assert(id == 1)
  wait(function() return notifications.two end)
  assert(notifications.one and responses == 1 and peer.alive())
  assert(peer.notify('notify', { value = 3 }))
  peer.request('server', nil, function(result, err)
    assert(result == vim.NIL and err == nil)
    responses = responses + 1
  end)
  wait(function() return answered[700] and answered[701] and notifications.noticed end)
  assert(answered[700].jsonrpc == '2.0' and answered[700].result.allowed)
  assert(answered[701].error.code == -32000 and answered[701].result == nil)
  peer.request('server_string', nil, function(result, err)
    assert(result == vim.NIL and err == nil)
  end)
  wait(function() return answered[''] and answered['700'] and answered[string.rep('x', 256)] and answered.denied end)
  for _, request_id in ipairs({ '', '700', string.rep('x', 256) }) do
    assert(answered[request_id].id == request_id and answered[request_id].result.allowed)
  end
  assert(answered.denied.id == 'denied' and answered.denied.error.code == -32000)
  peer.request('error', nil, function(result, err)
    assert(result == nil and err.code == -1)
    responses = responses + 1
  end)
  wait(function() return responses == 3 end)
  -- No idle expiry or request timeout belongs to this transport.
  vim.wait(30, function() return false end, 5)
  assert(peer.alive())
  local order = {}
  peer.request('first', nil, function(result, err) assert(not err); order[#order + 1] = result end)
  peer.request('second', nil, function(result, err) assert(not err); order[#order + 1] = result end)
  wait(function() return #order == 2 end)
  assert(order[1] == 'second' and order[2] == 'first', 'IDs must match, not FIFO')
  peer.close(); peer.close()

  for method, expected in pairs({ malformed = 'invalid_message', oversize = 'message_too_large',
    partial_limit = 'message_too_large',
    stderr = 'stderr_limit', eof = 'process_exited', death = 'process_exited',
    both = 'invalid_message', stringid = 'invalid_message', fraction = 'invalid_message',
    unknown = 'invalid_message', baderror = 'invalid_message', version = 'invalid_message' }) do
    local callbacks, errors, exits = 0, 0, 0
    local p = start({ max_bytes = 256,
      on_error = function(code) assert(code == expected); errors = errors + 1 end,
      on_exit = function(code)
        if method == 'death' then assert(code == 7) end
        exits = exits + 1
      end,
    })
    p.request(method, nil, function(result, err)
      assert(result == nil and err == expected)
      callbacks = callbacks + 1
    end)
    wait(function() return exits == 1 end)
    assert(callbacks == 1 and errors == 1 and not p.alive(), method)
    p.close()
  end

  local bad_id_errors, bad_id_callbacks = 0, 0
  local bad_id = start({ max_bytes = 1024, on_error = function(code)
    assert(code == 'invalid_message'); bad_id_errors = bad_id_errors + 1
  end })
  bad_id.request('longid', nil, function(_, code)
    assert(code == 'invalid_message'); bad_id_callbacks = bad_id_callbacks + 1
  end)
  wait(function() return not bad_id.alive() end)
  assert(bad_id_errors == 1 and bad_id_callbacks == 1)

  local completed, duplicate_errors = 0, 0
  local duplicate = start({ on_error = function(code)
    assert(code == 'invalid_message'); duplicate_errors = duplicate_errors + 1
  end })
  duplicate.request('duplicate', nil, function(result, err)
    assert(result == 1 and not err); completed = completed + 1
  end)
  wait(function() return not duplicate.alive() end)
  assert(completed == 1 and duplicate_errors == 1)

  local count, rejected, exits = 0, 0, 0
  local pending = start({ on_exit = function() exits = exits + 1 end })
  for index = 1, 16 do
    assert(pending.request('hold', nil, function(_, err)
      assert(err == 'closed'); count = count + 1
    end) == index)
  end
  local refused, reason = pending.request('hold', nil, function(_, err)
    assert(err == 'pending_limit'); rejected = rejected + 1
  end)
  assert(refused == nil and reason == 'pending_limit' and rejected == 1 and pending.alive())
  pending.close(); pending.close()
  wait(function() return exits == 1 end)
  assert(count == 16 and not pending.alive())
  pending.request('hold', nil, function(_, err) assert(err == 'closed'); count = count + 1 end)
  assert(count == 17)

  -- Capture real job callbacks to deliver events after close without a timer race.
  local jobstart, captured = vim.fn.jobstart, nil
  vim.fn.jobstart = function(argv, opts) captured = opts; return jobstart(argv, opts) end
  local late, callbacks, notices, late_exits = nil, 0, 0, 0
  late = start({ on_notification = function() notices = notices + 1 end,
    on_exit = function() late_exits = late_exits + 1 end })
  vim.fn.jobstart = jobstart
  late.request('hold', nil, function(_, err) assert(err == 'closed'); callbacks = callbacks + 1 end)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  late.close()
  captured.on_stdout(0, { '{"jsonrpc":"2.0","id":1,"result":"late"}', '' })
  captured.on_stdout(0, { '{"jsonrpc":"2.0","method":"late"}', '' })
  captured.on_stderr(0, { string.rep('x', 2000000), '' })
  captured.on_exit(0, 0); captured.on_exit(0, 0)
  assert(callbacks == 1 and notices == 0 and late_exits == 1)
  assert(vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win() == win)

  for _, mode in ipairs({ 'zero', 'throw' }) do
    local errors, results = 0, 0
    local p = start({ on_error = function(code) assert(code == 'write_failed'); errors = errors + 1 end })
    local chansend = vim.fn.chansend
    vim.fn.chansend = function()
      if mode == 'throw' then error('PRIVATE WRITE FAILURE') end
      return 0
    end
    local sent, err = p.request('hold', nil, function(_, code)
      assert(code == 'write_failed'); results = results + 1
    end)
    vim.fn.chansend = chansend
    assert(sent == nil and err == 'write_failed' and errors == 1 and results == 1 and not p.alive())
  end
  local saved_respond
  local deferred = start({ on_request = function(_, _, respond) saved_respond = respond end })
  deferred.request('server', nil, function() end)
  wait(function() return saved_respond ~= nil end)
  deferred.close()
  local sent, reason = saved_respond({ too = 'late' })
  assert(sent == nil and reason == 'closed')

  local fallback_reply
  local fallback = start({ on_notification = function(method, params)
    if method == 'answered' then fallback_reply = params end
  end })
  fallback.request('server', nil, function() end)
  wait(function() return fallback_reply ~= nil end)
  assert(fallback_reply.error.code == -32601)
  fallback.close()

  local oversized_calls, oversized_errors = 0, 0
  local oversized = start({ max_bytes = 128, on_error = function(code)
    assert(code == 'message_too_large'); oversized_errors = oversized_errors + 1
  end })
  local sent_id, send_err = oversized.request('echo', { value = string.rep('x', 200) }, function(_, code)
    assert(code == 'message_too_large'); oversized_calls = oversized_calls + 1
  end)
  assert(sent_id == nil and send_err == 'message_too_large' and oversized_calls == 1 and oversized_errors == 1)

  local throwing = start({ on_notification = function() error('PRIVATE CALLBACK FAILURE') end })
  throwing.notify('notify', {})
  wait(function() return not throwing.alive() end)
  for _, opts in ipairs({ { max_bytes = 0 }, { max_bytes = math.huge }, { on_error = true } }) do
    local invalid, code = rpc.start({ 'python3', script }, root, opts)
    assert(invalid == nil and code == 'invalid_options')
  end
  local invalid, err = rpc.start({ root .. '/does-not-exist' }, root)
  assert(invalid == nil and err == 'start_failed')
  assert(package.loaded['hodocode.agent'] == nil and package.loaded['hodocode.session'] == nil)
  print('acp_rpc: ok')
end
local ok, err = xpcall(run, debug.traceback)
for _, peer in ipairs(peers) do peer.close() end
if root then vim.fn.delete(root, 'rf') end
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
