local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module test.variable', '', 'go 1.23' }, root .. '/go.mod')
  local lines = { 'package main', 'func main() {', ' x := 1', ' println(x)', '}' }
  vim.fn.writefile(lines, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local hc = require('hodocode')
  hc.config.root = root
  local metadata = { name = 'x', type = 'int', kind = 'ローカル変数', runtime_safe = true,
    function_file = 'main.go', function_start_line = 2, function_end_line = 5 }
  local help = { title = '変数情報: x', description = '静的情報: 初期値 1 / 更新なし', syntax = 'var x int',
    variable = metadata, translate = true, documentation = 'never translate variables' }
  package.loaded['hodocode.client'] = { start = function() return { request = function(_, method, _, cb)
    if method == 'reload' then cb({}) elseif method == 'syntax' then cb(help) else error(method) end
  end } end }
  package.loaded['hodocode.marker'] = { start = function() end, stop = function() end }
  require('hodocode.prepare').argv = function() error('variables must never enter AI/translation') end
  local loads = 0
  package.preload.dap = function() loads = loads + 1; error('not installed') end
  local function press(key) vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false) end
  local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') end
  local function contains(s) assert(text():find(s, 1, true), s .. '\n' .. text()) end
  local function flush() vim.wait(30, function() return false end, 5) end
  local function show()
    require('hodocode.variable').cancel()
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_win_set_cursor(0, { 3, 1 })
    press('s')
    assert(vim.bo.buftype == 'nofile')
    assert(vim.api.nvim_win_get_config(0).relative == 'editor')
    contains('静的情報: 初期値 1 / 更新なし')
    return vim.api.nvim_get_current_win()
  end
  hc.mode()
  help.variable, help.translate = nil, false
  show(); assert(loads == 0, 'ordinary syntax must not load DAP')
  help.variable, help.translate = metadata, true
  show(); contains('nvim-dap がありません'); assert(loads == 1)
  local calls, queue, current = {}, {}, nil
  local dap = { session = function() return current end, listeners = { after = {} } }
  for _, event in ipairs({ 'event_continued', 'event_stopped', 'event_terminated', 'event_exited' }) do
    dap.listeners.after[event] = {}
  end
  package.loaded.dap = dap
  show(); contains('停止していません')
  local function session()
    calls, queue = {}, {}
    current = { stopped_thread_id = 1, current_frame = { id = 7, line = 4, name = 'main', source = { path = root .. '/main.go' } } }
    function current:request(command, args, cb)
      assert(command == 'scopes' or command == 'variables', 'no evaluate or child expansion')
      calls[#calls + 1] = { command, args }
      queue[#queue + 1] = cb
    end
  end
  local function reply(value, err)
    local cb = assert(table.remove(queue, 1), 'missing callback')
    cb(err, value); flush()
  end
  local scopes = { scopes = { { name = 'Locals', variablesReference = 10 }, { presentationHint = 'arguments', variablesReference = 11 },
    { name = 'Globals', variablesReference = 99 }, { name = 'Locals', expensive = true, variablesReference = 98 } } }
  local function values(v1, v2)
    reply(scopes)
    assert(#calls == 3 and calls[1][2].frameId == 7 and calls[2][2].variablesReference == 10 and calls[3][2].variablesReference == 11)
    reply({ variables = v1 }); reply({ variables = v2 or {} })
  end
  session(); local popup = show()
  assert(#calls == 1); contains('取得中')
  values({ { name = 'xx', value = 'wrong' }, { name = 'x', value = '42', variablesReference = 100 } })
  contains('x = 42'); contains('カーソル行の値ではありません'); contains('一致は未検証'); contains('id=7')
  assert(vim.api.nvim_get_current_win() == popup and #calls == 3)
  for _, cb in pairs(dap.listeners.after.event_continued) do cb(current) end
  flush(); contains('値は無効'); assert(not text():find('x = 42', 1, true))
  session(); popup = show(); local popup_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_win(source_win)
  values({ { name = 'x', value = '43' } })
  assert(vim.api.nvim_get_current_win() == source_win, 'async update must not steal focus')
  assert(table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), '\n'):find('x = 43', 1, true))
  current.current_frame.id = 8
  assert(vim.wait(300, function() return table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), '\n'):find('値は無効', 1, true) ~= nil end, 10))
  session(); show(); values({ { name = 'x', value = '1' } }, { { name = 'x', value = '2' } }); contains('同名変数が複数')
  session(); show(); values({ { name = 'xx', value = '1' } }); contains('完全一致する変数がありません')
  for _, value in ipairs({ 42, 'bad\0value' }) do
    session(); show(); values({ { name = 'x', value = value } }); contains('値が不正またはありません')
    assert(not text():find('\0', 1, true), 'invalid values must not enter the popup')
  end
  session(); show(); reply(nil, 'adapter error'); contains('取得エラー')
  session(); show(); reply({}); contains('応答が不正')
  session(); current.current_frame.line = 1; show(); contains('関数の範囲外'); assert(#calls == 0)
  session(); current.current_frame.source.path = root .. '/else.go'; show(); contains('関数の範囲外'); assert(#calls == 0)
  for _, source_info in ipairs({ false, 42, 'invalid', {}, { path = 42 }, { path = {} }, { path = 'bad\0path' } }) do
    session(); current.current_frame.source = source_info
    show(); contains('関数の範囲外'); assert(#calls == 0)
  end
  for _, kind in ipairs({ 'フィールド', 'パッケージ変数', '定数' }) do
    session(); metadata.kind = kind; show(); contains('取得対象ではありません'); assert(#calls == 0)
  end
  metadata.kind = 'ローカル変数'
  session(); metadata.runtime_safe = false; show(); assert(#calls == 0); metadata.runtime_safe = true
  session(); show(); local old = table.remove(queue, 1); press('q'); old(nil, scopes); flush(); assert(#calls == 1)
  session(); show(); old = table.remove(queue, 1); hc.cancel(); old(nil, scopes); flush(); assert(vim.api.nvim_get_current_win() == source_win and #calls == 1)
  session(); show(); old = table.remove(queue, 1); current.current_frame = vim.deepcopy(current.current_frame)
  old(nil, scopes); flush(); assert(#calls == 1); vim.wait(300, function() return text():find('値は無効', 1, true) ~= nil end, 10); contains('値は無効')
  session(); show(); old = table.remove(queue, 1); current = nil; old(nil, scopes); flush(); assert(#calls == 1)
  session(); show(); assert(vim.wait(3500, function() return text():find('タイムアウト', 1, true) ~= nil end, 10)); old = table.remove(queue, 1); old(nil, scopes); flush(); assert(#calls == 1)
  session(); popup = show(); old = table.remove(queue, 1)
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// edit' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  old(nil, scopes); flush(); assert(not vim.api.nvim_win_is_valid(popup) and #calls == 1)
  require('hodocode.variable').cancel()
  hc.exit_mode()
  vim.fn.delete(root, 'rf')
  print('PASS: s variable static popup; optional mocked DAP, exact local/args reads, guards, ambiguity, errors, timeout, cancellation, source edits; no AI/evaluate/expansion')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
