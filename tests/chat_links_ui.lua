local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.lines, vim.o.columns = false, 35, 120
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/nested', 'p')
  root = (vim.uv or vim.loop).fs_realpath(root)
  vim.fn.writefile({ 'one', 'two', 'three', 'four' }, root .. '/a.lua')
  vim.fn.writefile({ 'target', 'two', 'three' }, root .. '/nested/b.lua')
  vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.lua'))
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { 'unsaved source' })
  local sessions = require('hodocode.session')
  local session = sessions.get()
  session.request = { source = source, stream = 'ongoing' }
  local activations, questions, starts, scans, notices = 0, 0, 0, 0, {}
  sessions.activate = function() activations = activations + 1; return session end
  local mode_active, mode_leaves = true, 0
  package.loaded['hodocode.mode'] = { active = function() return mode_active end,
    start = function()
      assert(vim.api.nvim_get_current_win() == source_win)
      mode_active, starts = true, starts + 1
    end }
  package.loaded['hodocode.agent'] = { status = function() return 'waiting' end }
  package.loaded['hodocode.edit_prompt'] = { open = function() questions = questions + 1 end }
  vim.notify = function(message) notices[#notices + 1] = message end
  local engine = require('hodocode.chat_links')
  local scan = engine.scan
  engine.scan = function(...) scans = scans + 1; return scan(...) end
  local refs = engine.capture('a.lua:2', root, { [root .. '/a.lua'] = 'unsaved source\ntwo\nthree\nfour\n' })
  sessions.append('user', 'a.lua:2', { root = root })
  sessions.append('assistant', 'legacy a.lua:2')
  local turn = sessions.append('assistant', '日本語 a.lua:2 and `nested/b.lua:3` and a.lua:4', {
    root = root, references = refs,
    changes = { { path = 'a.lua', line = 2 }, { path = 'nested/b.lua', line = 3 } },
  })
  assert(turn == session.history[3] and turn.root == root and turn.references['a.lua:2']
    and turn.changes[2].line == 3 and turn.metadata == nil, 'real session.append schema')
  for i = 1, 45 do sessions.append('assistant', 'tail ' .. i) end
  local chat = require('hodocode.chat')
  local config = { agent_transport = 'acp' } -- Also exercises the two-row missing-agent banner.
  assert(chat.open(config))
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local ns = vim.api.nvim_get_namespaces().HodoCodeChatLinks
  local function marks() return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }) end
  local function mapping(key)
    return vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key, 'n', false, true).callback end)
  end
  local enter, insert = mapping('<CR>'), mapping('i')
  local function find(text)
    for row, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local col = line:find(text, 1, true)
      if col then return row, col - 1 end
    end
    error('missing ' .. text)
  end
  local row, col = find('日本語')
  local links = marks()
  assert(#links == 5, 'user/legacy links decorated or changes missing')
  assert(links[1][2] == row - 1 and links[1][3] == #'日本語 ', 'UTF-8 byte column/banner offset')
  assert(links[1][4].end_col == #'日本語 a.lua:2', 'exclusive byte end')
  assert(select(1, find('変更箇所: `a.lua:2`')))
  local before_scans = scans
  session.request.stream = 'stream update'
  chat.render(); chat.render()
  assert(scans == before_scans, 'stream/status rescanned history')
  assert(vim.deep_equal(links, marks()), 'stream/status redecorated links')
  session.history[3].references = {}
  chat.render()
  assert(scans == before_scans + 1, 'metadata pointer invalidation')
  vim.api.nvim_win_set_cursor(win, { row, #'日本語 ' })
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zt') end)
  local saved = vim.fn.winsaveview()
  insert(); assert(questions == 1, 'i on link must ask')
  -- Dirty target is reused, and dirty source survives with nohidden.
  local target = vim.fn.bufadd(root .. '/nested/b.lua'); vim.fn.bufload(target)
  vim.api.nvim_buf_set_lines(target, 0, 1, false, { 'unsaved target' })
  vim.api.nvim_win_set_cursor(win, { row, #'日本語 a.lua:2 and `' })
  saved = vim.fn.winsaveview()
  vim.api.nvim_create_autocmd('BufLeave', { buffer = source, once = true, callback = function()
    mode_active, mode_leaves = false, mode_leaves + 1
  end })
  enter()
  assert(not chat.visible() and vim.api.nvim_get_current_buf() == target, vim.inspect(notices))
  assert(mode_leaves == 1 and mode_active and starts == 1, 'BufLeave lost reading mode restart')
  assert(vim.api.nvim_win_get_cursor(source_win)[1] == 3)
  assert(vim.bo[source].modified and vim.bo[target].modified)
  assert(vim.fn.readfile(root .. '/a.lua')[1] == 'one' and vim.fn.readfile(root .. '/nested/b.lua')[1] == 'target')
  assert(session.request.stream == 'stream update', 'jump canceled request')
  sessions.append('assistant', 'hidden addition')
  chat.render()
  local count = activations
  assert(chat.open(config))
  win = vim.api.nvim_get_current_win()
  assert(activations == count, 'return activated nested project')
  assert(chat.source().buf == target, 'source not updated on return')
  local returned = vim.fn.winsaveview()
  assert(returned.lnum == saved.lnum and returned.col == saved.col and returned.topline == saved.topline,
    'return did not restore reader view')
  chat.open(config)
  assert(vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf), 'return mark not one-shot')
  -- Errors keep the popup, cursor and scroll, and do not open a prompt.
  session.history[3].content = 'missing.lua:1 a.lua:900 a.lua:0 a.lua:2'
  chat.render()
  row, col = find('missing.lua:1')
  local function fails(column)
    vim.api.nvim_win_set_cursor(win, { row, column })
    local previous = vim.fn.winsaveview()
    local asked = questions
    enter()
    assert(chat.visible() and vim.api.nvim_get_current_win() == win and questions == asked)
    assert(vim.deep_equal(previous, vim.fn.winsaveview()), 'failure moved chat')
  end
  fails(col); fails(#'missing.lua:1 '); fails(#'missing.lua:1 a.lua:900 ')
  session.history[3].references = { ['a.lua:2'] = { root = root, path = root .. '/a.lua',
    version = 'stale', context = { 'gone' }, offset = 0 } }
  chat.render(); fails(#'missing.lua:1 a.lua:900 a.lua:0 ')
  assert(#notices == 4, 'errors not notified')
  vim.api.nvim_win_set_cursor(win, { row, 0 }); insert()
  vim.api.nvim_win_set_cursor(win, { 1, 0 }); enter()
  assert(questions == 3, 'off-link Enter must ask')
  -- Last-view wipe buffers must not be abandoned even by :hide.
  vim.bo[target].bufhidden = 'wipe'
  session.history[3].references = {}
  chat.render()
  fails(#'missing.lua:1 a.lua:900 a.lua:0 ')
  assert(vim.api.nvim_buf_is_valid(target) and vim.bo[target].modified)
  vim.bo[target].bufhidden = ''
  -- Invalid source window falls back to an existing normal window without layout changes.
  vim.cmd('wincmd p')
  vim.cmd('split')
  local replacement = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(source_win, false)
  source_win = replacement
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_win_set_cursor(win, { row, #'missing.lua:1 a.lua:900 a.lua:0 ' })
  enter(); assert(not chat.visible() and vim.api.nvim_get_current_win() == replacement)
  -- Visiting another project discards the mark; ordinary open always selects latest.
  local other = vim.fn.tempname(); vim.fn.mkdir(other, 'p'); vim.fn.writefile({ 'other' }, other .. '/c.lua')
  vim.cmd('hide edit ' .. vim.fn.fnameescape(other .. '/c.lua'))
  assert(chat.open(config))
  win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf))
  chat.hide()
  assert(chat.open(config, { buf = source, win = replacement }))
  assert(vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1] == vim.api.nvim_buf_line_count(buf))
  chat.shutdown()
  vim.fn.delete(root, 'rf'); vim.fn.delete(other, 'rf')
  print('PASS: real session.append → assistant links, byte ranges, cache, dirty jumps, failure safety, reading mode, one-shot return, projects')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
