local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  local hc = require('hodocode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local original = { 'one', 'old', 'delete', 'end' }
  vim.fn.writefile(original, root .. '/main.py')
  vim.cmd.edit(root .. '/main.py')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '#user' })
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  hc.setup({ agent = { 'python3', '-c', [[import json,sys
r=json.load(sys.stdin)
assert r['prompt']=='change it' and r['buffer']['content']=='one\nold\ndelete\nend\n#user\n'
json.dump({'message':'done','content':'one\nnew\nend\n#user\n'},sys.stdout)]] } })
  require('hodocode.client').start = function() error('editing must not reparse or reload saved disk') end
  require('hodocode.marker').start = function() end
  local function invoke(key)
    local callback = vim.fn.maparg(key, 'n', false, true).callback
    assert(type(callback) == 'function', 'missing ' .. key)
    callback()
  end
  hc.mode()
  local tabs = #vim.api.nvim_list_tabpages()
  invoke('A')
  local prompt = vim.api.nvim_get_current_buf()
  assert(prompt ~= source and vim.bo[prompt].modifiable)
  assert(vim.api.nvim_win_get_config(0).relative == 'editor', 'request must be a popup')
  vim.api.nvim_buf_set_lines(prompt, 0, -1, false, { 'change it' })
  vim.cmd.stopinsert()
  invoke('<C-s>')
  assert(vim.wait(5000, function() return vim.api.nvim_buf_get_lines(source, 1, 2, false)[1] == 'new'  end, 5), table.concat(notices, '\n'))
  assert(#vim.api.nvim_list_tabpages() == tabs, 'edit must not open diff')
  assert(require('hodocode.mode').active(), 'source d mapping must remain available')
  assert(vim.bo[source].modified and vim.deep_equal(vim.fn.readfile(root .. '/main.py'), original))
  local ns = vim.api.nvim_create_namespace('HodoCodeAgentChanges')
  local marks = vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })
  assert(#marks == 1 and marks[1][2] == 1, vim.inspect(marks))
  assert(marks[1][4].virt_text[1][1]:find('🤖', 1, true))
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(#vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) == 1, 'own edit event must preserve marks')
  assert(vim.api.nvim_get_current_win() ~= source_win, 'success must preserve prompt/chat focus')
  require('hodocode.chat').hide()
  vim.api.nvim_set_current_win(source_win)
  invoke('d')
  assert(#vim.api.nvim_list_tabpages() == tabs)
  assert(require('hodocode.inline_diff').visible(source))
  assert(vim.deep_equal(require('hodocode.agent').baseline(source).lines, original))
  invoke('d')
  assert(not require('hodocode.inline_diff').visible(source))
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '#manual' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(#vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) == 0, 'later user edits must clear stale markers')
  hc.cancel()
  vim.fn.delete(root, 'rf')
  print('PASS: A popup request -> buffer redraw/persistent chat + AI-only robot markers -> explicit d inline saved diff; no auto diff/save/reanalysis/network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
