local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local hc = require('hodocode')
  local start, calls = vim.fn.jobstart, 0
  vim.fn.jobstart = function() calls = calls + 1; error('setup must not start a process') end
  assert(hc.config.agent_transport == 'json')
  hc.setup({ agent_transport = 'acp', agent = { 'fx', 'acp', '--permission-mode', 'ask' } })
  assert(hc.config.agent_transport == 'acp' and hc.config.acp_cancel_timeout_ms == 3000)
  assert(not pcall(hc.setup, { agent_transport = 'unknown' }))
  assert(not pcall(hc.setup, { acp_cancel_timeout_ms = 0 }))
  assert(not pcall(hc.setup, { acp_cancel_timeout_ms = false }))
  hc.setup({ acp_cancel_timeout_ms = 50 })
  assert(hc.config.agent_transport == 'json' and hc.config.acp_cancel_timeout_ms == 50)
  assert(calls == 0, 'configuration must remain lazy')
  vim.fn.jobstart = start
  print('PASS: explicit ACP config, JSON default, positive cancel grace, no setup process')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
