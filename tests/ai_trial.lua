local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.cmd.edit(root .. '/unsaved.py')
  local source = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'token = "SECRET"', 'print(token)' })
  local original = table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n') .. '\n'
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local prep = require('hodocode.prepare')
  local explain = require('hodocode.explain')
  local chat = require('hodocode.chat')
  local config = { root = root, timeout_ms = 1500, agent_timeout_ms = 1500, max_agent_bytes = 131072,
    excludes = {}, backend = { 'python3', '-c', [[import sys,json,hashlib
assert sys.argv[1:3]==['prepare-buffer','--root']
r=json.load(sys.stdin)
assert r['file']=='unsaved.py' and 'SECRET' in r['content']
json.dump(dict(file=r['file'],content=r['content'].replace('SECRET','******'),purpose=r['purpose'],language='python',version=hashlib.sha256(r['content'].encode()).hexdigest(),line_count=r['content'].count('\n')+1),sys.stdout)
]] } }
  local real_backend = { vim.fn.getcwd() .. '/bin/hodocode' }
  assert(vim.fn.executable(real_backend[1]) == 1, 'run make build before this test')
  local real_config = vim.tbl_extend('force', config, { backend = real_backend })
  local snapshot = assert(prep.capture(real_config))
  local prepared, prepare_error, finished
  prep.run({}, real_config, snapshot, 'Explain unsaved source', function(value, err)
    prepared, prepare_error, finished = value, err, true
  end)
  assert(vim.wait(5000, function() return finished end, 10), 'real prepare timeout')
  assert(prepared, prepare_error)
  assert(prepared.buffer.file == 'unsaved.py' and not prepared.buffer.content:find('SECRET', 1, true))
  assert(not uv.fs_stat(root .. '/go.mod') and not uv.fs_stat(root .. '/unsaved.py'))
  assert(uv.fs_symlink(root, root .. '/alias'))
  -- Neovim resolves symlink names itself; supply an alias explicitly at the capture boundary.
  local get_name = vim.api.nvim_buf_get_name
  vim.api.nvim_buf_get_name = function(buf)
    return buf == source and snapshot.root .. '/alias/unsaved.py' or get_name(buf)
  end
  local aliased = assert(prep.capture(real_config))
  assert(aliased.file == 'alias/unsaved.py', 'capture must preserve child alias')
  finished, prepared = false, nil
  prep.run({}, real_config, aliased, 'Explain alias', function(value, err)
    prepared, prepare_error, finished = value, err, true
  end)
  assert(vim.wait(5000, function() return finished end, 10))
  assert(not prepared and prepare_error:find('symlink', 1, true), prepare_error)
  vim.api.nvim_buf_get_name = get_name
  uv.fs_unlink(root .. '/alias')
  local boundary_config = vim.tbl_extend('force', config, { backend = { 'python3', '-c', [[import sys,json,hashlib
r=json.load(sys.stdin)
s=json.dumps(dict(file=r['file'],content='masked',purpose=r['purpose'],language='python',version=hashlib.sha256(r['content'].encode()).hexdigest(),line_count=r['content'].count('\n')+1),separators=(',',':'))
sys.stdout.write(s+' '*(131072-len(s))+'\n')
]] } })
  finished, prepared = false, nil
  prep.run({}, boundary_config, assert(prep.capture(config)), 'Boundary', function(value, err)
    prepared, prepare_error, finished = value, err, true
  end)
  assert(vim.wait(5000, function() return finished end, 10))
  assert(prepared, prepare_error)
  finished, prepared = false, nil
  local excluded_config = vim.tbl_extend('force', real_config, { excludes = { 'unsaved.py' } })
  prep.run({}, excluded_config, assert(prep.capture(excluded_config)), 'Excluded', function(value, err)
    prepared, prepare_error, finished = value, err, true
  end)
  assert(vim.wait(5000, function() return finished end, 10))
  assert(not prepared and prepare_error:find('excluded', 1, true), prepare_error)
  local adapter = [[import sys,json,os,stat
assert os.path.realpath(os.getcwd())!=os.path.realpath(]] .. string.format('%q', root) .. ')\n' .. [[
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
r=json.load(sys.stdin)
assert 'SECRET' not in json.dumps(r) and '******' in r['buffer']['content']
assert r['buffer']['file']=='unsaved.py' and r['buffer']['path']=='unsaved.py'
json.dump(dict(version=r['buffer']['version'],message='Summary',comments=[dict(file='unsaved.py',line=1,end_line=2,text='First\nFull detail')]),sys.stdout)
]]
  config.explain_agent = { 'python3', '-c', adapter }
  local ns = vim.api.nvim_create_namespace('HodoCodeExplain')
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) end
  local function wait(test, label)
    assert(vim.wait(5000, test, 10), 'timeout: ' .. label .. '\n' .. table.concat(notices, '\n'))
  end
  assert(explain.run(config, 'explain'))
  wait(function() return #marks() == 1 end, 'masked unsaved explain')
  assert(table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n') .. '\n' == original)
  assert(not uv.fs_stat(root .. '/unsaved.py'), 'no source writes')
  assert(explain.toggle() and #marks() == 0)
  assert(explain.toggle() and #marks() == 1)
  assert(explain.show())
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('Full detail', 1, true))
  vim.api.nvim_win_close(0, true)
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = source })
  assert(#marks() == 0)

  local delayed
  local input = vim.ui.input
  vim.ui.input = function(_, callback) delayed = callback end
  explain.run(config)
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { 'print(token) # changed' })
  delayed('late')
  vim.ui.input = input
  assert(not explain.stop() and #marks() == 0, 'delayed input must not recapture changes')
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { 'print(token)' })

  config.explain_agent = { 'python3', '-c', adapter:gsub('line=1,end_line=2', 'line=3,end_line=3') }
  local count = #notices
  explain.run(config, 'bad range')
  wait(function() return #notices > count end, 'reject phantom trailing line')
  assert(#marks() == 0)
  for _, invalid in ipairs({ adapter:gsub("file='unsaved.py',line", "file='other.py',line"),
    adapter:gsub("version=r%['buffer'%]%['version'%]", "version='wrong'") }) do
    config.explain_agent = { 'python3', '-c', invalid }
    count = #notices
    explain.run(config, 'identity')
    wait(function() return #notices > count end, 'reject wrong identity')
    assert(#marks() == 0)
  end
  local slow = adapter:gsub('import sys,json,os,stat', 'import sys,json,os,stat,time; time.sleep(0.1)')
  config.explain_agent = { 'python3', '-c', slow }
  count = #notices
  explain.run(config, 'disk race')
  vim.defer_fn(function() vim.fn.writefile({ 'external' }, root .. '/unsaved.py') end, 30)
  wait(function() return #notices > count end, 'reject disk mutation')
  assert(#marks() == 0)
  vim.fn.delete(root .. '/unsaved.py')
  count = #notices
  explain.run(config, 'eol race')
  vim.defer_fn(function() vim.bo[source].endofline = false end, 30)
  wait(function() return #notices > count end, 'reject eol mutation')
  assert(#marks() == 0)
  vim.bo[source].endofline = true
  config.explain_agent = { 'python3', '-c', 'import time; time.sleep(3)' }
  explain.run(config, 'cancel')
  assert(explain.stop() and not explain.stop())
  config.explain_agent = { 'python3', '-c', 'import sys; sys.stdout.write("x"*200000)' }
  count = #notices
  explain.run(config, 'large')
  wait(function() return #notices > count end, 'bounded stdout')
  assert(notices[#notices]:find('size limit', 1, true))
  config.explain_agent = { 'python3', '-c', 'import time; time.sleep(3)' }
  config.agent_timeout_ms = 30
  count = #notices
  explain.run(config, 'timeout')
  wait(function() return #notices > count end, 'timeout')
  assert(#marks() == 0)

  -- Chat is the persistent agent session UI, not a terminal/context-file pipeline.
  local input_fail = vim.ui.input
  vim.ui.input = function() error('simulated prompt failure') end
  assert(explain.run(config))
  assert(not explain.stop(), 'prompt failure must clear pending state')
  vim.ui.input = input_fail
  vim.api.nvim_set_current_buf(source)
  config.agent_timeout_ms = 1500
  config.agent = { 'python3', '-c', [[import json,sys,os,stat
r=json.load(sys.stdin)
assert stat.S_IMODE(os.stat('.').st_mode)==0o700
assert r['intent']=='chat' and r['prompt'] in ('first','second')
assert isinstance(r['history'],list) and r['session_id']
if r['prompt']=='second':
    assert any(t['role']=='user' and t['content']=='first' for t in r['history'])
    assert any(t['role']=='assistant' and t['content']=='PERSISTENT_HISTORY_OK' for t in r['history'])
json.dump({'message':'PERSISTENT_HISTORY_OK' if r['prompt']=='first' else 'HISTORY_REUSED_OK'},sys.stdout)
]] }
  assert(chat.open(config))
  local view = vim.api.nvim_get_current_buf()
  assert(vim.bo[view].buftype == 'nofile', 'chat must use a native history view')
  require('hodocode.agent').run(config, 'first', 'chat', { buf = source })
  wait(function() return not require('hodocode.session').get().request end, 'session chat reply')
  assert(table.concat(vim.api.nvim_buf_get_lines(view, 0, -1, false), '\n'):find('PERSISTENT_HISTORY_OK', 1, true))
  local history = vim.deepcopy(require('hodocode.session').get().history)
  chat.hide()
  assert(chat.open(config))
  assert(vim.deep_equal(require('hodocode.session').get().history, history), 'hide discarded history')
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('PERSISTENT_HISTORY_OK', 1, true))
  local session_id = require('hodocode.session').get().id
  require('hodocode.agent').run(config, 'second', 'chat', { buf = source })
  wait(function() return not require('hodocode.session').get().request end, 'shared adapter history')
  assert(require('hodocode.session').get().id == session_id, 'conversation changed across sends')
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('HISTORY_REUSED_OK', 1, true))
  chat.hide()
  vim.api.nvim_set_current_buf(source)
  explain.clear()
  local leftover = assert(prep.tempdir())
  vim.fn.writefile({ 'adapter-created' }, leftover .. '/extra')
  count = #notices
  prep.remove_dir(leftover)
  assert(#notices == count + 1 and notices[#notices]:find(leftover, 1, true))
  assert(uv.fs_stat(leftover .. '/extra'), 'never recursively remove adapter-created files')
  uv.fs_unlink(leftover .. '/extra')
  uv.fs_rmdir(leftover)
  vim.fn.delete(root, 'rf')
  print('PASS: real backend unsaved/no-go.mod masking, alias/excludes rejection; fake adapter identity/ranges, races, bounds, timeout/cancel, persistent native chat history and leftover warning; no external AI calls')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
