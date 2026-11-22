local snacks_path = vim.env.HODOCODE_SNACKS
if not snacks_path or snacks_path == '' then
  vim.cmd('qa!')
  return
end

local project
local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.opt.runtimepath:prepend(snacks_path)
  vim.o.lines, vim.o.columns, vim.o.hidden = 45, 140, true
  require('snacks').setup({ picker = { enabled = true } })
  vim.cmd('runtime plugin/hodocode.lua')
  assert(vim.fn.executable(vim.fn.getcwd() .. '/bin/hodocode') == 1, 'build bin/hodocode before this test')
  local hc = require('hodocode')
  local mode = require('hodocode.mode')
  local clients = require('hodocode.client')
  local notices, events = {}, {}
  vim.notify = function(message) notices[#notices + 1] = tostring(message) end
  local function diagnostic()
    local pickers = {}
    for _, p in ipairs(Snacks.picker.get()) do
      pickers[#pickers + 1] = string.format('%s shown=%s count=%d current=%s', p.title, tostring(p.shown), p:count(),
        tostring(p:current() and p:current().node and p:current().node.id))
    end
    return '\nnotices: ' .. table.concat(notices, '\n') .. '\nPickers: ' .. table.concat(pickers, '\n')
      .. '\nBufEnter: ' .. table.concat(events, '\n')
  end
  local function check(ok, message) assert(ok, message .. diagnostic()) end
  local function wait(predicate, message)
    check(vim.wait(15000, predicate, 5), 'timeout: ' .. message)
  end
  project = vim.fn.tempname()
  vim.fn.mkdir(project, 'p')
  project = (vim.uv or vim.loop).fs_realpath(project)
  local original = {
    'package main', '', 'func leaf() {}', 'func branch() { leaf() }',
    'func other() { leaf() }', 'func main() { branch(); other() }',
  }
  vim.fn.writefile({ 'module example.test/snacks', '', 'go 1.23' }, project .. '/go.mod')
  vim.fn.writefile(original, project .. '/main.go')
  vim.cmd.edit(project .. '/main.go')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local h_before = vim.fn.maparg('h', 'n', false, true)
  hc.setup({ root = project, language = 'go', timeout_ms = 15000, tree = 'auto' })
  vim.api.nvim_create_autocmd('BufEnter', { callback = function(event)
    events[#events + 1] = string.format('buf=%d relative=%s mode=%s', event.buf,
      vim.api.nvim_win_get_config(0).relative, tostring(mode.active()))
  end })
  local function invoke(key)
    local map = vim.fn.maparg(key, 'n', false, true)
    check(type(map.callback) == 'function', 'expected real mapped callback: ' .. key)
    map.callback()
  end
  local function picker()
    for _, p in ipairs(Snacks.picker.get()) do
      if p.title:find('HodoCode', 1, true) then return p end
    end
  end
  local function open_tree()
    invoke('t')
    local p
    wait(function()
      p = picker()
      return p and p.shown and p:count() >= 3 and p:current() ~= nil
        and vim.api.nvim_win_get_config(0).relative ~= ''
    end, 'real hc.calls Snacks picker')
    check(mode.active(), 'Snacks focus unexpectedly ended source mode')
    return p
  end
  local function select_node(p, suffix)
    local expected
    for index, item in ipairs(p:items()) do
      if item.node.id == 'example.test/snacks.' .. suffix then expected = index; break end
    end
    check(expected ~= nil, 'missing tree node: ' .. suffix)
    p:action('list_top')
    for _ = 2, expected do p:action('list_down') end
    check(p:current().node.id == 'example.test/snacks.' .. suffix, 'wrong selected node: ' .. suffix)
    return p:current().node
  end
  local function source_return()
    wait(function() return vim.api.nvim_get_current_win() == source_win and vim.api.nvim_get_current_buf() == source end,
      'picker close restores original source window')
    check(mode.active(), 'returning from Snacks unexpectedly ended source mode')
  end

  vim.api.nvim_win_set_cursor(source_win, { 6, 12 })
  hc.mode()
  check(mode.active(), 'hc.mode did not activate')
  local marker_ns = vim.api.nvim_create_namespace('HodoCodeFunction')
  local function markers() return vim.api.nvim_buf_get_extmarks(source, marker_ns, 0, -1, { details = true }) end
  local function strong_markers()
    return vim.tbl_filter(function(mark) return mark[4].hl_group == 'HodoCodeFunction' end, markers())
  end
  wait(function() return #markers() == 8 and #strong_markers() == 4 end, 'all general and proven name markers before picker')
  for _, mark in ipairs(markers()) do
    check(mark[2] == mark[4].end_row and not mark[4].hl_eol, 'marker covers a function range instead of a call name')
  end
  check(vim.deep_equal(vim.fn.maparg('h', 'n', false, true), h_before), 'mode remapped source h')
  vim.cmd('normal h')
  check(vim.api.nvim_win_get_cursor(source_win)[2] == 11, 'normal source h movement changed')
  local p = open_tree()
  local tree_win = vim.api.nvim_get_current_win()
  local function popup_size_matches()
    local width, height = require('hodocode.ui').popup_size()
    return vim.api.nvim_win_get_width(tree_win) == width and vim.api.nvim_win_get_height(tree_win) == height
  end
  check(p.list.win.win == tree_win, 'focused Snacks window is not the list')
  check(popup_size_matches(), 'Snacks list dimensions differ from ui.popup_size()')
  for _, screen in ipairs({ { 100, 32 }, { 140, 45 } }) do
    vim.o.columns, vim.o.lines = screen[1], screen[2]
    vim.api.nvim_exec_autocmds('VimResized', {})
    wait(popup_size_matches, 'Snacks list follows unified popup size after resize')
  end
  check(#markers() == 8 and #strong_markers() == 4, 'opening Snacks removed source name markers')
  local root = p:items()[1].node
  check(root.id == 'example.test/snacks.main' and p:current().node == root, 'current function root not selected')
  local branch = select_node(p, 'branch')
  p:action('tree_toggle')
  wait(function() return branch.loaded and p:count() == 4 end, 'real lazy branch expansion')
  local other = select_node(p, 'other')
  p:action('tree_toggle')
  wait(function() return other.loaded and p:count() == 5 end, 'real lazy sibling expansion')
  p:action('tree_toggle')
  wait(function() return not other.open and p:count() == 4 end, 'sibling collapse')
  select_node(p, 'branch')
  invoke('t')
  source_return()

  p = open_tree()
  wait(function() return p:current().node == branch end, 'saved selection on reopen')
  check(p:items()[1].node == root and branch.open and not other.open and p:count() == 4,
    'expanded/collapsed branches changed across real hc.calls reopen')
  -- Exercise the actual list Enter mapping, not the tree controller directly.
  invoke('<CR>')
  source_return()
  check(vim.api.nvim_win_get_cursor(source_win)[1] == 4, 'picker Enter did not jump to branch definition')
  check(vim.api.nvim_buf_get_changedtick(source) == tick,
    string.format('same-file Enter reloaded unchanged source (changedtick %d -> %d), invalidating tree snapshot',
      tick, vim.api.nvim_buf_get_changedtick(source)))
  p = open_tree()
  wait(function() return p:current().node == branch end, 'reading path selected after same-file jump')
  check(p:items()[1].node == root and not other.open, 'same-file jump lost retained tree root/branches')
  p:action('close')
  source_return()
  vim.api.nvim_win_set_cursor(source_win, { 4, 12 })
  vim.cmd('normal h')
  check(vim.api.nvim_win_get_cursor(source_win)[2] == 11, 'source h movement changed after picker return')

  -- The real server handles these asynchronously; move before any event-loop wait.
  local client = clients.start(project, hc.config)
  local function barrier()
    local done, failure
    client:request('functions', {}, function(_, err) done, failure = true, err end)
    wait(function() return done end, 'real backend focus-check barrier')
    check(not failure, 'backend barrier failed: ' .. tostring(failure))
    vim.wait(50, function() return false end, 5)
  end
  local function window_snapshot()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do wins[win] = true end
    return wins
  end
  local function no_new_windows(before)
    for _, win in ipairs(vim.api.nvim_list_wins()) do if not before[win] then return false end end
    return true
  end
  for _, key in ipairs({ 't', 'm' }) do
    local before = window_snapshot()
    vim.api.nvim_win_set_cursor(source_win, { 6, 12 })
    invoke(key)
    vim.api.nvim_win_set_cursor(source_win, { 6, 13 })
    barrier()
    check(not picker() and no_new_windows(before), 'stale cursor opened ' .. key .. ' UI')
    check(mode.active(), 'stale cursor request ended source mode')
  end
  vim.cmd('vsplit')
  local second_win = vim.api.nvim_get_current_win()
  check(second_win ~= source_win and vim.api.nvim_get_current_buf() == source, 'same-source split missing')
  for _, key in ipairs({ 't', 'm' }) do
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_win_set_cursor(source_win, { 6, 12 })
    vim.api.nvim_win_set_cursor(second_win, { 6, 12 })
    local before = window_snapshot()
    invoke(key)
    vim.api.nvim_set_current_win(second_win)
    barrier()
    check(vim.api.nvim_get_current_win() == second_win and not picker() and no_new_windows(before),
      'stale window focus opened ' .. key .. ' UI or stole focus')
    check(mode.active(), 'same-source nonfloating BufEnter unexpectedly ended mode')
  end
  vim.api.nvim_win_close(second_win, true)
  vim.api.nvim_set_current_win(source_win)
  check(mode.active(), 'mode did not survive integration lifecycle')
  check(vim.api.nvim_buf_get_changedtick(source) == tick and not vim.bo[source].modified
    and vim.deep_equal(vim.fn.readfile(project .. '/main.go'), original), 'integration modified source')
  hc.exit_mode()
  check(#markers() == 0, 'mode exit left source name markers')
  clients.stop_all()
  print('PASS: real backend + Snacks mode/calls, lazy tree/reopen, Enter jump, source movement, stale cursor/window focus')
end
local ok, err = xpcall(run, debug.traceback)
if package.loaded['hodocode.mode'] then pcall(require('hodocode.mode').stop) end
if package.loaded['hodocode.client'] then pcall(require('hodocode.client').stop_all) end
if project then vim.fn.delete(project, 'rf') end
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
