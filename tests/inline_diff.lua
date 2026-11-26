local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local diff = require('hodocode.inline_diff')
  local ns = vim.api.nvim_create_namespace('HodoCodeInlineDiff')
  local buf = vim.api.nvim_get_current_buf()
  local calls = 0
  local function logical(lines, eol)
    return { lines = lines, endofline = eol ~= false, fileformat = 'unix', bomb = false }
  end
  local function marks()
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end
  local function flush() vim.wait(20, function() return false end, 1) end
  local function setup(before, after, eol)
    diff.clear(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, after)
    vim.bo[buf].endofline = eol ~= false
    vim.bo[buf].fileformat, vim.bo[buf].bomb = 'unix', false
    assert(diff.toggle(buf, function() calls = calls + 1; return before end))
    return marks()
  end
  local function highlights(group)
    local result = {}
    for _, mark in ipairs(marks()) do
      if mark[4].hl_group then
        assert(mark[4].hl_group == group and mark[4].hl_eol)
        assert(mark[4].end_row == mark[2] + 1 and mark[4].end_col == 0)
        result[#result + 1] = mark[2]
      end
    end
    return result
  end
  local function deleted()
    local result = {}
    for _, mark in ipairs(marks()) do
      if mark[4].virt_lines then
        result[#result + 1] = { mark[2], mark[4].virt_lines_above, mark[4].virt_lines }
      end
    end
    return result
  end
  local function old(row, above, ...)
    local lines = {}
    for _, text in ipairs({ ... }) do lines[#lines + 1] = { { '- ' .. text, 'DiffDelete' } } end
    return { row, above, lines }
  end
  local function equal(actual, expected)
    assert(vim.deep_equal(actual, expected), vim.inspect(actual) .. '\nexpected: ' .. vim.inspect(expected))
  end

  local attach, attached = vim.api.nvim_buf_attach, 0
  vim.api.nvim_buf_attach = function(...)
    attached = attached + 1
    return attach(...)
  end
  diff.refresh(buf, logical({ 'unused' }))
  assert(attached == 0 and not diff.visible(buf), 'hidden diff attached a buffer watcher')
  vim.api.nvim_buf_attach = attach

  setup(logical({ 'top', 'old1', 'old2', 'end' }), { 'top', 'new1', 'new2', 'end' })
  equal(highlights('DiffChange'), { 1, 2 })
  equal(deleted(), { old(1, false, 'old1'), old(2, false, 'old2') })
  setup(logical({ 'a', 'b', 'c' }), { 'x' })
  equal(highlights('DiffChange'), { 0 })
  equal(deleted(), { old(0, false, 'a', 'b', 'c') })
  setup(logical({ 'a' }), { 'x', 'y', '' })
  equal(highlights('DiffChange'), { 0, 1, 2 })
  equal(deleted(), { old(0, false, 'a') })
  setup(logical({ 'a' }), { 'a', 'b', '' })
  equal(highlights('DiffAdd'), { 1, 2 })
  equal(deleted(), {})
  setup(logical({ 'a', 'b', 'c' }), { 'a', 'c' })
  equal(deleted(), { old(0, false, 'b') })
  setup(logical({ 'a', 'b' }), { 'b' })
  equal(deleted(), { old(0, true, 'a') })
  setup(logical({ 'a', 'b' }, false), { '' }, false)
  equal(deleted(), { old(0, true, 'a', 'b') })
  equal(highlights('DiffChange'), {})
  setup(logical({ '' }, false), { '' }, false)
  equal(marks(), {})
  setup(logical({ '' }, false), { 'new' }, false)
  equal(highlights('DiffAdd'), { 0 })
  equal(deleted(), {})
  setup(logical({ 'a' }), { 'a' }, false)
  equal(highlights('DiffChange'), {})
  local eof = deleted()
  assert(#eof == 1 and #eof[1][3] == 2)
  assert(eof[1][3][1][1][1] == '- 末尾改行あり' and eof[1][3][2][1][1] == '+ 末尾改行なし')
  assert(eof[1][3][1][1][2] == 'DiffText')
  setup(logical({ 'a' }), { 'a' })
  equal(marks(), {})

  local many = {}
  for i = 1, 1105 do many[i] = 'old' .. i end
  setup(logical(many), { 'replacement' })
  assert(#deleted()[1][3] == 1105, 'must not truncate old lines')

  -- Neither toggles nor refresh may touch source, undo history, focus or metadata.
  setup(logical({ 'before' }), { 'after' })
  vim.bo[buf].modified = false
  local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local undo, tick = vim.fn.undotree(), vim.api.nvim_buf_get_changedtick(buf)
  local win, cursor = vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
  local tabs, windows = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_wins()
  diff.refresh(buf)
  assert(not diff.toggle(buf, function() error('off must not call provider') end))
  assert(not diff.visible(buf) and #marks() == 0)
  assert(diff.toggle(buf, function() return logical({ 'before' }) end))
  equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content)
  equal(vim.fn.undotree(), undo)
  assert(vim.api.nvim_buf_get_changedtick(buf) == tick and not vim.bo[buf].modified)
  assert(vim.api.nvim_get_current_win() == win)
  equal(vim.api.nvim_win_get_cursor(0), cursor)
  assert(#vim.api.nvim_list_tabpages() == tabs and #vim.api.nvim_list_wins() == windows)
  assert(not vim.wo.diff)

  -- API edits are observed even without TextChanged; edits do not reread disk.
  setup(logical({ 'same' }), { 'same' })
  local captured_calls = calls
  vim.cmd('let &undolevels = &undolevels')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'manual' })
  flush()
  equal(deleted(), { old(0, false, 'same') })
  assert(calls == captured_calls)
  vim.cmd.undo()
  flush()
  equal(marks(), {})
  assert(calls == captured_calls)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'latest' })
  flush()
  diff.refresh(buf, logical({ 'latest' }))
  equal(marks(), {})
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'later' })
  flush()
  equal(deleted(), { old(0, false, 'latest') })

  -- Queued work must not resurrect decorations after off, rename, wipe or shutdown.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'queued' })
  diff.clear(buf)
  flush()
  equal(marks(), {})
  for _ = 1, 20 do
    assert(diff.toggle(buf, function() return logical({ 'base' }) end))
    assert(not diff.toggle(buf, function() error('off') end))
  end
  assert(diff.toggle(buf, function() return logical({ 'base' }) end))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'queued again' })
  vim.api.nvim_buf_set_name(buf, vim.fn.tempname())
  flush()
  assert(not diff.visible(buf) and #marks() == 0)
  assert(diff.toggle(buf, function() return logical({ 'base' }) end))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'wipe queued' })
  vim.api.nvim_buf_delete(buf, { force = true })
  flush()
  assert(not diff.visible(buf))
  buf = vim.api.nvim_get_current_buf()
  assert(diff.toggle(buf, function() return logical({ 'base' }) end))
  diff.shutdown()
  assert(not diff.visible(buf) and #marks() == 0)
  local notify = vim.notify
  vim.notify = function() end
  assert(not diff.toggle(buf, function() return nil, 'unreadable' end))
  vim.notify = notify
  print('PASS: inline diff positioning, full deletions, EOF, source invariants, API edits/undo, captured baseline and cleanup')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
