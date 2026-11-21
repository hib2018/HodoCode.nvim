local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  vim.g.mapleader = ','
  local existing_leader = function() end
  vim.keymap.set('n', '<leader>h', existing_leader)
  vim.cmd('runtime plugin/hodocode.lua')
  assert(vim.fn.maparg(',h', 'n', false, true).callback == existing_leader,
    'plugin overwrote an existing leader mapping')
  vim.keymap.del('n', '<leader>h')
  vim.g.loaded_hodocode = nil
  vim.cmd('runtime plugin/hodocode.lua')
  assert(not vim.tbl_isempty(vim.fn.maparg(',h', 'n', false, true)), 'default leader mapping missing')
  assert(vim.fn.exists(':HodoCodeMode') == 2 and vim.fn.exists(':HodoCodeModeExit') == 2,
    'mode commands missing')

  local hc = require('hodocode')
  local mode = require('hodocode.mode')
  local dispatched = {}
  for _, name in ipairs({ 'functions', 'calls', 'syntax', 'reload', 'agent', 'diff' }) do
    local method = name
    hc[method] = function() dispatched[#dispatched + 1] = method end
  end
  require('hodocode.agent').stop = function() dispatched[#dispatched + 1] = 'cancel' end
  require('hodocode.client').start = function() error('mode tests must not start a backend') end

  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module example.test/mode', '', 'go 1.23' }, root .. '/go.mod')
  local original = { 'package main', '', 'func main() {}' }
  vim.fn.writefile(original, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local function mapping(key)
    return vim.fn.maparg(key, 'n', false, true)
  end
  local function invoke(key)
    local map = mapping(key)
    assert(not vim.tbl_isempty(map), 'mapping missing: ' .. key)
    if type(map.callback) == 'function' then
      map.callback()
    else
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'mx', false)
    end
  end
  local function guides()
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'hodocode-mode' then wins[#wins + 1] = win end
    end
    return wins
  end
  local function inactive(label)
    assert(mode.active() == false, label .. ': mode did not stop')
    assert(#guides() == 0, label .. ': guide leaked')
  end
  local function source_state()
    return {
      lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
      tick = vim.api.nvim_buf_get_changedtick(source),
      modified = vim.bo[source].modified,
      eol = vim.bo[source].endofline,
    }
  end
  local function same_mapping(actual, expected, label)
    for _, field in ipairs({ 'lhs', 'rhs', 'callback', 'expr', 'noremap', 'silent', 'nowait', 'buffer', 'desc' }) do
      assert(actual[field] == expected[field], label .. ': changed mapping field ' .. field)
    end
  end
  local keys = { 'f', 'c', 's', 'r', 'a', 'x', 'd', '<Esc>' }
  local local_calls, global_calls = 0, 0
  local local_callback = function() local_calls = local_calls + 1 end
  local global_callback = function() global_calls = global_calls + 1 end
  vim.keymap.set('n', 'f', local_callback, { buffer = source, silent = true, nowait = true, desc = 'user callback' })
  vim.keymap.set('n', 'c', "'l'", { buffer = source, expr = true, desc = 'user expression' })
  vim.keymap.set('n', 's', global_callback, { silent = true, desc = 'global fallback' })
  local before_maps, movement = {}, {}
  for _, key in ipairs(keys) do before_maps[key] = mapping(key) end
  for _, key in ipairs({ 'h', 'j', 'k', 'l' }) do movement[key] = mapping(key) end
  local before = source_state()
  inactive('initial state')

  -- Both entry points must only enter mode, never invoke the agent implicitly.
  invoke(',h')
  assert(mode.active() == true, 'default leader mapping did not enter mode')
  assert(#dispatched == 0, 'entry invoked an action')
  assert(vim.api.nvim_get_current_win() == source_win, 'guide stole source focus')
  local guide_wins = guides()
  assert(#guide_wins == 1, 'expected exactly one mode guide')
  local guide = guide_wins[1]
  local guide_buf = vim.api.nvim_win_get_buf(guide)
  local config = vim.api.nvim_win_get_config(guide)
  assert(config.relative ~= '' and config.focusable == false, 'guide must be a nonfocusable float')
  assert(not vim.bo[guide_buf].modifiable and vim.bo[guide_buf].readonly, 'guide must be read-only')
  assert(#vim.api.nvim_buf_get_lines(guide_buf, 0, -1, false) > 0, 'guide is empty')
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(guide_buf, 'n')) do
    assert(not vim.tbl_contains(keys, map.lhs), 'modal action installed in guide: ' .. map.lhs)
  end
  mode.start()
  vim.cmd('HodoCodeMode')
  assert(#guides() == 1 and guides()[1] == guide, 'repeated entry duplicated or replaced the guide')
  for _, key in ipairs({ 'h', 'j', 'k', 'l' }) do same_mapping(mapping(key), movement[key], key) end
  for _, key in ipairs(keys) do
    assert(mapping(key).buffer == 1 and type(mapping(key).callback) == 'function',
      'mode action must be a source-local callback: ' .. key)
  end
  for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
    if map.lhs == 's' then assert(map.callback == global_callback, 'mode changed global fallback') end
  end

  local actions = {
    { 'f', 'functions' }, { 'c', 'calls' }, { 's', 'syntax' }, { 'r', 'reload' },
    { 'x', 'cancel' }, { 'd', 'diff' }, { 'a', 'agent' },
  }
  for index, action in ipairs(actions) do
    invoke(action[1])
    assert(#dispatched == index and dispatched[index] == action[2], 'wrong dispatch for ' .. action[1])
    assert(mode.active() == true, action[1] .. ' unexpectedly ended mode')
    assert(#guides() == 1, action[1] .. ' closed the guide')
  end
  assert(local_calls == 0 and global_calls == 0, 'mode invoked shadowed user mappings')
  assert(vim.deep_equal(source_state(), before), 'mode entry/actions modified source')
  invoke('<Esc>')
  inactive('source Escape')
  assert(not vim.api.nvim_win_is_valid(guide), 'Escape did not close original guide')
  for _, key in ipairs(keys) do same_mapping(mapping(key), before_maps[key], key) end
  invoke('f')
  invoke('s')
  assert(local_calls == 1 and global_calls == 1, 'restored callback/global fallback does not execute')
  mode.stop()
  inactive('idempotent stop')

  vim.cmd('HodoCodeMode')
  assert(mode.active() == true, 'mode command did not enter')
  vim.cmd('HodoCodeModeExit')
  inactive('exit command')

  mode.start()
  vim.api.nvim_win_close(guides()[1], true)
  inactive('manually closed guide')

  -- Visiting a result float and returning is not a source buffer switch.
  mode.start()
  local float_buf = vim.api.nvim_create_buf(false, true)
  local float = vim.api.nvim_open_win(float_buf, true, {
    relative = 'editor', row = 1, col = 1, width = 25, height = 3, style = 'minimal',
  })
  assert(mode.active() == true, 'focusing a float ended mode')
  vim.api.nvim_exec_autocmds('InsertEnter', { buffer = float_buf })
  assert(mode.active() == true, 'InsertEnter in a result float ended source mode')
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(float_buf, 'n')) do
    assert(not vim.tbl_contains(keys, map.lhs), 'modal action installed in result float: ' .. map.lhs)
  end
  vim.api.nvim_set_current_win(source_win)
  assert(mode.active() == true, 'returning from float ended mode')
  vim.api.nvim_win_close(float, true)
  invoke('f')
  assert(dispatched[#dispatched] == 'functions', 'action failed after returning from float')
  mode.stop()

  mode.start()
  vim.api.nvim_exec_autocmds('InsertEnter', { buffer = source })
  inactive('source InsertEnter')
  for _, key in ipairs(keys) do same_mapping(mapping(key), before_maps[key], 'InsertEnter ' .. key) end

  mode.start()
  local other = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(other)
  inactive('different normal buffer')
  vim.api.nvim_set_current_buf(source)
  for _, key in ipairs(keys) do same_mapping(mapping(key), before_maps[key], 'buffer switch ' .. key) end

  mode.start()
  local user_changed = function() local_calls = local_calls + 10 end
  vim.keymap.set('n', 'f', user_changed, { buffer = source, desc = 'changed while in mode' })
  mode.stop()
  assert(mapping('f').callback == user_changed, 'stop overwrote a mapping changed by the user')
  invoke('f')
  assert(local_calls == 11, 'user replacement mapping is not callable')

  mode.start()
  hc.setup({ root = root, language = 'go' })
  inactive('setup')
  assert(mapping('f').callback == user_changed, 'setup did not restore user mapping')
  assert(vim.deep_equal(source_state(), before), 'mode lifecycle modified source')
  assert(vim.deep_equal(vim.fn.readfile(root .. '/main.go'), original), 'mode changed source on disk')

  mode.start()
  vim.api.nvim_buf_delete(source, { force = true })
  inactive('source wipe')
  mode.stop()
  inactive('stop after source wipe')
  -- BufDelete also ends mode when the buffer itself remains valid.
  local deleted = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(deleted)
  mode.start()
  assert(mode.active() == true, 'could not enter mode for BufDelete test')
  vim.api.nvim_exec_autocmds('BufDelete', { buffer = deleted })
  inactive('source BufDelete')
  assert(vim.api.nvim_buf_is_valid(deleted), 'BufDelete fixture was unexpectedly wiped')
  vim.fn.delete(root, 'rf')
  print('PASS: mode commands/default mapping, idempotent entry, action dispatch, mapping restoration, guide/floating focus, lifecycle cleanup, user remapping')
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
