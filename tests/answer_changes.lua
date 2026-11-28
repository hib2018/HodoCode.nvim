local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  vim.notify = function() end
  package.loaded['hodocode.chat'] = { open = function() end }
  local callbacks, payload
  package.loaded['hodocode.acp'] = {
    prompt = function(_, request, handlers)
      payload, callbacks = request, handlers
      return { cancel = function() end }
    end,
    shutdown = function() end,
  }
  local agent, session = require('hodocode.agent'), require('hodocode.session')
  local marks, links = require('hodocode.edit_marks'), require('hodocode.chat_links')
  local uv = vim.uv or vim.loop
  local temp = vim.fn.tempname()
  vim.fn.mkdir(temp .. '/project/nested', 'p')
  vim.fn.mkdir(temp .. '/elsewhere', 'p')
  local root = session.realpath(temp .. '/project')
  local cwd = vim.fn.getcwd()
  local config = { root = root, agent_transport = 'acp', agent = { 'mock' },
    max_agent_bytes = 1024 * 1024, agent_timeout_ms = 3000 }
  local serial = 0
  local function file(content)
    serial = serial + 1
    local path = root .. '/nested/source ' .. serial .. '.txt'
    local fd = assert(uv.fs_open(path, 'w', 384))
    assert(uv.fs_write(fd, content, 0)); uv.fs_close(fd)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    return buf, path
  end
  local function text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
      .. (vim.bo[buf].endofline and '\n' or '')
  end
  local capture, captured = links.capture
  links.capture = function(message, project, sources)
    captured = { message = message, root = project, sources = sources }
    return capture(message, project, sources)
  end
  local function last()
    local history = session.get().history
    return history[#history]
  end
  local function start(buf, intent)
    config.root = root
    assert(agent.run(config, 'request', intent or 'edit', { buf = buf }))
    assert(payload.root == root)
    assert(payload.buffer.relative_path == vim.api.nvim_buf_get_name(buf):sub(#root + 2))
    return session.get().request
  end
  local ns = vim.api.nvim_create_namespace('HodoCodeAgentChanges')
  local cases = {
    { 'a\nb\nc\nd\ne\n', 'a\nB\nC\nd\nE\n', { 2, 5 } },
    { 'a\nb\nc\n', 'a\nc\n', { 2 } },
    { 'a\nb\n', 'b\n', { 1 } },
    { 'a\nb\n', 'a\n', { 1 } },
    { 'a\n', '', { 1 } },
    { 'a\n', 'a', { 1 } },
  }
  local original_diff, diff_calls = vim.diff, 0
  vim.diff = function(...)
    diff_calls = diff_calls + 1
    return original_diff(...)
  end
  for _, case in ipairs(cases) do
    local before, after, expected = unpack(case)
    local buf, path = file(before)
    local saved = table.concat(vim.fn.readfile(path, 'b'), '\n')
    start(buf)
    local request = session.get().request
    local relative = payload.buffer.relative_path
    config.root = temp .. '/elsewhere'
    vim.cmd.cd(vim.fn.fnameescape(temp .. '/elsewhere'))
    -- A later session-root mutation must not change this request's reference root.
    local selected = session.get()
    selected.root = config.root
    local count = diff_calls
    callbacks.on_done({ message = 'Applied `' .. relative .. ':1`', content = after })
    selected.root = root
    assert(diff_calls == count + 1, 'application must calculate diff only once')
    local turn = last()
    assert(turn.status == 'applied' and turn.root == root and turn.path == path)
    assert(request.root == root and request.path == path and request.reference_source == after)
    assert(#turn.changes == #expected, vim.inspect(turn.changes))
    local decorations = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
    for i, line in ipairs(expected) do
      local change = turn.changes[i]
      assert(change.path == relative and change.line == line, vim.inspect(turn.changes))
      local reference = assert(turn.references[relative .. ':' .. line])
      assert(reference.version == vim.fn.sha256(after), vim.inspect(reference))
      assert(reference.path == path and reference.root == root and #reference.context <= 5)
      local marked = false
      for _, decoration in ipairs(decorations) do if decoration[2] + 1 == line then marked = true end end
      assert(marked, 'change link must match a decoration')
    end
    assert(turn.references[relative .. ':1'].version == vim.fn.sha256(after))
    assert(captured.sources[path] == after and vim.tbl_count(captured.sources) == 1)
    assert(turn.reference_source == nil and turn.sources == nil, 'full snapshots must not enter history')
    assert(text(buf) == after and table.concat(vim.fn.readfile(path, 'b'), '\n') == saved)
  end
  vim.diff = original_diff
  vim.cmd.cd(vim.fn.fnameescape(cwd))

  -- Non-applied outcomes carry references, but never generated changes or marks.
  for _, kind in ipairs({ 'chat', 'same', 'error', 'invalid', 'cancel' }) do
    local buf, path = file('original\n')
    local request = start(buf, kind == 'chat' and 'chat' or 'edit')
    local relative = payload.buffer.relative_path
    local message = 'See `' .. relative .. ':1`'
    if kind == 'cancel' then
      agent.stop()
      callbacks.on_context({ { path = path, content = 'late context\n' } })
      callbacks.on_done({ message = message, content = 'late\n' })
    elseif kind == 'error' then callbacks.on_done(nil, 'transport')
    elseif kind == 'invalid' then callbacks.on_done({ message = message, version = 'wrong', content = 'bad\n' })
    else callbacks.on_done({ message = message, content = kind == 'same' and 'original\n' or nil }) end
    local turn = last()
    assert(request.reference_sources == nil, 'all outcomes must release context snapshots')
    assert(turn.root == root and turn.path == path and turn.changes == nil)
    assert(type(turn.references) == 'table' and text(buf) == 'original\n')
    assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)
    if kind == 'same' or kind == 'chat' then
      assert(turn.references[relative .. ':1'].version == vim.fn.sha256('original\n'))
    end
  end

  -- Other references intentionally have unknown versions, even when loaded/dirty.
  local other, other_path = file('other disk\n')
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'other private unsaved' })
  local primary = file('primary\n')
  start(primary, 'chat')
  local other_relative = other_path:sub(#root + 2)
  callbacks.on_done({ message = 'See `' .. other_relative .. ':1`' })
  local unknown = assert(last().references[other_relative .. ':1'])
  assert(unknown.version == nil and unknown.context == nil and unknown.path == other_path)
  assert(vim.tbl_count(captured.sources) == 1 and captured.sources[other_path] == nil)

  -- Only ACP's actual transmitted context makes a helper version known.
  local helper, helper_path = file('disk helper\n')
  local helper_lines = { 'one', 'two', 'three', 'target', 'five', 'six', 'seven' }
  vim.api.nvim_buf_set_lines(helper, 0, -1, false, helper_lines)
  local helper_content = text(helper)
  primary = file('primary before\n')
  local request = start(primary)
  local primary_relative = payload.buffer.relative_path
  local helper_relative = helper_path:sub(#root + 2)
  callbacks.on_context({ { path = helper_path, content = helper_content } })
  assert(request.reference_sources[helper_path] == helper_content)
  callbacks.on_done({ message = 'See `' .. helper_relative .. ':4` and `' .. primary_relative .. ':1`',
    content = 'primary applied\n' })
  local turn = last()
  local reference = assert(turn.references[helper_relative .. ':4'])
  assert(reference.version == vim.fn.sha256(helper_content) and #reference.context == 5)
  assert(turn.references[primary_relative .. ':1'].version == vim.fn.sha256('primary applied\n'))
  assert(request.reference_sources == nil, 'completed request must release context snapshots')
  assert(turn.reference_sources == nil and vim.tbl_count(captured.sources) == 2)
  callbacks.on_context({ { path = helper_path, content = 'late ignored\n' } })
  assert(request.reference_sources == nil, 'late context must not recreate snapshots')
  local link = links.scan({ '`' .. helper_relative .. ':4`' }, turn.root, turn.references)[1]
  local resolved = assert(links.resolve(link))
  assert(resolved.buf == helper and resolved.row == 4)
  vim.api.nvim_buf_set_lines(helper, 0, 0, false, { 'inserted after reply' })
  resolved = assert(links.resolve(link))
  assert(resolved.buf == helper and resolved.row == 5, 'known helper anchor must relocate uniquely')
  vim.api.nvim_buf_set_lines(helper, 4, 5, false, { 'target changed after reply' })
  assert(links.resolve(link) == nil, 'changed known helper anchor must reject stale navigation')
  assert(table.concat(vim.fn.readfile(helper_path, 'b'), '\n') == 'disk helper\n')

  -- Legacy callers may replace edit_marks.set without returning positions.
  local set = marks.set
  marks.set = function() end
  local buf = file('before\n')
  start(buf)
  callbacks.on_done({ message = 'done', content = 'after\n' })
  assert(last().status == 'applied' and last().changes == nil)
  marks.set = set

  -- Bound only decorations, not the generated links for later hunks.
  local before, after = {}, {}
  for i = 1, 2205 do
    before[i] = 'line ' .. i
    after[i] = i % 2 == 0 and ('changed ' .. i) or before[i]
  end
  buf = file(table.concat(before, '\n') .. '\n')
  start(buf)
  callbacks.on_done({ message = 'done', content = table.concat(after, '\n') .. '\n' })
  assert(#last().changes == 1102 and last().changes[1102].line == 2204)
  assert(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 1000)

  -- Real legacy JSON adapter: optional relative path, send-time root, dirty undo.
  config.agent_transport = nil
  local script = temp .. '/adapter.py'
  vim.fn.writefile({
    'import json, sys, time',
    'request = json.load(sys.stdin)',
    'assert request["buffer"]["relative_path"] == sys.argv[1]',
    'assert request["buffer"]["content"] == "disk\\nmanual\\n"',
    'time.sleep(.05)',
    'json.dump({"message": "See `" + sys.argv[1] + ":3`", "content": "disk\\nmanual\\nAI\\n"}, sys.stdout)',
  }, script)
  local path
  buf, path = file('disk\n')
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'manual' })
  local relative = path:sub(#root + 2)
  config.root, config.agent = root, { 'python3', script, relative }
  assert(agent.run(config, 'request', 'edit', { buf = buf }))
  local request = session.get().request
  config.root = temp .. '/elsewhere'
  vim.cmd.cd(vim.fn.fnameescape(config.root))
  assert(vim.wait(5000, function() return session.get().request == nil end, 5), 'legacy completion timeout')
  local turn = last()
  assert(turn.status == 'applied' and turn.root == root and turn.path == path, vim.inspect(turn))
  assert(request.root == root and turn.changes[1].path == relative and turn.changes[1].line == 3)
  assert(turn.references[relative .. ':3'].version == vim.fn.sha256('disk\nmanual\nAI\n'))
  assert(table.concat(vim.fn.readfile(path, 'b'), '\n') == 'disk\n', 'metadata must not save source')
  vim.api.nvim_buf_call(buf, function() vim.cmd.undo() end)
  assert(text(buf) == 'disk\nmanual\n', 'undo must preserve preexisting manual changes')
  links.capture = capture
  agent.shutdown()
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  vim.fn.delete(temp, 'rf')
  print('PASS: applied hunk links, single diff, bounded marks, frozen roots, reference snapshots, ACP/legacy, dirty undo')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
