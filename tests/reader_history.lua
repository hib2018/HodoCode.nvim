local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  vim.o.lines = 30
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module example.test/reader', '', 'go 1.23' }, root .. '/go.mod')
  local lines = { 'package main' }
  for i = 2, 120 do lines[i] = 'func f' .. i .. '() {}' end
  for _, file in ipairs({ 'a.go', 'b.go' }) do vim.fn.writefile(lines, root .. '/' .. file) end
  local hc, ui, mode = require('hodocode'), require('hodocode.ui'), require('hodocode.mode')
  hc.setup({ root = root, language = 'go' })
  local functions = {
    { ID = 'a', File = 'a.go', Line = 45, End = 45 },
    { ID = 'b', File = 'b.go', Line = 60, End = 60 },
  }
  require('hodocode.client').start = function()
    return { request = function(_, method, params, callback)
      if method == 'functions' then callback(functions)
      elseif method == 'calls' then
        local index = params['function'] == 'a' and 1 or 2
        local target = functions[3 - index]
        callback({ calls = { { Line = functions[index].Line, Column = 1, EndColumn = 2, To = target.ID } },
          Targets = { [target.ID] = target } })
      else callback({}) end
    end }
  end
  local marker_ns = vim.api.nvim_create_namespace('HodoCodeFunction')
  local function markers(buf) return #vim.api.nvim_buf_get_extmarks(buf, marker_ns, 0, -1, {}) end
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  vim.cmd.edit(root .. '/a.go')
  local a, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_cursor(0, { 45, 4 })
  vim.fn.winrestview({ topline = 40, lnum = 45, col = 4 })
  local original = vim.fn.winsaveview()
  assert(not ui.back(), 'empty history navigated')
  assert(vim.deep_equal(original, vim.fn.winsaveview()))
  mode.start()
  assert(markers(a) == 1, 'source marker missing')
  assert(ui.jump(root, { File = 'b.go', Line = 60 }))
  local b = vim.api.nvim_get_current_buf()
  assert(b ~= a and mode.active(), 'cross-file jump ended mode')
  assert(markers(b) == 1 and markers(a) == 0, 'cross-file jump did not refresh marker ranges')
  vim.fn.winrestview({ topline = 52, lnum = 60, col = 3 })
  local nested = vim.fn.winsaveview()
  assert(ui.jump(root, { File = 'b.go', Line = 90 }))
  assert(mode.active())
  assert(ui.back() and vim.deep_equal(nested, vim.fn.winsaveview()), 'nested cursor/view not restored')
  assert(ui.back() and vim.api.nvim_get_current_buf() == a, 'cross-file back failed')
  assert(mode.active() and vim.deep_equal(original, vim.fn.winsaveview()), 'source cursor/view or mode not restored')
  assert(markers(a) == 1 and markers(b) == 0, 'cross-file back did not restore source marker ranges')
  assert(not ui.back(), 'exhausted history navigated')
  -- The normal jumplist remains useful independently of reader history.
  assert(ui.jump(root, { File = 'b.go', Line = 65 }))
  vim.cmd('normal! ' .. string.char(15))
  assert(vim.api.nvim_get_current_buf() == a and vim.api.nvim_win_get_cursor(0)[1] == 45, 'Ctrl-O lost callsite')
  assert(not mode.active(), 'manual jumplist switch retained mode')
  assert(ui.back())
  assert(not ui.back())
  vim.api.nvim_buf_set_lines(b, 2, 3, false, { '// unsaved target' })
  assert(not ui.jump(root, { File = 'b.go', Line = 4 }), 'modified target accepted')
  assert(not ui.back(), 'refused jump appended history')
  assert(vim.bo[b].modified and vim.api.nvim_buf_get_lines(b, 2, 3, false)[1] == '// unsaved target')
  -- Going back uses the saved buffer without reloading unsaved source changes.
  assert(ui.jump(root, { File = 'a.go', Line = 80 }))
  vim.api.nvim_buf_set_lines(a, 3, 4, false, { '// unsaved source' })
  assert(ui.back() and vim.bo[a].modified)
  assert(vim.api.nvim_buf_get_lines(a, 3, 4, false)[1] == '// unsaved source')
  vim.bo[a].modified = false
  mode.start()
  vim.api.nvim_set_current_buf(b)
  assert(not mode.active(), 'manual switch did not stop mode')
  vim.api.nvim_set_current_buf(a)
  -- Wiped entries use their existing disk path; missing entries cannot navigate.
  assert(ui.jump(root, { File = 'a.go', Line = 20 }))
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_delete(a, { force = true })
  assert(ui.back() and (vim.uv or vim.loop).fs_realpath(vim.api.nvim_buf_get_name(0)) == (vim.uv or vim.loop).fs_realpath(root .. '/a.go'), 'wiped buffer path not restored')
  a = vim.api.nvim_get_current_buf()
  assert(ui.jump(root, { File = 'a.go', Line = 30 }))
  vim.api.nvim_set_current_buf(b)
  vim.api.nvim_buf_delete(a, { force = true })
  vim.fn.delete(root .. '/a.go')
  assert(not ui.back() and vim.api.nvim_get_current_buf() == b, 'missing history entry navigated')
  local content = {}
  for i = 1, 100 do content[i] = 'result ' .. i end
  mode.start()
  local _, dismiss = ui.float(content, 'dismiss')
  vim.fn.maparg('q', 'n', false, true).callback()
  assert(not vim.api.nvim_win_is_valid(dismiss) and mode.active(), 'popup q exited source mode')
  local _, first = ui.float(content, 'first')
  local _, latest = ui.float(content, 'latest')
  vim.api.nvim_set_current_win(source_win)
  local source_view = vim.fn.winsaveview()
  assert(ui.scroll(1))
  assert(vim.api.nvim_get_current_win() == source_win and vim.deep_equal(source_view, vim.fn.winsaveview()), 'scroll stole source focus/view')
  assert(vim.api.nvim_win_call(latest, vim.fn.winsaveview).topline == 2, 'latest popup did not scroll')
  vim.api.nvim_set_current_win(first)
  vim.fn.maparg(']', 'n', false, true).callback()
  assert(vim.fn.winsaveview().topline == 2, 'focused owned popup lost priority')
  vim.fn.maparg('[', 'n', false, true).callback()
  assert(vim.fn.winsaveview().topline == 1)
  vim.fn.maparg('<C-c>', 'n', false, true).callback()
  assert(not vim.api.nvim_win_is_valid(first) and not mode.active(), 'popup Ctrl-C did not exit reader mode')
  vim.api.nvim_set_current_win(source_win)
  mode.start()
  vim.api.nvim_set_current_win(latest)
  vim.fn.maparg('<C-d>', 'n', false, true).callback()
  assert(not vim.api.nvim_win_is_valid(latest) and not ui.scroll(1), 'closed popup remained scrollable')
  assert(not mode.active(), 'popup Ctrl-D did not exit reader mode')
  vim.bo[b].modified = false
  local _, popup = ui.float(content, 'jump origin')
  assert(ui.jump(root, { File = 'b.go', Line = 30 }))
  vim.api.nvim_win_close(popup, true)
  assert(not ui.back(), 'transient popup appended reader history')
  assert(vim.deep_equal(vim.fn.readfile(root .. '/b.go'), lines), 'source disk contents changed')
  vim.fn.delete(root, 'rf')
  print('PASS: reader history, safe jumps, jumplist, mode continuity, popup scrolling/focus')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
