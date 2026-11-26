local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/bin', 'p')
  local uv = vim.uv or vim.loop
  root = assert(uv.fs_realpath(root))
  local python = vim.fn.exepath('python3')
  local fake = '#!' .. python .. '\n' .. [[import json,os,stat,sys,time
assert sys.argv[1:7]==['--no-additional-dirs','ask','--ask','--json','--no-save','--system']
assert os.environ['HODOCODE_EDIT_PROTOCOL']=='2'
assert os.environ['HODOCODE_AGENT_TIMEOUT_MS'] in ('5000','1500')
assert 'ORIGINAL supplied' in sys.argv[7] and 'FULL replacement' not in sys.argv[7]
r=json.load(sys.stdin)
assert set(r)=={'prompt','buffer','intent','session_id','request_id','history'}
assert r['intent']=='edit' and r['session_id'] and r['request_id']
assert isinstance(r['history'],list)
if r['prompt']=='timeout':
    assert any(t['role']=='user' and t['content']=='change value' for t in r['history'])
    assert any(t['role']=='assistant' and t['content']=='編集しました' for t in r['history'])
b=r['buffer']
assert b['name']=='main.py' and 'path' not in b
assert '*user* `text`' in b['content'] and r['prompt'] in ('change value','timeout')
if r['prompt']=='timeout': time.sleep(10)
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
assert ROOT not in os.getcwd() and ROOT not in json.dumps(r)
result={'message':'編集しました','edits':[{'old_text':'value = 1','new_text':'value = 2'}]}
json.dump({'output':json.dumps(result,ensure_ascii=False),'final_output':'WRONG: stripped formatted source'},sys.stdout,ensure_ascii=False)
]]
  fake = fake:gsub('ROOT', string.format('%q', root))
  vim.fn.writefile(vim.split(fake, '\n', { plain = true }), root .. '/bin/fx')
  assert(uv.fs_chmod(root .. '/bin/fx', 493))
  local path = root .. '/main.py'
  vim.fn.writefile({ 'value = 1' }, path)
  vim.cmd.edit(path)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo.filetype = 'python'
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { '# *user* `text`' })
  local old_path = vim.env.PATH
  vim.env.PATH = root .. '/bin:' .. old_path
  local config = { agent = { python, vim.fn.getcwd() .. '/examples/edit-fx.py' }, agent_timeout_ms = 5000, max_agent_bytes = 1024 * 1024 }
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local agent = require('hodocode.agent')
  agent.run(config, 'change value')
  assert(vim.wait(6000, function() return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'value = 2' end, 10), table.concat(notices, '\n') .. '\n' .. table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'))
  assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == '# *user* `text`')
  assert(vim.deep_equal(vim.fn.readfile(path), { 'value = 1' }), 'must not autosave')
  require('hodocode.chat').hide()
  vim.api.nvim_set_current_buf(buf)
  assert(#vim.api.nvim_list_tabpages() == 1, 'must not open diff automatically')
  assert(agent.status(buf).phase == 'done' and not agent.status(buf).running)
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace('HodoCodeAgentChanges'), 0, -1, {})
  assert(#marks > 0, 'partial edit must mark changed lines')
  config.agent_timeout_ms = 1500
  agent.run(config, 'timeout')
  require('hodocode.chat').open(config)
  assert(vim.wait(3000, function() return not agent.status(buf).running end, 10), 'helper timeout never completed')
  assert(agent.status(buf).code == 'timeout' and agent.status(buf).phase == 'error', 'inner deadline classification lost')
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'value = 2', 'timeout changed buffer')
  assert(vim.deep_equal(vim.fn.readfile(path), { 'value = 1' }), 'timeout saved buffer')
  require('hodocode.chat').hide()
  vim.api.nvim_set_current_buf(buf)
  agent.diff()
  assert(require('hodocode.inline_diff').visible(buf))
  assert(vim.deep_equal(agent.baseline(buf).lines, { 'value = 1' }))
  assert(#vim.api.nvim_list_tabpages() == 1, 'inline diff opened a tab')
  agent.diff()
  assert(not require('hodocode.inline_diff').visible(buf))
  agent.stop()
  vim.env.PATH = old_path
  vim.fn.delete(root, 'rf')
  print('PASS: actual edit-fx subprocess + local fake fx, negotiated partial edits, private cwd/basename/raw literals, configured inner timeout, dirty apply/marks/explicit saved diff; no network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
