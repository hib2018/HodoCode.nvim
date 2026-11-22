local function run()
  local plugin = vim.fn.getcwd()
  vim.opt.runtimepath:prepend(plugin)
  local uv = vim.uv or vim.loop
  local hc = require('hodocode')
  local prep = require('hodocode.prepare')
  local explain = require('hodocode.explain')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.cmd.edit(root .. '/unsaved.go')
  local source = vim.api.nvim_get_current_buf()
  local lines = {
    'package main',
    '',
    'func outsideCode() {',
    '  println("OUTSIDE_SECRET")',
    '}',
    '',
    '// OUTSIDE_COMMENT',
    'func 日本語() {',
    '  println("SECRET", "日本語")',
    '  println(1)',
    '}',
    'var outsideCodeMarker = 1',
  }
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  local original = table.concat(lines, '\n') .. '\n'
  local version = vim.fn.sha256(original)
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = tostring(message) end
  local function wait(test, label)
    assert(vim.wait(5000, test, 10), label .. '\n' .. table.concat(notices, '\n'))
  end
  local ns = vim.api.nvim_create_namespace('HodoCodeExplain')
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) end
  local function cursor(row) vim.api.nvim_win_set_cursor(0, { row, 0 }) end
  local adapter = [[import sys,json,os,stat
r=json.load(sys.stdin)
b=r['buffer']
assert b['file']==b['path']=='unsaved.go'
assert b['start_line']==8 and b['end_line']==11
assert b['version']==]] .. string.format('%q', version) .. '\n' .. [[
s=json.dumps(r,ensure_ascii=False)
assert all(token not in s for token in ['SECRET','outsideCode','OUTSIDE_COMMENT','package main'])
lines=b['content'].splitlines()
assert len(lines)==4 and lines[0]=='func 日本語() {' and lines[-1]=='}'
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
json.dump(dict(version=b['version'],message='関数の説明',comments=[dict(file=b['file'],line=2,end_line=3,text='日本語の解説\nUTF8 detail')]),sys.stdout,ensure_ascii=False)
]]
  local backend = plugin .. '/bin/hodocode'
  assert(vim.fn.executable(backend) == 1, 'run make build before this test')
  hc.setup({ root = root, backend = { backend }, explain_agent = { 'python3', '-c', adapter },
    timeout_ms = 1500, agent_timeout_ms = 1500, max_agent_bytes = 131072 })

  local prepared, prepare_error, finished
  prep.run({}, hc.config, assert(prep.capture(hc.config)), 'Function snapshot', function(value, err, encoded)
    prepared, prepare_error, finished = value, err, true
    if value then assert(vim.deep_equal(vim.json.decode(encoded), value)) end
  end, 9)
  wait(function() return finished end, 'real function prepare')
  assert(prepared, prepare_error)
  assert(prepared.buffer.start_line == 8 and prepared.buffer.end_line == 11)
  assert(prepared.buffer.version == version, 'version must hash the full unsaved buffer, not the snippet')
  assert(#vim.split(vim.trim(prepared.buffer.content), '\n', { plain = true }) == 4)
  assert(not prepared.buffer.content:find('SECRET', 1, true))
  assert(not prepared.buffer.content:find('outsideCode', 1, true))

  local system, starts = prep.system, 0
  prep.system = function(state, argv, ...)
    if argv[1] == 'python3' then starts = starts + 1 end
    return system(state, argv, ...)
  end
  cursor(9)
  hc.explain('Explain only this function')
  wait(function() return #marks() == 1 end, 'function-only adapter request and UTF8 response')
  assert(starts == 1 and marks()[1][2] == 8, 'relative line 2 must map to actual function line 9')
  local function virtual_text()
    return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })[1][4].virt_text[1][1]
  end
  assert(virtual_text() == '  🤖 日本語の解説 UTF8 detail', 'missing robot prefix on explanation')
  assert(explain.toggle() and #marks() == 0)
  assert(explain.toggle() and #marks() == 1)
  assert(virtual_text() == '  🤖 日本語の解説 UTF8 detail', 'toggle lost or duplicated robot prefix')
  cursor(10)
  assert(explain.show(), 'relative end_line must also map to the buffer')
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('UTF8 detail', 1, true))
  vim.api.nvim_win_close(0, true)
  vim.api.nvim_buf_set_lines(source, 9, 10, false, { '  println(2)' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(#marks() == 0 and not explain.toggle(), 'edits must clear stale function comments')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)

  local count, before = #notices, starts
  cursor(1)
  hc.explain('Outside a function')
  wait(function() return #notices > count end, 'reject cursor outside function')
  assert(starts == before and #marks() == 0, 'outside-function requests must not fall back to full-buffer AI')

  cursor(9)
  for _, range in ipairs({ 'line=0,end_line=2', 'line=5,end_line=5', 'line=2,end_line=5',
    'line=3,end_line=2', 'line=1.5,end_line=2' }) do
    hc.config.explain_agent = { 'python3', '-c', (adapter:gsub('line=2,end_line=3', range)) }
    count, before = #notices, starts
    hc.explain('Reject malformed relative range')
    wait(function() return #notices > count end, 'reject relative range: ' .. range)
    assert(starts == before + 1 and #marks() == 0, 'invalid ranges must not render buffer-relative comments')
  end
  hc.config.explain_agent = { 'python3', '-c', adapter }

  local input, delayed = vim.ui.input
  vim.ui.input = function(_, callback) delayed = callback end
  cursor(9)
  hc.explain()
  assert(type(delayed) == 'function')
  cursor(4)
  delayed('Keep the original function')
  wait(function() return #marks() == 1 end, 'delayed prompt captures original cursor row')
  assert(marks()[1][2] == 8, 'moving during prompt must not select a different function')
  explain.clear()

  cursor(9)
  hc.explain()
  before = starts
  vim.api.nvim_buf_set_lines(source, 9, 10, false, { '  println(3)' })
  delayed('Do not recapture edited source')
  assert(not explain.stop() and starts == before and #marks() == 0,
    'delayed prompt must reject edits before preparation or adapter launch')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  cursor(9)
  hc.explain()
  before = starts
  assert(explain.stop() and not explain.stop(), 'pending prompt cancellation must be idempotent')
  delayed('Cancelled prompt')
  assert(starts == before and #marks() == 0, 'cancelled prompts must not launch adapters')
  vim.ui.input = input

  hc.config.explain_agent = { 'python3', '-c', 'import time; time.sleep(3)' }
  before = starts
  hc.explain('Cancel running function adapter')
  wait(function() return starts == before + 1 end, 'start local cancellable adapter')
  assert(explain.stop() and not explain.stop())
  assert(#marks() == 0)
  prep.system = system
  assert(table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n') .. '\n' == original)
  assert(vim.bo[source].modified and not uv.fs_stat(root .. '/unsaved.go'), 'source must remain unsaved')
  assert(not uv.fs_stat(root .. '/go.mod'), 'function explanations must not create or require go.mod')
  hc.cancel()
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: real no-go.mod unsaved function masking, full hash, relative UTF8 ranges, outside-function rejection, delayed cursor/edit capture, stale comments and cancellation; local adapters only, no AI/network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
