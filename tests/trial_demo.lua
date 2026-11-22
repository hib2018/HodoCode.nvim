local function run()
  local plugin = vim.fn.getcwd()
  vim.opt.runtimepath:prepend(plugin)
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'package main', '// private comment', 'func main() { println("secret") }' })
  hc.setup({ root = root,
    explain_agent = { 'python3', plugin .. '/examples/explain-demo.py' },
    chat = { 'python3', plugin .. '/examples/chat-demo.py', '{context}' },
  })
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local ns = vim.api.nvim_create_namespace('HodoCodeExplain')
  local function wait(test, label)
    assert(vim.wait(10000, test, 10), label .. '\n' .. table.concat(notices, '\n'))
  end
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) end
  hc.explain('デモ')
  wait(function() return #marks() > 0 end, 'demo line explanations')
  assert(#marks() == 2 and vim.bo[source].modified, 'demo must annotate code only, without writes')
  hc.notes_toggle()
  assert(#marks() == 0)
  hc.notes_toggle()
  assert(#marks() == 2)
  hc.notes_show()
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false)):find('AIへは送信していません', 1, true))
  vim.api.nvim_win_close(0, true)
  hc.chat()
  wait(function() return vim.bo.buftype == 'terminal' end, 'demo chat terminal')
  local terminal = vim.api.nvim_get_current_buf()
  wait(function()
    return table.concat(vim.api.nvim_buf_get_lines(terminal, 0, -1, false)):find('AI未接続', 1, true) ~= nil
  end, 'demo terminal UI')
  assert(not table.concat(vim.api.nvim_buf_get_lines(terminal, 0, -1, false)):find('secret', 1, true))
  vim.fn.chansend(vim.b[terminal].terminal_job_id, '/quit\n')
  wait(function() return not vim.api.nvim_buf_is_valid(terminal) end, 'demo terminal exit cleanup')
  assert(vim.api.nvim_get_current_buf() == source)
  vim.cmd.stopinsert()
  hc.setup({ root = root })
  assert(#marks() == 0, 'setup must clear previous annotations')
  hc.cancel()
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: bundled local demos + real prepare-buffer, annotations/popup and terminal lifecycle; no AI/network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
