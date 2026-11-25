local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  local agent, uv = require('hodocode.agent'), vim.uv or vim.loop
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
    local popup, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    assert(popup ~= buf, 'request output must be a popup')
    wait(function() return uv.fs_stat(trace) ~= nil end, 'adapter stdin')
    local record = vim.json.decode(read(trace))
    assert(record.mode == 448 and record.cwd ~= root, 'request cwd must be private 0700')
    return { buf = popup, win = win, cwd = record.cwd, modified = record.modified }
  end
  local function finish(request)
    wait(function() return not lines(request.buf):find('実行中…', 1, true) end, 'adapter completion')
    assert(not uv.fs_stat(request.cwd), 'request cwd leaked after completion')
  end
  local function close(request)
    vim.api.nvim_set_current_win(request.win); key(request.buf, 'q')
  end
  local function baseline(buf, expected, current_disk)
    vim.api.nvim_set_current_buf(buf)
    local original_tab = vim.api.nvim_get_current_tabpage()
    local old_q = vim.fn.maparg('q', 'n', false, true)
    agent.diff()
    local tab, left, right = vim.api.nvim_get_current_tabpage()
    assert(tab ~= original_tab and #vim.api.nvim_tabpage_list_wins(tab) == 2, 'diff must own a two-pane tab')
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(win) == buf then right = win else left = win end
    end
    assert(left and right and vim.wo[left].diff and vim.wo[right].diff)
    local saved = vim.api.nvim_win_get_buf(left)
    assert(lines(saved) == expected, 'wrong saved baseline: ' .. lines(saved))
    assert(not vim.bo[saved].modifiable and vim.bo[saved].readonly)
    assert(vim.bo[buf].modifiable and vim.api.nvim_get_current_win() == right, 'right pane must be the live source')
    local label = current_disk and '保存済み（diff表示時）' or '保存済み（要求開始時）'
    assert(vim.wo[left].winbar:find(label, 1, true)
      and vim.wo[right].winbar:find('現在のバッファ', 1, true), 'diff labels missing')
    assert(vim.deep_equal(old_q, vim.fn.maparg('q', 'n', false, true)), 'diff must not override source q')
    return { tab = tab, left = left, right = right, saved = saved }
  end
  local function close_diff(view)
    vim.api.nvim_set_current_win(view.left); key(view.saved, 'q')
    wait(function() return not vim.api.nvim_tabpage_is_valid(view.tab) end, 'scratch q closes owned tab')
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
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { 'live' })
  assert(vim.api.nvim_win_get_buf(view.right) == source and lines(source):find('live', 1, true))
  vim.cmd.write()
  assert(lines(view.saved) == 'saved', 'writing must not mutate request-time baseline')
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
  vim.cmd.tabclose()
  wait(function() return not vim.api.nvim_buf_is_valid(view.saved) end, 'right tabclose cleanup')

  local function source_watchers()
    return #vim.api.nvim_get_autocmds({ buffer = source, event = { 'BufFilePost', 'BufWipeout' } })
  end
  local watchers = source_watchers()
  for _ = 1, 3 do close_diff(baseline(source, 'saved\ndirty\nAI\nlive')) end
  assert(source_watchers() == watchers, 'diff open/close leaked source autocmds')
  view = baseline(source, 'saved\ndirty\nAI\nlive')
  assert(#vim.fn.win_findbuf(source) >= 2, 'original source must remain visible outside diff')
  local replacement = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(replacement, root .. '/unrelated.txt')
  vim.api.nvim_buf_set_lines(replacement, 0, -1, false, { 'unrelated unsaved edits' })
  vim.api.nvim_win_set_buf(view.right, replacement)
  vim.api.nvim_set_current_win(view.left); key(view.saved, 'q')
  wait(function() return not vim.api.nvim_buf_is_valid(view.saved) end, 'replaced diff scratch cleanup')
  assert(vim.api.nvim_win_is_valid(view.right) and vim.api.nvim_win_get_buf(view.right) == replacement,
    'scratch q closed or replaced an unrelated right window')
  assert(lines(replacement) == 'unrelated unsaved edits' and vim.bo[replacement].modified,
    'scratch q discarded unrelated dirty buffer')
  assert(source_watchers() == watchers, 'replaced diff view leaked source autocmds')
  vim.api.nvim_set_current_win(view.right); vim.cmd.tabclose()
  vim.api.nvim_set_current_buf(source)

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
  assert(not vim.bo[view.saved].endofline and vim.wo[view.left].winbar:find('EOL=false', 1, true))
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
  assert(vim.bo[view.saved].bomb and vim.bo[view.saved].fileformat == 'dos' and not vim.bo[view.saved].endofline)
  assert(vim.wo[view.left].winbar:find('BOM=true', 1, true) and vim.wo[view.left].winbar:find('dos', 1, true))
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
  for _, kind in ipairs({ 'buffer', 'disk', 'name', 'options', 'window' }) do
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
  -- Capture must precede waiting for an interactive prompt.
  local input = vim.ui.input
  for _, kind in ipairs({ 'buffer', 'disk', 'options', 'window' }) do
    local buf, filename = file('prompt\n')
    local callback
    vim.ui.input = function(_, cb) callback = cb end
    local cfg, trace = config('edit', 'prompt\n', 'UNSAFE\n')
    agent.run(cfg)
    assert(callback, 'prompt not requested')
    if kind == 'buffer' then vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'user' })
    elseif kind == 'disk' then write(filename, 'external\n')
    elseif kind == 'options' then vim.bo[buf].bomb = true
    else vim.cmd.enew() end
    callback('edit')
    assert(not uv.fs_stat(trace) and not lines(buf):find('UNSAFE', 1, true), 'prompt capture race: ' .. kind)
  end
  vim.ui.input = input
  for _, cancel in ipairs({ 'q', 'stop' }) do
    local buf = file('cancel\n')
    request = start(buf, 'slow', 'cancel\n', 'LATE\n')
    if cancel == 'q' then close(request) else agent.stop(); close(request) end
    wait(function() return not uv.fs_stat(request.cwd) end, 'cancel cwd cleanup')
    vim.wait(400, function() return false end, 10)
    assert(lines(buf) == 'cancel', 'cancelled callback applied late')
  end
  local malformed = file('safe\n')
  request = start(malformed, 'bad', 'safe\n')
  finish(request)
  assert(lines(request.buf):find('不正', 1, true) and lines(malformed) == 'safe')
  assert(not (lines(request.buf) .. table.concat(notices, '\n')):find('PRIVATE_STDERR_SECRET', 1, true), 'raw stderr leaked')
  close(request)
  request = start(malformed, 'edit', 'safe\n', string.rep('x', 4096), 512)
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
  print('PASS: saved/request snapshots, live diff, undo, metadata, conflicts, prompt capture, cancel, private adapters')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
