local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  vim.o.hidden = true
  local hc = require('hodocode')
  local clients = require('hodocode.client')
  local agent = require('hodocode.agent')
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local function wait(predicate, label)
    assert(vim.wait(10000, predicate, 5), 'timeout: ' .. label .. '\n' .. table.concat(notices, '\n'))
  end
  local function drain()
    local done = false
    vim.schedule(function() done = true end)
    wait(function() return done end, 'scheduled callbacks')
  end
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  root = (vim.uv or vim.loop).fs_realpath(root)
  vim.fn.writefile({ 'module example.test/edges', '', 'go 1.23' }, root .. '/go.mod')
  local original = { 'package main', 'func entry() {}', 'func a() {}', 'func b() {}' }
  vim.fn.writefile(original, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  hc.setup({ root = root, language = 'go', timeout_ms = 10000 })

  -- Exercise the real wire encoder: an empty params table must become {}, not [].
  local real = clients.start(root, hc.config)
  local response, response_error, received
  real:request('functions', {}, function(result, err)
    response, response_error, received = result, err, true
  end)
  wait(function() return received end, 'real backend empty params')
  assert(not response_error, response_error)
  assert(type(response) == 'table' and #response == 3, 'real functions response missing')
  assert(response[1].ID == 'example.test/edges.a', 'real functions order changed')
  clients.stop_all()

  local function definition(id, line)
    return { ID = id, File = 'main.go', Line = line, End = line }
  end
  local entry, a, b = definition('entry', 2), definition('a', 3), definition('b', 4)
  local ac, bc = definition('a.child', 3), definition('b.child', 4)
  local real_start = clients.start
  for _, reverse in ipairs({ false, true }) do
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    hc.setup({ root = root, language = 'go', tree = 'native', timeout_ms = 10000 })
    local pending = {}
    clients.start = function()
      return { request = function(_, method, params, callback)
        if method == 'reload' then callback({ reloaded = true })
        elseif method == 'functions' then callback({ entry })
        else
          assert(method == 'calls' and not pending[params['function']], 'unexpected tree request')
          pending[params['function']] = callback
        end
      end }
    end
    hc.calls()
    local tree, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    assert(tree ~= source and pending.entry, 'tree did not request entry')
    -- Decode actual JSON null, rather than replacing it with an empty Lua array.
    local unknown = vim.json.decode('{"To":"dynamic","Name":"dynamic","Unknown":true,"Reason":"unresolved","Candidates":null}')
    pending.entry({ calls = { { To = 'a' }, { To = 'b' }, unknown }, Targets = { a = a, b = b } })
    local rendered = vim.api.nvim_buf_get_lines(tree, 0, -1, false)
    assert(#rendered == 5 and rendered[5]:find('dynamic', 1, true), 'null Candidates broke rendering')
    assert(rendered[5]:find('未解決', 1, true), 'unknown call lost its unresolved label')
    local toggle
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(tree, 'n')) do
      if mapping.lhs == '<Tab>' then toggle = mapping.callback end
    end
    assert(type(toggle) == 'function', 'tree toggle mapping missing')
    vim.api.nvim_win_set_cursor(win, { 3, 0 }); toggle()
    vim.api.nvim_win_set_cursor(win, { 4, 0 }); toggle()
    assert(pending.a and pending.b, 'sibling requests must both be pending')
    local function answer_a() pending.a({ calls = { { To = ac.ID } }, Targets = { [ac.ID] = ac } }) end
    local function answer_b() pending.b({ calls = { { To = bc.ID } }, Targets = { [bc.ID] = bc } }) end
    if reverse then answer_b(); answer_a() else answer_a(); answer_b() end
    rendered = vim.api.nvim_buf_get_lines(tree, 0, -1, false)
    local ids = {}
    for index = 3, 6 do ids[#ids + 1] = rendered[index]:match('([%w%.]+)$') end
    assert(vim.deep_equal(ids, { 'a', 'a.child', 'b', 'b.child' }),
      'async sibling order corrupted: ' .. table.concat(rendered, '|'))
    assert(rendered[7]:find('dynamic', 1, true), 'parallel node array lost unknown sibling')
    -- Validate node/row alignment too: an inserted child must still navigate.
    local jump, jumped = require('hodocode.ui').jump, nil
    require('hodocode.ui').jump = function(_, target) jumped = target.ID end
    vim.api.nvim_win_set_cursor(win, { 6, 0 })
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(tree, 'n')) do
      if mapping.lhs == 'o' then mapping.callback() end
    end
    require('hodocode.ui').jump = jump
    assert(jumped == 'b.child', 'node array no longer matches displayed child')
  end
  clients.start = real_start

  -- Adapter execution is entirely mocked; callbacks are deliberately controlled.
  local system, input = vim.system, vim.ui.input
  local invocations = {}
  vim.system = function(argv, options, callback)
    assert(argv[1] == 'edge-test-adapter', 'unexpected adapter')
    local invocation = { options = options, callback = callback, killed = false }
    invocations[#invocations + 1] = invocation
    return { kill = function(_, signal) invocation.killed = signal end }
  end
  hc.config.agent = { 'edge-test-adapter' }
  hc.config.max_agent_bytes = 4096
  local function focus_source()
    vim.api.nvim_set_current_buf(source)
  end
  local function source_state()
    return {
      lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
      eol = vim.bo[source].endofline,
      modified = vim.bo[source].modified,
      tick = vim.api.nvim_buf_get_changedtick(source),
    }
  end
  local function unchanged(before, label)
    assert(vim.deep_equal(source_state(), before), label .. ' mutated source or buffer options')
    assert(vim.deep_equal(vim.fn.readfile(root .. '/main.go'), original), label .. ' changed disk source')
  end
  local function finish(invocation, output)
    if output then invocation.options.stdout(nil, output) end
    invocation.callback({ code = 0 })
    drain()
  end
  local function begin(prompt)
    focus_source()
    hc.agent(prompt)
    local invocation = invocations[#invocations]
    assert(invocation and vim.bo.buftype == 'nofile', 'adapter did not start')
    return invocation, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  end
  local function close(win)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    focus_source()
  end

  focus_source()
  local submitted
  vim.ui.input = function(_, callback) submitted = callback end
  hc.agent('')
  assert(type(submitted) == 'function', 'agent prompt callback missing')
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(other, root .. '/other.go')
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'PRIVATE_OTHER_BUFFER' })
  vim.api.nvim_set_current_buf(other)
  submitted('edit the original buffer')
  drain()
  assert(#invocations == 0, 'delayed prompt sent a different buffer to the adapter')
  assert(vim.api.nvim_get_current_buf() == other, 'rejected prompt changed buffers')
  vim.ui.input = input

  focus_source()
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// preserve unsaved user content' })
  local invocation, win, output = begin('concurrent endofline change')
  local tick = vim.api.nvim_buf_get_changedtick(source)
  vim.bo[source].endofline = false
  assert(vim.api.nvim_buf_get_changedtick(source) == tick, 'endofline must exercise the non-changedtick guard')
  local before = source_state()
  finish(invocation, vim.json.encode({ message = 'done', content = 'MUST NOT APPLY\n' }))
  unchanged(before, 'concurrent endofline change')
  assert(table.concat(vim.api.nvim_buf_get_lines(output, 0, -1, false), '\n'):find('競合', 1, true),
    'endofline conflict was not reported')
  close(win)

  for _, case in ipairs({ 'cancelled', 'oversized', 'malformed', 'wrong-shape' }) do
    invocation, win, output = begin(case)
    before = source_state()
    if case == 'cancelled' then
      agent.stop()
      assert(invocation.killed == 15, 'cancel did not terminate adapter')
      finish(invocation, vim.json.encode({ message = 'late success', content = 'MUST NOT APPLY\n' }))
    elseif case == 'oversized' then
      finish(invocation, vim.json.encode({ message = string.rep('x', hc.config.max_agent_bytes + 1), content = 'MUST NOT APPLY\n' }))
      assert(invocation.killed == 15, 'oversized output did not terminate adapter')
      assert(table.concat(vim.api.nvim_buf_get_lines(output, 0, -1, false), '\n'):find('サイズ制限', 1, true),
        'oversized response was not reported')
    else
      finish(invocation, case == 'malformed' and '{not json' or '{"message":"bad content","content":42}')
      assert(table.concat(vim.api.nvim_buf_get_lines(output, 0, -1, false), '\n'):find('不正', 1, true),
        'malformed adapter response was not reported')
    end
    unchanged(before, case .. ' adapter response')
    close(win)
  end
  vim.system = system
  agent.stop()

  -- Keep the real client/timer logic; only replace the process transport.
  local jobstart, chansend, jobstop = vim.fn.jobstart, vim.fn.chansend, vim.fn.jobstop
  local stopped, requests, callbacks = false, {}, {}
  vim.fn.jobstart = function() return 98765 end
  vim.fn.chansend = function(_, message) requests[#requests + 1] = vim.json.decode(message); return #message end
  vim.fn.jobstop = function(job) assert(job == 98765); stopped = true; return 1 end
  local config = vim.deepcopy(hc.config)
  config.timeout_ms = 20
  local timed = clients.start(root, config)
  for i = 1, 2 do
    timed:request('functions', {}, function(result, err)
      callbacks[i] = { result = result, error = err }
    end)
  end
  wait(function() return timed.closed and callbacks[1] and callbacks[2] end, 'protocol timeout')
  assert(stopped and next(timed.pending) == nil, 'timeout did not stop client and clear pending requests')
  assert(#requests == 2, 'timeout transport did not receive both requests')
  for i = 1, 2 do
    assert(callbacks[i].result == nil and callbacks[i].error:find('timed out', 1, true),
      'timeout did not fail every pending callback')
  end
  local rejected
  timed:request('functions', {}, function(_, err) rejected = err end)
  assert(rejected == 'backend stopped' and #requests == 2, 'closed client accepted another request')
  vim.fn.jobstart, vim.fn.chansend, vim.fn.jobstop = jobstart, chansend, jobstop
  clients.stop_all()
  vim.fn.delete(root, 'rf')
  print('PASS: empty params, null Candidates, sibling expansion order, delayed prompt, endofline conflict, cancelled/oversized/malformed adapters, protocol timeout')
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
