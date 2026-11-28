local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = false
  vim.o.lines, vim.o.columns = 35, 120
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  root = (vim.uv or vim.loop).fs_realpath(root)
  local path, other_path = root .. '/source.txt', root .. '/other.txt'
  vim.fn.writefile({ 'top', 'value = 1', 'end' }, path)
  vim.fn.writefile({ 'other', 'saved reference', 'end' }, other_path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local source = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { 'manual change' })
  local other = vim.fn.bufadd(other_path)
  vim.fn.bufload(other)
  vim.api.nvim_buf_set_lines(other, 1, 2, false, { 'unsaved reference' })
  local config = { root = root, max_agent_bytes = 1024 * 1024, agent_timeout_ms = 3000,
    agent = { 'python3', '-c', [[import hashlib,json,sys
r=json.load(sys.stdin)
assert r['buffer']['relative_path']=='source.txt'
print(json.dumps({'event':'result','version':hashlib.sha256(r['buffer']['content'].encode()).hexdigest(),
 'message':'See `other.txt:2` and `source.txt:2`.',
 'edits':[{'old_text':'value = 1','new_text':'value = 2'}]}))]] } }
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local agent, chat, session = require('hodocode.agent'), require('hodocode.chat'), require('hodocode.session')
  assert(agent.run(config, 'update'))
  assert(vim.wait(4000, function() return session.get().request == nil end, 10), table.concat(notices, '\n'))
  local state = session.get()
  local answer = state.history[#state.history]
  assert(answer.status == 'applied' and answer.root == root and answer.changes[1].line == 2)
  local chatbuf = vim.api.nvim_get_current_buf()
  assert(chat.is_view(chatbuf) and chat.visible())
  local function enter()
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(chatbuf, 'n')) do
      if mapping.lhs == '<CR>' then return mapping.callback() end
    end
    error('missing Enter mapping')
  end
  local function select_link(needle)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(chatbuf, 0, -1, false)) do
      local col = line:find(needle, 1, true)
      if col then vim.api.nvim_win_set_cursor(0, { row, col - 1 }); return row, col - 1 end
    end
    error('missing link: ' .. needle)
  end
  local row, col = select_link('other.txt:2')
  enter()
  assert(not chat.visible(), 'actual flat session metadata did not create a clickable answer link')
  assert(vim.api.nvim_get_current_buf() == other and vim.api.nvim_win_get_cursor(0)[1] == 2)
  assert(vim.bo[other].modified and vim.api.nvim_buf_get_lines(other, 1, 2, false)[1] == 'unsaved reference')
  assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 3, 4, false)[1] == 'manual change')
  assert(chat.open(config))
  assert(vim.api.nvim_get_current_buf() == chatbuf)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { row, col }), 'link return lost position')
  select_link('変更箇所:')
  local current = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(chatbuf, current[1] - 1, current[1], false)[1]
  vim.api.nvim_win_set_cursor(0, { current[1], assert(line:find('source.txt:2', 1, true)) - 1 })
  enter()
  assert(not chat.visible() and vim.api.nvim_get_current_buf() == source)
  assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
  assert(agent.diff() and require('hodocode.inline_diff').visible(source))
  local ns = vim.api.nvim_create_namespace('HodoCodeInlineDiff')
  assert(#vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) > 0)
  vim.cmd.undo()
  assert(vim.api.nvim_buf_get_lines(source, 1, 2, false)[1] == 'value = 1')
  assert(chat.open(config))
  enter()
  assert(chat.visible(), 'undo invalidated the anchor but still jumped')
  assert(session.get() == state and #state.history == 2)
  assert(vim.fn.readfile(path)[2] == 'value = 1' and vim.fn.readfile(other_path)[2] == 'saved reference')
  chat.shutdown(); agent.shutdown(); require('hodocode.inline_diff').shutdown()
  vim.fn.delete(root, 'rf')
  print('PASS: actual JSON adapter -> flat session -> answer/change links -> dirty buffer reuse -> return -> inline diff/undo guard')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
