local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/bin', 'p')
  local uv = vim.uv or vim.loop
  root = assert(uv.fs_realpath(root))
  local python = vim.fn.exepath('python3')
  local fake = '#!' .. python .. '\n' .. [[import json,os,stat,sys
assert sys.argv[1:7]==['--no-additional-dirs','ask','--ask','--json','--no-save','--system']
r=json.load(sys.stdin)
assert set(r)=={'prompt','buffer'}
b=r['buffer']
assert b['name']=='main.py' and 'path' not in b
assert '*user* `text`' in b['content'] and r['prompt']=='change value'
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
assert ROOT not in os.getcwd() and ROOT not in json.dumps(r)
result={'message':'編集しました','content':b['content'].replace('value = 1','value = 2')}
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
  if vim.bo.buftype == 'nofile' then vim.api.nvim_win_close(0, true) end
  assert(vim.api.nvim_get_current_buf() == buf, 'successful edit must return to source')
  agent.diff()
  local before
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if b ~= buf then before = b end
  end
  assert(before and vim.deep_equal(vim.api.nvim_buf_get_lines(before, 0, -1, false), { 'value = 1' }))
  assert(not vim.bo[before].modifiable and vim.bo[before].readonly)
  vim.cmd.tabclose()
  agent.stop()
  vim.env.PATH = old_path
  vim.fn.delete(root, 'rf')
  print('PASS: actual edit-fx adapter subprocess + local fake fx, private cwd, basename-only provider payload, raw pointer/backtick preservation, dirty buffer apply and saved diff; no network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
