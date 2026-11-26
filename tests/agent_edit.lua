local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  local agent, uv = require('hodocode.agent'), vim.uv or vim.loop
  local chat, session = require('hodocode.chat'), require('hodocode.session')
  local root, notices = vim.fn.tempname(), {}
  vim.fn.mkdir(root, 'p')
  vim.notify = function(message) notices[#notices + 1] = message end
  local function write(path, bytes)
    local fd = assert(uv.fs_open(path, 'w', 384))
    assert(uv.fs_write(fd, bytes, 0)); uv.fs_close(fd)
  end
  local function read(path)
    return table.concat(vim.fn.readfile(path, 'b'), '\n')
  end
  local function wait(test, label)
    assert(vim.wait(5000, test, 5), 'timeout: ' .. label .. '\n' .. table.concat(notices, '\n'))
  end
  local function lines(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local function key(buf, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if map.lhs == lhs then assert(map.callback, 'expected callback for ' .. lhs); map.callback(); return end
    end
    error('missing key: ' .. lhs)
  end
  local serial = 0
  local function file(bytes)
    serial = serial + 1
    local path = root .. '/source' .. serial .. '.txt'
    if bytes ~= nil then write(path, bytes) end
    vim.cmd.edit(path)
    return vim.api.nvim_get_current_buf(), path
  end
  local script = root .. '/mock.py'
  write(script, [[import json, os, signal, sys, time
mode, trace, expected, output = sys.argv[1:]
r = json.load(sys.stdin)
assert r['prompt'] == 'edit' and r['buffer']['content'] == expected
with open(trace + '.tmp', 'w') as f:
    json.dump({'cwd': os.getcwd(), 'mode': os.stat('.').st_mode & 0o777,
               'modified': r['buffer']['modified']}, f)
os.replace(trace + '.tmp', trace)
if mode == 'slow':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(.25)
if mode == 'bad':
    sys.stderr.write('PRIVATE_STDERR_SECRET')
    sys.stdout.write('{not-json')
else:
    response = {'message': 'DONE' if mode != 'nul' else 'bad\x00message'}
    if mode != 'message': response['content'] = output
    json.dump(response, sys.stdout)
]])
  local function config(mode, expected, output)
    serial = serial + 1
    local trace = root .. '/trace' .. serial
    return { agent = { 'python3', script, mode, trace, expected, output or '' },
      max_agent_bytes = 1024 * 1024, agent_timeout_ms = 3000 }, trace
  end
  local function start(buf, mode, expected, output, limit)
    vim.api.nvim_set_current_buf(buf)
    local cfg, trace = config(mode, expected, output)
    if limit then cfg.max_agent_bytes = limit end
    agent.run(cfg, 'edit')
    chat.open(cfg)
    local popup, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    assert(popup ~= buf, 'request output must be a popup')
    wait(function() return uv.fs_stat(trace) ~= nil end, 'adapter stdin')
    local record = vim.json.decode(read(trace))
    assert(record.mode == 448 and record.cwd ~= root, 'request cwd must be private 0700')
    return { buf = popup, win = win, source = buf, cwd = record.cwd, modified = record.modified }
  end
  local function finish(request)
    wait(function()
      return not session.get().request
    end, 'adapter completion')
    wait(function() return not uv.fs_stat(request.cwd) end, 'request cwd cleanup')
  end
  local function close(request)
    chat.hide()
    vim.api.nvim_set_current_buf(request.source)
  end
  local function baseline(buf, expected)
    vim.api.nvim_set_current_buf(buf)
    local before_tabs, before_wins = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_wins()
    local old_q = vim.fn.maparg('q', 'n', false, true)
    local saved = assert(agent.baseline(buf))
    assert(table.concat(saved.lines, '\n') == expected, 'wrong saved baseline: ' .. vim.inspect(saved))
    agent.diff()
    assert(require('hodocode.inline_diff').visible(buf), 'inline diff not enabled')
    assert(#vim.api.nvim_list_tabpages() == before_tabs and #vim.api.nvim_list_wins() == before_wins,
      'inline diff must not open windows or tabs')
    assert(vim.bo[buf].modifiable and vim.deep_equal(old_q, vim.fn.maparg('q', 'n', false, true)),
      'inline diff changed source options or mappings')
    return { source = buf, saved = saved }
  end
  local function close_diff(view)
    vim.api.nvim_set_current_buf(view.source)
    agent.diff()
    assert(not require('hodocode.inline_diff').visible(view.source), 'inline diff did not toggle off')
    assert(#vim.api.nvim_buf_get_extmarks(view.source, vim.api.nvim_create_namespace('HodoCodeInlineDiff'), 0, -1, {}) == 0,
      'inline diff toggle left namespace marks')
  end

  local source, path = file('saved\n')
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { 'dirty' })
  local request = start(source, 'edit', 'saved\ndirty\n', 'saved\ndirty\nAI\n')
  assert(request.modified, 'adapter must receive dirty full-buffer context')
  finish(request); close(request)
  assert(vim.bo[source].modified and read(path) == 'saved\n', 'AI must not autosave')
  vim.api.nvim_buf_call(source, function() vim.cmd.undo() end)
  assert(lines(source) == 'saved\ndirty' and vim.bo[source].modified, 'one undo must preserve pre-AI dirty edits')
  vim.api.nvim_buf_call(source, function() vim.cmd.redo() end)
  local view = baseline(source, 'saved')
  assert(#vim.api.nvim_buf_get_extmarks(source, vim.api.nvim_create_namespace('HodoCodeInlineDiff'), 0, -1, {}) > 0,
    'inline diff must decorate changed source lines')
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { 'live' })
  assert(lines(source):find('live', 1, true))
  vim.cmd.write()
  assert(table.concat(agent.baseline(source).lines, '\n') == 'saved', 'writing must not mutate request-time baseline')
  close_diff(view)
  for _, mode in ipairs({ 'message', 'edit' }) do
    request = start(source, mode, 'saved\ndirty\nAI\nlive\n', 'saved\ndirty\nAI\nlive\n')
    finish(request); close(request)
    close_diff(baseline(source, 'saved'))
  end
  request = start(source, 'bad', 'saved\ndirty\nAI\nlive\n')
  finish(request); close(request)
  close_diff(baseline(source, 'saved'))
  request = start(source, 'edit', 'saved\ndirty\nAI\nlive\n', 'second\n')
  finish(request); close(request)
  view = baseline(source, 'saved\ndirty\nAI\nlive')
  close_diff(view)
  local function source_watchers()
    return #vim.api.nvim_get_autocmds({ buffer = source })
  end
  local watchers = source_watchers()
  for _ = 1, 3 do close_diff(baseline(source, 'saved\ndirty\nAI\nlive')) end
  assert(source_watchers() == watchers, 'inline diff toggles leaked source autocmds')

  -- A renamed buffer must not inherit another path's AI baseline.
  local renamed = file('old disk\n')
  request = start(renamed, 'edit', 'old disk\n', 'old AI\n')
  finish(request); close(request)
  write(root .. '/renamed.txt', 'other disk\n')
  vim.api.nvim_buf_set_name(renamed, root .. '/renamed.txt')
  close_diff(baseline(renamed, 'other disk', true))

  -- Standalone diff, missing files, and byte-level metadata do not require AI.
  local plain = file('disk without EOF')
  vim.api.nvim_buf_set_lines(plain, 0, -1, false, { 'unsaved' })
  view = baseline(plain, 'disk without EOF', true)
  assert(not view.saved.endofline, 'baseline lost missing EOF newline')
  close_diff(view)
  local new = file(nil)
  vim.api.nvim_buf_set_lines(new, 0, -1, false, { 'new unsaved' })
  close_diff(baseline(new, '', true))
  request = start(new, 'edit', 'new unsaved\n', 'new AI\n')
  finish(request); close(request)
  close_diff(baseline(new, ''))
  local dos = file('\239\187\191saved\r\nlast')
  request = start(dos, 'edit', 'saved\nlast', '\239\187\191changed\r\nlast\r\n')
  finish(request); close(request)
  assert(lines(dos) == 'changed\nlast' and vim.bo[dos].endofline, 'BOM/CRLF must not become visible buffer characters')
  vim.api.nvim_buf_call(dos, function() vim.cmd.undo() end)
  assert(lines(dos) == 'saved\nlast', 'undo must restore original lines immediately')
  wait(function() return not vim.bo[dos].endofline end, 'undo restores missing EOF newline')
  vim.api.nvim_buf_call(dos, function() vim.cmd.redo() end)
  assert(lines(dos) == 'changed\nlast', 'redo must restore AI lines immediately')
  wait(function() return vim.bo[dos].endofline end, 'redo restores AI EOF newline')
  view = baseline(dos, 'saved\nlast')
  assert(view.saved.bomb and view.saved.fileformat == 'dos' and not view.saved.endofline)
  close_diff(view)

  local manual = file('manual saved\n')
  request = start(manual, 'edit', 'manual saved\n', 'AI without EOF')
  finish(request); close(request)
  assert(lines(manual) == 'AI without EOF' and not vim.bo[manual].endofline)
  vim.api.nvim_buf_call(manual, function() vim.cmd('setlocal eol') end)
  for _, value in ipairs({ 'manual edit', 'AI without EOF' }) do
    vim.api.nvim_buf_set_lines(manual, 0, -1, false, { value })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = manual })
    local drained = false
    vim.schedule(function() drained = true end)
    wait(function() return drained end, 'manual EOF scheduled callbacks')
    assert(lines(manual) == value and vim.bo[manual].endofline, 'scheduled restoration clobbered manual setlocal eol')
  end

  -- Each concurrent mutation must refuse application, retaining the source.
  for _, kind in ipairs({ 'buffer', 'disk', 'name', 'options' }) do
    local buf, filename = file('safe\n')
    request = start(buf, 'slow', 'safe\n', 'UNSAFE\n')
    if kind == 'buffer' then vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'user' })
    elseif kind == 'disk' then write(filename, 'external\n')
    elseif kind == 'name' then vim.api.nvim_buf_set_name(buf, filename .. '.renamed')
    elseif kind == 'options' then vim.bo[buf].endofline = false
    else vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1]); vim.cmd.enew() end
    finish(request)
    assert(not lines(buf):find('UNSAFE', 1, true), 'hidden/conflicting apply: ' .. kind)
    close(request)
  end
  -- Source changes while composing are captured only when the user sends.
  local prompt = require('hodocode.edit_prompt')
  local open = prompt.open
  local buf = file('prompt\n')
  local callback
  prompt.open = function(submit) callback = submit; return nil, nil, function() end end
  local cfg = config('edit', 'prompt\nlatest\n', 'captured latest\n')
  agent.run(cfg)
  assert(callback, 'prompt not requested')
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'latest' })
  callback('edit')
  wait(function() return agent.status(buf) and not agent.status(buf).running end, 'latest prompt snapshot')
  assert(lines(buf) == 'captured latest', 'prompt send did not capture latest source')
  prompt.open = open
  chat.hide()
  for _, action in ipairs({ 'hide', 'focus', 'window', 'stop' }) do
    buf = file('cancel\n')
    request = start(buf, 'slow', 'cancel\n', 'LATE\n')
    local history_count = #session.get().history
    if action == 'hide' then close(request)
    elseif action == 'focus' then vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    elseif action == 'window' then
      local source_win = vim.fn.win_findbuf(buf)[1]
      vim.api.nvim_win_set_buf(source_win, vim.api.nvim_create_buf(true, false))
    else agent.stop() end
    finish(request)
    assert(lines(buf) == (action == 'stop' and 'cancel' or 'LATE'), 'UI lifecycle cancelled request: ' .. action)
    assert(#session.get().history >= history_count, 'history discarded: ' .. action)
    close(request)
  end
  local malformed = file('safe\n')
  request = start(malformed, 'bad', 'safe\n')
  finish(request)
  assert(lines(request.buf):find('不正', 1, true) and lines(malformed) == 'safe')
  assert(not (lines(request.buf) .. table.concat(notices, '\n')):find('PRIVATE_STDERR_SECRET', 1, true), 'raw stderr leaked')
  close(request)
  request = start(malformed, 'edit', 'safe\n', string.rep('x', 65536), 32768)
  finish(request)
  assert(lines(malformed) == 'safe' and lines(request.buf):find('サイズ', 1, true), 'oversized response applied')
  close(request)
  for _, invalid in ipairs({ { 'nul', 'UNSAFE\n' }, { 'edit', 'one\r\ntwo\n' } }) do
    request = start(malformed, invalid[1], 'safe\n', invalid[2])
    finish(request)
    assert(lines(malformed) == 'safe' and lines(request.buf):find('不正', 1, true), 'unsafe response applied')
    close(request)
  end
  vim.bo[malformed].fileencoding = 'latin1'
  local cfg, trace = config('edit', 'safe\n', 'UNSAFE\n')
  agent.run(cfg, 'edit')
  assert(not uv.fs_stat(trace) and lines(malformed) == 'safe', 'unsupported encoding must reject before launch')
  agent.stop(); vim.fn.delete(root, 'rf')
  print('PASS: saved/request snapshots, inline diff, undo, metadata, conflicts, send-time capture, hide versus cancel, private adapters')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
