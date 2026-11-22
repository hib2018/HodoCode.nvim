local function run()
  local plugin = vim.fn.getcwd()
  vim.opt.runtimepath:prepend(plugin)
  vim.o.columns, vim.o.lines = 140, 45
  vim.cmd('runtime plugin/hodocode.lua')
  local uv = vim.uv or vim.loop
  local hc = require('hodocode')
  local prep = require('hodocode.prepare')
  local explain = require('hodocode.explain')
  local mode = require('hodocode.mode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.cmd.edit(root .. '/unsaved.go')
  local source = vim.api.nvim_get_current_buf()
  local lines = {
    'package main',
    'var hidden = `BEFORE_SECRET',
    'INSIDE_SECRET',
    'AFTER_SECRET`',
    '',
    'var 日本語 = "SELECTED_SECRET" // COMMENT_SECRET',
    '',
    'func outsideCode() {',
    '  println("OUTSIDE_SECRET")',
    '}',
  }
  local row = 6
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  local original = table.concat(lines, '\n') .. '\n'
  local version = vim.fn.sha256(original)
  local prompt = 'Explain this line. Read-only; do not modify files.'
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = tostring(message) end
  local function wait(test, label)
    assert(vim.wait(5000, test, 10), label .. '\n' .. table.concat(notices, '\n'))
  end
  local ns = vim.api.nvim_create_namespace('HodoCodeExplain')
  local function marks() return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, {}) end
  local function cursor(line) vim.api.nvim_win_set_cursor(0, { line, 0 }) end
  local function invoke(key)
    local map = vim.fn.maparg(key, 'n', false, true)
    assert(type(map.callback) == 'function', 'missing mode mapping: ' .. key)
    map.callback()
  end
  local adapter = [[import sys,json,os,stat
r=json.load(sys.stdin)
b=r['buffer']
assert r['prompt']=='Explain this line. Read-only; do not modify files.'
assert b['file']==b['path']=='unsaved.go'
assert b['start_line']==b['end_line']==6
assert b['version']==]] .. string.format('%q', version) .. '\n' .. [[
s=json.dumps(r,ensure_ascii=False)
assert all(token not in s for token in ['SECRET','outsideCode','hidden','package main','println'])
lines=b['content'].splitlines()
assert len(lines)==1 and lines[0].startswith('var 日本語 = ')
assert stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
json.dump(dict(version=b['version'],message='行の説明',comments=[dict(file=b['file'],line=1,end_line=1,text='日本語の解説\nUTF8 detail')]),sys.stdout,ensure_ascii=False)
]]
  local backend = plugin .. '/bin/hodocode'
  assert(vim.fn.executable(backend) == 1, 'run make build before this test')
  hc.setup({ root = root, backend = { backend }, explain_agent = { 'python3', '-c', adapter },
    timeout_ms = 1500, agent_timeout_ms = 1500, max_agent_bytes = 131072 })

  local system, starts, preparations, adapter_state = prep.system, 0, 0, nil
  prep.system = function(state, argv, options, ...)
    if argv[1] == backend then
      preparations = preparations + 1
      assert(argv[2] == 'prepare-buffer', 'line explanations must use the real masking backend')
      local payload = vim.json.decode(options.stdin)
      assert(payload.row == nil, 'line scope must not ask the backend for a containing function')
      assert(payload.content == original, 'mask the full unsaved source before selecting one line')
    elseif argv[1] == 'python3' then starts, adapter_state = starts + 1, state
    else error('unexpected process: ' .. tostring(argv[1])) end
    return system(state, argv, options, ...)
  end
  local function prepare(selected)
    local prepared, prepare_error, finished
    prep.run({}, hc.config, assert(prep.capture(hc.config)), prompt, function(value, err, encoded)
      prepared, prepare_error, finished = value, err, true
      if value then assert(vim.deep_equal(vim.json.decode(encoded), value)) end
    end, selected, 'line')
    wait(function() return finished end, 'real single-line prepare')
    assert(prepared, prepare_error)
    assert(prepared.buffer.start_line == selected and prepared.buffer.end_line == selected)
    assert(prepared.buffer.version == version, 'version must hash the full unsaved buffer')
    assert(#vim.split(prepared.buffer.content, '\n', { plain = true }) == 1, 'only one line may leave preparation')
    assert(not prepared.buffer.content:find('SECRET', 1, true))
    assert(not prepared.buffer.content:find('outsideCode', 1, true))
    return prepared.buffer.content
  end
  assert(prepare(row):find('var 日本語', 1, true))
  assert(prepare(1) == 'package main', 'package lines outside functions must work')
  assert(not prepare(3):find('INSIDE_SECRET', 1, true), 'multiline literals must be masked before slicing')
  assert(starts == 0 and preparations == 3)

  local input, pending, inputs = vim.ui.input, nil, 0
  vim.ui.input = function(_, callback) inputs = inputs + 1; pending = callback end
  local run_explain, calls = explain.run, {}
  explain.run = function(config, value, selected, scope)
    calls[#calls + 1] = { config = config, prompt = value, row = selected, scope = scope }
  end
  cursor(row)
  hc.explain_line()
  assert(#calls == 1 and calls[1].config == hc.config and calls[1].prompt == nil
    and calls[1].row == row and calls[1].scope == 'line', 'public line entry point must capture row and scope')
  mode.start()
  invoke('a')
  assert(#calls == 2 and calls[2].prompt == nil and calls[2].row == row and calls[2].scope == 'line',
    'a must dispatch the line entry point with instruction input')
  invoke('E')
  assert(#calls == 3 and calls[3].row == row and calls[3].scope ~= 'line'
    and calls[3].prompt == 'Explain this function line by line. Read-only; do not modify files.',
    'E must retain function explanations')
  vim.cmd('HodoCodeExplain Explain the function')
  assert(#calls == 4 and calls[4].row == row and calls[4].scope ~= 'line'
    and calls[4].prompt == 'Explain the function', 'HodoCodeExplain must retain function explanations')
  explain.run = run_explain

  invoke('a')
  assert(type(pending) == 'function' and inputs == 1, 'a must open instruction input')
  cursor(9)
  pending('')
  cursor(1)
  wait(function() return #marks() == 1 end, 'blank instruction defaults to the line prompt and UTF8 response')
  assert(starts == 1 and marks()[1][2] == row - 1, 'capture cursor before async preparation; relative line 1 maps to selected row')
  local function virtual_text()
    return vim.api.nvim_buf_get_extmarks(source, ns, 0, -1, { details = true })[1][4].virt_text[1][1]
  end
  assert(virtual_text() == '  🤖 日本語の解説 UTF8 detail', 'missing robot virtual text on selected line')
  assert(explain.toggle() and #marks() == 0)
  assert(explain.toggle() and #marks() == 1)
  assert(virtual_text() == '  🤖 日本語の解説 UTF8 detail', 'toggle changed robot prefix')
  cursor(row)
  invoke('K')
  assert(vim.api.nvim_get_current_buf() ~= source, 'K must open the explanation popup')
  assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'):find('UTF8 detail', 1, true))
  vim.api.nvim_win_close(0, true)
  mode.stop()
  vim.api.nvim_buf_set_lines(source, 8, 9, false, { '  println("EDITED_SECRET")' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(#marks() == 0 and not explain.toggle(), 'edits elsewhere must invalidate line comments')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)

  cursor(row)
  local custom = 'Explain the top-level variable in Japanese'
  hc.config.explain_agent = { 'python3', '-c', (adapter:gsub(prompt:gsub('(%W)', '%%%1'), custom)) }
  hc.explain_line('')
  assert(inputs == 2, 'empty initial instruction must open input')
  pending(custom)
  wait(function() return #marks() == 1 end, 'custom line instruction must pass through unchanged')
  explain.clear()
  hc.config.explain_agent = { 'python3', '-c', adapter }
  local before = starts
  hc.explain_line()
  pending(nil)
  assert(starts == before and #marks() == 0 and not explain.stop(), 'nil instruction cancels without launching an adapter')
  hc.explain_line()
  assert(explain.stop() and not explain.stop(), 'pending instruction cancellation must be idempotent')
  pending('Cancelled instruction')
  assert(starts == before and #marks() == 0, 'cancelled prompt callbacks must not launch adapters')
  hc.explain_line()
  vim.api.nvim_buf_set_lines(source, 8, 9, false, { '  println("EDITED_SECRET")' })
  pending('Reject edited source')
  assert(starts == before and #marks() == 0 and not explain.stop(), 'pending instruction must reject source edits')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  for _, range in ipairs({ 'line=2,end_line=2', 'line=1,end_line=2', 'line=0,end_line=1',
    'line=1,end_line=0', 'line=1.5,end_line=1.5' }) do
    hc.config.explain_agent = { 'python3', '-c', (adapter:gsub('line=1,end_line=1', range)) }
    local count, before = #notices, starts
    hc.explain_line(prompt)
    wait(function() return #notices > count end, 'reject invalid line-relative range: ' .. range)
    assert(starts == before + 1 and #marks() == 0, 'only relative line 1/end_line 1 may render')
  end

  local delayed = adapter:gsub('json.dump', 'import time; time.sleep(0.2)\njson.dump', 1)
  hc.config.explain_agent = { 'python3', '-c', delayed }
  before = starts
  hc.explain_line(prompt)
  wait(function() return starts == before + 1 end, 'start delayed local adapter before editing')
  vim.api.nvim_buf_set_lines(source, 8, 9, false, { '  println("EDITED_SECRET")' })
  wait(function() return adapter_state.process == nil end, 'settle delayed response after edit')
  assert(#marks() == 0 and not explain.toggle(), 'delayed responses must reject edits anywhere in the full source')
  assert(not explain.stop(), 'edited request must finish or be cancelled')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  before = starts
  hc.explain_line(prompt)
  wait(function() return starts == before + 1 end, 'start delayed local adapter before cancellation')
  assert(explain.stop() and not explain.stop(), 'line cancellation must be idempotent')
  wait(function() return adapter_state.process == nil end, 'settle cancelled delayed response')
  assert(#marks() == 0 and not explain.toggle(), 'cancelled delayed responses must not render')
  assert(inputs == 5, 'explicit line instructions must bypass input')
  vim.ui.input, prep.system = input, system
  assert(table.concat(vim.api.nvim_buf_get_lines(source, 0, -1, false), '\n') .. '\n' == original)
  assert(vim.bo[source].modified and not uv.fs_stat(root .. '/unsaved.go'), 'source must remain unsaved')
  assert(not uv.fs_stat(root .. '/go.mod'), 'line explanations must not create or require go.mod')
  hc.cancel()
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: real no-go.mod unsaved single-line masking, full hash, fixed prompt, a/E/command routing, robot/K UI, relative ranges, async cursor capture, stale edit/cancel rejection; local adapters only, no AI/network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
