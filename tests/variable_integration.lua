local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local lines = { 'package main', 'func main() {', ' var count int', ' count = 2', ' count++', ' _ = "日本語"', ' _ = count', '}' }
  vim.fn.writefile({ 'module example.test/variables', '', 'go 1.23' }, root .. '/go.mod')
  vim.fn.writefile(lines, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local requests = {}
  local session = { stopped_thread_id = 1, current_frame = { id = 9, line = 4, name = 'main.main', source = { path = root .. '/main.go' } } }
  function session:request(command, args, callback)
    requests[#requests + 1] = command
    if command == 'scopes' then
      assert(args.frameId == 9)
      callback(nil, { scopes = { { name = 'Locals', variablesReference = 10 } } })
    elseif command == 'variables' then
      assert(args.variablesReference == 10)
      callback(nil, { variables = { { name = 'count', value = '7', type = 'int' } } })
    else error('unexpected DAP request: ' .. command) end
  end
  local dap = { session = function() return session end, listeners = { after = {
    event_continued = {}, event_stopped = {}, event_terminated = {}, event_exited = {},
  } } }
  package.loaded.dap = dap
  local hc = require('hodocode')
  hc.setup({ root = root, timeout_ms = 30000, explain_agent = { 'false' } })
  local ai = 0
  require('hodocode.prepare').system = function() ai = ai + 1; error('variable information must never use AI') end
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  end
  local function press(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
  end
  hc.mode()
  vim.api.nvim_win_set_cursor(source_win, { 7, assert(lines[7]:find('count', 1, true)) - 1 })
  press('s')
  assert(vim.wait(35000, function() return vim.bo.buftype == 'nofile' and text():find('count = 7', 1, true) end, 10), table.concat(notices, '\n') .. '\n' .. text())
  for _, expected in ipairs({ '変数情報: count', '型: int', 'ゼロ初期化', 'count++', 'count = 2', '参照箇所', '静的解析では不明', 'カーソル行の値ではありません', '一致は未検証' }) do
    assert(text():find(expected, 1, true), 'missing ' .. expected .. '\n' .. text())
  end
  assert(vim.deep_equal(requests, { 'scopes', 'variables' }) and ai == 0)
  local popup = vim.api.nvim_get_current_win()
  for _, listener in pairs(dap.listeners.after.event_continued) do listener(session) end
  assert(vim.wait(1000, function() return text():find('値は無効', 1, true) end, 10))
  assert(not text():find('count = 7', 1, true), 'stale DAP value remained')
  press('q')
  assert(not vim.api.nvim_win_is_valid(popup) and vim.api.nvim_get_current_win() == source_win)
  press('s')
  assert(vim.wait(35000, function() return vim.bo.buftype == 'nofile' end, 10))
  popup = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// unsaved' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(not vim.api.nvim_win_is_valid(popup), 'source edit must close variable popup')
  assert(ai == 0)
  hc.exit_mode()
  require('hodocode.client').stop_all()
  assert(vim.deep_equal(vim.fn.readfile(root .. '/main.go'), lines), 'source was modified')
  vim.fn.delete(root, 'rf')
  print('PASS: real backend+s variable metadata, static type/initialization/references/updates, mocked stopped DAP, frame labeling/resume invalidation/edit cleanup; no AI/source writes')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
