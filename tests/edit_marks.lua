local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.notify = function() end
  local marks = require('hodocode.edit_marks')
  local ns = vim.api.nvim_create_namespace('HodoCodeAgentChanges')
  local buf = vim.api.nvim_get_current_buf()
  local function check(before, after, expected)
    local lines = vim.split(after, '\n', { plain = true })
    if after:sub(-1) == '\n' then table.remove(lines) end
    if #lines == 0 then lines = { '' } end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    marks.set(buf, before, after)
    local actual = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    assert(#actual == #expected, vim.inspect(actual))
    for i, row in ipairs(expected) do
      assert(actual[i][2] == row and actual[i][4].virt_text[1][1]:find('🤖', 1, true), vim.inspect(actual))
    end
  end
  check('a\nb\n', 'a\nc\nd\n', { 1, 2 })
  check('a\nb\nc\n', 'a\nc\n', { 1 })
  check('a\nb\n', 'b\n', { 0 })
  check('a\n', '', { 0 })
  check('a\n', 'a', { 0 })
  check('a\n', 'a\n', {})
  local big = {}
  for i = 1, 1005 do big[i] = tostring(i) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, big)
  marks.set(buf, '', table.concat(big, '\n') .. '\n')
  assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 1000, 'decoration cost must be bounded')
  vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf })
  assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)
  print('PASS: AI change/insert/deletion/empty/EOF markers, bounded decorations, save cleanup')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
