local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden, vim.o.columns, vim.o.lines = true, 140, 45
  local mode = require('hodocode.mode')
  local ui = require('hodocode.ui')
  local hc = require('hodocode')
  require('hodocode.client').start = function() error('navigation help must not start a backend') end

  local original = { 'package main', '', 'func main() {}' }
  local path = vim.fn.tempname() .. '.go'
  vim.fn.writefile(original, path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local previous_help = function() error('mode dispatched the original question-mark mapping') end
  vim.keymap.set('n', '?', previous_help, { buffer = source, silent = true, nowait = true, desc = 'original help' })
  local original_map = vim.fn.maparg('?', 'n', false, true)
  local original_state = {
    lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
    tick = vim.api.nvim_buf_get_changedtick(source),
    modified = vim.bo[source].modified,
    eol = vim.bo[source].endofline,
  }
  local function source_unchanged()
    assert(vim.deep_equal(original_state, {
      lines = vim.api.nvim_buf_get_lines(source, 0, -1, false),
      tick = vim.api.nvim_buf_get_changedtick(source),
      modified = vim.bo[source].modified,
      eol = vim.bo[source].endofline,
    }), 'navigation UI changed source state')
    assert(vim.deep_equal(vim.fn.readfile(path), original), 'navigation UI changed source on disk')
  end
  local function invoke(key)
    local map = vim.fn.maparg(key, 'n', false, true)
    assert(type(map.callback) == 'function', 'missing callback for ' .. key)
    map.callback()
  end
  local function guides()
    local result = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'hodocode-mode' then result[#result + 1] = win end
    end
    return result
  end
  local function lines(win)
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  end
  local function contains(text, needle, label)
    assert(text:find(needle, 1, true), (label or 'missing help text') .. ': ' .. needle)
  end
  local function one_guide()
    local wins = guides()
    assert(#wins == 1, 'expected one guide')
    return wins[1]
  end
  local function stopped(label)
    assert(not mode.active(), label .. ': mode still active')
    assert(#guides() == 0, label .. ': guide leaked')
    assert(#vim.api.nvim_list_wins() == 1, label .. ': help leaked')
    assert(vim.api.nvim_get_current_win() == source_win, label .. ': source focus not restored')
    local restored = vim.fn.maparg('?', 'n', false, true)
    for _, field in ipairs({ 'lhs', 'rhs', 'callback', 'expr', 'noremap', 'silent', 'nowait', 'buffer', 'desc' }) do
      assert(restored[field] == original_map[field], label .. ': original ? mapping changed: ' .. field)
    end
    source_unchanged()
  end
  local function help_size(win)
    local width, height = ui.popup_size()
    assert(vim.api.nvim_win_get_width(win) == width, 'help does not use unified 90% width')
    assert(vim.api.nvim_win_get_height(win) == height, 'help does not use unified 80% height')
  end
  local function open_help()
    assert(vim.api.nvim_get_current_win() == source_win, 'open help fixture lost source focus')
    local map = vim.fn.maparg('?', 'n', false, true)
    assert(map.buffer == 1 and map.callback ~= previous_help, '? must be source-local')
    invoke('?')
    local win = vim.api.nvim_get_current_win()
    assert(win ~= source_win and win ~= one_guide(), 'help did not focus a separate popup')
    assert(mode.active(), 'opening help stopped mode')
    help_size(win)
    assert(not vim.bo[vim.api.nvim_win_get_buf(win)].modifiable, 'help is editable')
    return win
  end

  mode.start()
  assert(type(mode.help) == 'function', 'mode.help export missing')
  assert(hc.help == nil, 'help should not add a top-level init API')
  local guide = one_guide()
  local wide_lines = lines(guide)
  assert(#wide_lines == 4, 'normal-width guide must have four grouped rows')
  local guide_text = table.concat(wide_lines, '\n')
  for _, hint in ipairs({ '?', '操作一覧', '移動', '表示', 'AI', 'n/N', 'Enter', 'b', 'g/G', 't', 'f', 'K', 'E', 'e', 'x', 'q', 'Esc' }) do
    contains(guide_text, hint, 'guide primary workflow')
  end
  contains(wide_lines[1], '?', 'guide title')
  contains(wide_lines[2], '移動', 'guide second row')
  contains(wide_lines[3], '表示', 'guide third row')
  contains(wide_lines[4], 'AI', 'guide fourth row')

  local help = open_help()
  local help_lines = lines(help)
  local categories, current = {}, nil
  for _, line in ipairs(help_lines) do
    local heading = line:match('^##%s+(.-)%s*$')
    if heading then current = heading; categories[current] = categories[current] or {} end
    if current then categories[current][#categories[current] + 1] = line end
  end
  local function category_keys(heading, keys)
    assert(categories[heading], 'help category missing: ' .. heading)
    local text = table.concat(categories[heading], '\n')
    for _, key in ipairs(keys) do
      if key:match('^[A-Za-z]$') then
        assert(text:find('%f[%a]' .. key .. '%f[%A]'), heading .. ': key missing: ' .. key)
      else
        contains(text, key, heading)
      end
    end
    return text
  end
  category_keys('基本の移動', { 'n', 'N', 'Enter', 'b', 'g', 'G' })
  category_keys('表示と読解', { 't', 'f', 's', 'r', 'm', 'c', 'z', 'K', '[', ']', '?' })
  category_keys('AI', { 'E', 'e', 'i', 'a', 'x', 'd' })
  category_keys('終了', { 'q', 'Esc', 'v', 'Ctrl' })
  local all_help = table.concat(help_lines, '\n')
  for _, meaning in ipairs({ '現在の関数', '呼び出し', '黄色', '履歴', 'ファイル', 'h/j/k/l', '標準', '?' }) do
    contains(all_help, meaning, 'navigation explanation')
  end
  assert(all_help:find('不明', 1, true) or all_help:find('未解決', 1, true)
    or all_help:find('unknown', 1, true), 'n/N must include unknown calls')
  assert(all_help:find('確定', 1, true) or all_help:find('証明', 1, true)
    or all_help:find('proven', 1, true), 'Enter must explain proven targets')

  mode.help()
  assert(vim.api.nvim_get_current_win() == help and #vim.api.nvim_list_wins() == 3, 'repeated help duplicated popup')
  invoke('q')
  assert(not vim.api.nvim_win_is_valid(help), 'q did not close help')
  assert(mode.active() and one_guide() == guide, 'q in help ended mode or replaced guide')
  assert(vim.api.nvim_get_current_win() == source_win, 'q did not return source focus')
  for _, key in ipairs({ '<Esc>', '?' }) do
    help = open_help()
    invoke(key)
    assert(not vim.api.nvim_win_is_valid(help), key .. ' did not close help')
    assert(mode.active() and one_guide() == guide, key .. ' in help ended mode')
    assert(vim.api.nvim_get_current_win() == source_win, key .. ' did not return source focus')
  end

  -- A manually closed popup must not leave a stale handle that closes its replacement.
  help = open_help()
  vim.api.nvim_win_close(help, true)
  assert(mode.active(), 'manually closing help ended mode')
  local replacement = open_help()
  assert(replacement ~= help and #vim.api.nvim_list_wins() == 3, 'closed help could not reopen cleanly')
  mode.stop()
  assert(not vim.api.nvim_win_is_valid(replacement) and not vim.api.nvim_win_is_valid(guide), 'stop while help focused leaked UI')
  stopped('stop from help')

  for _, key in ipairs({ '<C-c>', '<C-d>' }) do
    mode.start()
    help = open_help()
    invoke(key)
    assert(not vim.api.nvim_win_is_valid(help), key .. ' did not close help')
    stopped(key .. ' from help')
  end

  mode.start()
  guide = one_guide()
  help = open_help()
  vim.api.nvim_win_close(guide, true)
  assert(not vim.api.nvim_win_is_valid(help), 'guide WinClosed did not clean up focused help')
  stopped('guide closed while help focused')

  mode.start()
  guide = one_guide()
  local function fit_guide()
    local config = vim.api.nvim_win_get_config(guide)
    assert(config.focusable == false, 'resized guide became focusable')
    assert(config.row >= 0 and config.col >= 0, 'resized guide moved outside editor')
    assert(config.col + config.width + 2 <= vim.o.columns, 'guide border exceeds editor width')
    assert(config.row + config.height + 2 <= vim.o.lines - vim.o.cmdheight, 'guide border exceeds editor height')
    assert(#lines(guide) <= config.height, 'guide rows clipped vertically')
    for _, line in ipairs(lines(guide)) do
      assert(vim.fn.strdisplaywidth(line) <= config.width, 'guide text clipped at width ' .. config.width .. ': ' .. line)
    end
    assert(vim.api.nvim_get_current_win() == source_win, 'resize stole source focus')
  end
  fit_guide()
  for _, screen in ipairs({ { 52, 16 }, { 28, 8 }, { 12, 6 } }) do
    vim.o.columns, vim.o.lines = screen[1], screen[2]
    vim.api.nvim_exec_autocmds('VimResized', {})
    fit_guide()
    local compact = table.concat(lines(guide), '\n')
    assert(vim.fn.strdisplaywidth(compact) < vim.fn.strdisplaywidth(guide_text), 'narrow guide did not reduce hints')
    contains(compact, '?', 'narrow guide must retain help discovery')
    contains(compact, 'q', 'narrow guide must retain exit')
  end
  vim.o.columns, vim.o.lines = 140, 45
  vim.api.nvim_exec_autocmds('VimResized', {})
  fit_guide()
  assert(vim.deep_equal(lines(guide), wide_lines), 'expanding editor did not restore full guide text')
  help = open_help()
  vim.o.columns, vim.o.lines = 100, 32
  vim.api.nvim_exec_autocmds('VimResized', {})
  help_size(help)
  mode.stop()
  stopped('resized help cleanup')
  vim.fn.delete(path)
  print('PASS: categorized navigation help, source-local ? restoration, popup lifecycle/focus, responsive guide, source immutability')
end

local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
