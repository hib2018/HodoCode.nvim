local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'module example.test/navigation', '', 'go 1.23' }, root .. '/go.mod')
  local lines = { 'package main', 'func leaf() {}', 'func main() { leaf(); var f func(); f() }', 'func 日本語() { leaf() }' }
  vim.fn.writefile(lines, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source = vim.api.nvim_get_current_buf()
  hc.setup({ root = root, language = 'go' })
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local function wait(test, label)
    assert(vim.wait(15000, test, 10), label .. '\n' .. table.concat(notices, '\n'))
  end
  local function invoke(key) vim.fn.maparg(key, 'n', false, true).callback() end
  for _, name in ipairs({ 'HodoCodeFollow', 'HodoCodeGraph', 'HodoCodeExplain', 'HodoCodeChat', 'HodoCodeNote', 'HodoCodeNotesToggle', 'HodoCodeNotesClear' }) do
    assert(vim.fn.exists(':' .. name) == 2, 'missing command ' .. name)
  end
  vim.api.nvim_win_set_cursor(0, { 3, lines[3]:find('leaf', 1, true) - 1 })
  hc.mode()
  invoke('<CR>')
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 2 end, 'source Enter did not follow')
  assert(require('hodocode.mode').active(), 'same-file navigation should preserve mode')
  hc.exit_mode()
  vim.api.nvim_win_set_cursor(0, { 4, lines[4]:find('leaf', 1, true) - 1 })
  hc.follow()
  wait(function() return vim.api.nvim_win_get_cursor(0)[1] == 2 end, 'UTF8-byte follow')
  vim.api.nvim_win_set_cursor(0, { 3, lines[3]:find('; f()', 1, true) + 1 })
  local before = #notices
  hc.follow()
  wait(function() return #notices > before end, 'unknown reason')
  assert(notices[#notices]:find('未解決', 1, true), notices[#notices])
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, 'unresolved call must not jump')
  before = #notices
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  hc.follow()
  wait(function() return #notices > before end, 'outside call error')
  assert(notices[#notices]:find('呼び出し名', 1, true))
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  hc.graph()
  wait(function() return vim.bo.buftype == 'nofile' end, 'graph float')
  local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n') end
  wait(function() return text():find('Mermaidソース', 1, true) end, 'dependencies Mermaid')
  invoke('<Tab>')
  wait(function() return text():find('navigation#46;leaf', 1, true) and text():find('flowchart TD', 1, true) end, 'call graph Mermaid')
  assert(text():find('視覚レンダリングではありません', 1, true))
  vim.api.nvim_win_close(0, true)
  assert(vim.api.nvim_get_current_buf() == source)

  -- A late graph response cannot overwrite a newer view.
  local pending, rendered = {}, 0
  local client = { request = function(_, method, params, callback)
    assert(method == 'graph'); pending[#pending + 1] = { params = params, callback = callback }
  end }
  local ctx = hc.context()
  local graph = { kind = 'calls', nodes = {}, edges = {}, mermaid = 'flowchart LR\n TEST' }
  local buf, win = require('hodocode.graph').open(ctx, client, { ID = 'example.test/navigation.main' }, {
    graph_renderer = function() rendered = rendered + 1; error('renderer failed') end,
  })
  invoke('<Tab>')
  pending[1].callback({ nodes = {}, edges = {}, mermaid = 'OLD' })
  assert(not table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find('OLD', 1, true))
  pending[2].callback(graph)
  assert(rendered == 1 and table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):find('TEST', 1, true))
  assert(notices[#notices]:find('図レンダラー', 1, true))
  vim.api.nvim_win_close(win, true)
  pending[2].callback(graph)
  assert(rendered == 1, 'closed graph invoked renderer')
  -- Delayed UI requests must not steal focus after the user moves away.
  local start = require('hodocode.client').start
  local callbacks = {}
  require('hodocode.client').start = function()
    return { request = function(_, method, _, callback) callbacks[#callbacks + 1] = { method, callback } end }
  end
  for _, method in ipairs({ 'graph', 'calls', 'follow' }) do
    callbacks = {}
    hc[method]()
    assert(callbacks[1][1] == 'reload')
    callbacks[1][2]({ reloaded = true })
    assert(callbacks[2][1] == 'functions')
    local other = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(other)
    local windows = #vim.api.nvim_list_wins()
    callbacks[2][2]({ { ID = 'example.test/navigation.main', File = 'main.go', Line = 3, End = 3 } })
    assert(#callbacks == 2 and vim.api.nvim_get_current_buf() == other and #vim.api.nvim_list_wins() == windows,
      method .. ' stole focus after source switch')
    vim.api.nvim_set_current_buf(source)
    vim.api.nvim_buf_delete(other, { force = true })
  end
  require('hodocode.client').start = start
  vim.fn.writefile({ 'package main', 'func other() {}' }, root .. '/target.go')
  local target = vim.fn.bufadd(root .. '/target.go')
  vim.fn.bufload(target)
  vim.api.nvim_buf_set_lines(target, 0, 0, false, { '// local edit' })
  require('hodocode.ui').jump(root, { File = 'target.go', Line = 2 })
  assert(vim.api.nvim_get_current_buf() == source and vim.bo[target].modified, 'jumped to stale modified target')
  assert(notices[#notices]:find('移動先に未保存', 1, true))
  vim.api.nvim_buf_delete(target, { force = true })
  hc.cancel()
  require('hodocode.client').stop_all()
  vim.fn.delete(root, 'rf')
  print('PASS: real source navigation (UTF8/unresolved), graph switching, stale graph and renderer failure')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
