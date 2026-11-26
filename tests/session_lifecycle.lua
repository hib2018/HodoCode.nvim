local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  vim.cmd('runtime plugin/hodocode.lua')
  local hc, agent, chat, session = require('hodocode'), require('hodocode.agent'), require('hodocode.chat'), require('hodocode.session')
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local adapter = root .. '/adapter.py'
  vim.fn.writefile(vim.split([[import json,os,signal,sys,time
r=json.load(sys.stdin)
def stop(*_):
    with open(sys.argv[2]+'.stopped','w') as f: f.write('stopped')
    sys.exit(0)
signal.signal(signal.SIGTERM,stop)
with open(sys.argv[2],'w') as f: json.dump({'pid':os.getpid(),'cwd':os.getcwd()},f)
if sys.argv[1]=='exit': time.sleep(20)
else:
    time.sleep(.2)
    print(json.dumps({'message':'done','content':'after\n'}),flush=True)
]], '\n', { plain = true }), adapter)
  local path = root .. '/source.txt'
  vim.fn.writefile({ 'before' }, path)
  vim.cmd.edit(path)
  local source = vim.api.nvim_get_current_buf()
  local trace = root .. '/live'
  hc.setup({ agent = { 'python3', adapter, 'normal', trace }, agent_timeout_ms = 3000 })
  vim.notify = function() end
  package.loaded['hodocode.marker'] = { start = function() end, stop = function() end }
  hc.mode()
  hc.agent('change')
  assert(vim.wait(1000, function() return uv.fs_stat(trace) ~= nil end, 5))
  local id = session.get().id
  vim.cmd('q') -- Close only the agent window, not Neovim or the request.
  assert(session.get().request and not chat.visible())
  hc.exit_mode()
  vim.cmd.vsplit()
  vim.cmd.enew()
  local unrelated = vim.api.nvim_get_current_buf()
  assert(vim.wait(3000, function() return session.get().request == nil end, 5))
  assert(session.get().id == id and #session.history() == 2)
  assert(vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == 'after')
  assert(vim.api.nvim_get_current_buf() == unrelated and not chat.visible(), 'completion stole focus')
  hc.chat()
  assert(chat.visible())
  chat.open(hc.config, { buf = source, win = vim.fn.win_findbuf(source)[1], cursor = { 1, 0 } })
  local original_run, routed = agent.run
  agent.run = function(config, prompt, intent, target)
    routed = target and target.buf == source and intent == 'edit' and prompt == 'from conversation'
  end
  hc.agent('from conversation')
  agent.run = original_run
  assert(routed, ':HodoCodeAgent in conversation must use its source, not the readonly view')
  chat.hide()
  hc.setup({ agent = { 'python3', adapter, 'normal', trace }, agent_timeout_ms = 3000 })
  assert(session.get().id == id and #session.history() == 2, 'setup reset conversation')
  assert(vim.deep_equal(vim.fn.readfile(path), { 'before' }), 'must not autosave')

  -- A separate real Neovim process must clean its live worker on actual exit.
  local exit_trace, child = root .. '/exit', root .. '/child.lua'
  local script = string.format([[
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd('runtime plugin/hodocode.lua')
vim.cmd.edit(%q)
require('hodocode').setup({agent={'python3',%q,'exit',%q},agent_timeout_ms=30000})
require('hodocode').agent('stay busy')
assert(vim.wait(2000,function() return (vim.uv or vim.loop).fs_stat(%q)~=nil end,5))
vim.cmd('qa!')
]], path, adapter, exit_trace, exit_trace)
  vim.fn.writefile(vim.split(script, '\n', { plain = true }), child)
  local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', child }, { text = true, timeout = 6000 }):wait()
  assert(result.code == 0, result.stderr or 'child Neovim failed')
  assert(vim.wait(2000, function() return uv.fs_stat(exit_trace .. '.stopped') ~= nil end, 5), 'VimLeavePre did not stop worker')
  local record = vim.json.decode(table.concat(vim.fn.readfile(exit_trace), '\n'))
  assert(not uv.fs_stat(record.cwd), 'VimLeavePre left private cwd')
  chat.shutdown()
  agent.shutdown()
  require('hodocode.inline_diff').shutdown()
  vim.fn.delete(root, 'rf')
  print('PASS: real :q hides without cancellation; mode/focus/setup preserve session; actual Neovim exit stops worker and removes resources')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
