local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  local agent = require('hodocode.agent')
  local root, notifications, changes = vim.fn.tempname(), {}, {}
  vim.fn.mkdir(root, 'p')
  local done_text, listener_mode = {}, {}
  vim.notify = function(message) notifications[#notifications + 1] = message end
  vim.api.nvim_create_autocmd('User', { pattern = 'HodoCodeAgentStatus', callback = function(ev)
    assert(ev.data.buf and ev.data.phase and type(ev.data.running) == 'boolean')
    changes[#changes + 1] = ev.data
    if ev.data.phase == 'done' then
      done_text[ev.data.buf] = table.concat(vim.api.nvim_buf_get_lines(ev.data.buf, 0, -1, false), '\n')
    elseif ev.data.phase == 'validating' and listener_mode[ev.data.buf] then
      if listener_mode[ev.data.buf] == 'listener_cancel' then agent.stop()
      else vim.api.nvim_buf_set_lines(ev.data.buf, -1, -1, false, { 'listener' }) end
    end
  end })
  local script = root .. '/adapter.py'
  vim.fn.writefile(vim.split([[import hashlib,json,os,sys,time
r=json.load(sys.stdin)
assert os.environ['HODOCODE_AGENT_TIMEOUT_MS'] == sys.argv[2]
assert os.environ['HODOCODE_EDIT_PROTOCOL'] == '2'
assert os.environ['PATH']
mode=sys.argv[1]
version=hashlib.sha256(r['buffer']['content'].encode()).hexdigest()
def emit(obj):
    text=json.dumps(obj)+'\n'
    for c in text:
        sys.stdout.write(c)
    sys.stdout.flush()
emit({'event':'status','phase':'waiting'})
if mode in ('timeout','slow'): time.sleep(1.3)
if mode=='error':
    emit({'event':'error','code':'authentication','message':'SECRET_PROVIDER_CONTEXT'})
    sys.stderr.write('SECRET_STDERR')
    sys.exit(1)
if mode=='version': version='0'*64
edits=[{'old_text':'before','new_text':'after'}]
if mode=='noop': edits=[]
if mode=='message':
    emit({'event':'result','version':version,'message':'done'})
    sys.exit(0)
if mode=='patch': edits.append({'old_text':'not there','new_text':'unsafe'})
emit({'event':'result','version':version,'message':'done','edits':edits})
if mode=='trailing': emit({'event':'status','phase':'received'})
if mode=='exit': sys.exit(1)
if mode=='oversize': sys.stderr.write('x'*8192)
]], '\n', { plain = true }), script)
  local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local function test(mode, expected_code)
    local path = root .. '/' .. mode .. '.txt'
    vim.fn.writefile({ 'before' }, path)
    vim.cmd.edit(path)
    local source = vim.api.nvim_get_current_buf()
    if mode == 'listener' or mode == 'listener_cancel' then listener_mode[source] = mode end
    local timeout = mode == 'timeout' and 50 or 3000
    agent.run({ agent = { 'python3', script, mode, tostring(timeout) }, max_agent_bytes = 4096,
      agent_timeout_ms = timeout }, 'edit')
    local popup, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    assert(agent.status(source).running and agent.status(source).elapsed_ms >= 0)
    assert(agent.status(popup) == nil)
    if mode == 'cancel' then agent.stop() end
    if mode == 'slow' then
      assert(vim.wait(1200, function() return agent.status(source).elapsed_ms >= 1000 end, 10))
      assert(text(popup):find('応答待ち', 1, true) and not text(popup):find('%%'))
      vim.api.nvim_buf_set_lines(source, -1, -1, false, { 'user' })
    end
    assert(vim.wait(5000, function() return not agent.status(source).running end, 5), 'completion: ' .. mode)
    local status = agent.status(source)
    assert(status.code == expected_code, mode .. ': expected ' .. tostring(expected_code) .. ', got ' .. tostring(status.code))
    local expected_phase = expected_code == 'cancelled' and 'cancelled' or (expected_code and 'error' or 'done')
    assert(status.phase == expected_phase, 'terminal phase: ' .. mode .. ': ' .. status.phase)
    if expected_code then
      assert(text(source):sub(1, 6) == 'before', 'partial apply: ' .. mode)
      assert(done_text[source] == nil, 'failure announced done: ' .. mode)
      if mode == 'patch' then assert(text(popup):find('置換元が一致しません', 1, true), 'patch detail discarded') end
      assert(text(popup):find('経過', 1, true), 'elapsed omitted: ' .. mode)
      assert(not text(popup):find('SECRET', 1, true), 'private popup context leaked')
    else
      local expected = (mode == 'noop' or mode == 'message') and 'before' or 'after'
      assert(text(source) == expected and done_text[source] == expected, 'done announced before source was updated')
      if expected == 'after' then
        assert(vim.bo[source].modified)
        assert(vim.api.nvim_get_current_buf() == source, 'must return to source')
        vim.api.nvim_buf_call(source, function() vim.cmd.undo() end)
        assert(text(source) == 'before', 'single undo')
      end
    end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    vim.api.nvim_buf_delete(source, { force = true })
    assert(agent.status(source) == nil, 'status must clear on wipe')
  end
  test('ok')
  test('noop')
  test('message')
  for mode, code in pairs({ patch = 'invalid_patch', version = 'version_mismatch', trailing = 'invalid_response',
    exit = 'process_exit', oversize = 'size_limit', timeout = 'timeout', error = 'authentication',
    slow = 'conflict', cancel = 'cancelled', listener = 'conflict', listener_cancel = 'cancelled' }) do test(mode, code) end
  vim.cmd.edit(root .. '/spawn.txt')
  local spawn_source = vim.api.nvim_get_current_buf()
  local system = vim.system
  vim.system = function() error('SECRET_SPAWN') end
  agent.run({ agent = { 'missing' }, max_agent_bytes = 4096, agent_timeout_ms = 100 }, 'edit')
  vim.system = system
  assert(agent.status(spawn_source).phase == 'error' and agent.status(spawn_source).code == 'spawn_failed')
  vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
  vim.api.nvim_buf_delete(spawn_source, { force = true })
  assert(#changes > 10)
  assert(not table.concat(notifications, '\n'):find('SECRET', 1, true), 'private context leaked')
  vim.fn.delete(root, 'rf')
  print('PASS: edit bridge atomic patch, version, exit, timeout, cancel, conflict, status, private errors')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
