local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.cmd('runtime plugin/hodocode.lua')
  local hc = require('hodocode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. '/helper', 'p')
  vim.fn.writefile({ 'module example.test/importhelp', '', 'go 1.23' }, root .. '/go.mod')
  vim.fn.writefile({ 'package helper', '// Double returns twice the input.', 'func Double(x int) int { return x * 2 }' }, root .. '/helper/helper.go')
  local source_lines = {
    'package main',
    'import (',
    '  f "fmt"',
    '  h "example.test/importhelp/helper"; sig "os/signal"',
    ')',
    'func main() {',
    '  _ = "日本語"; f.Println(h.Double(2)); _ = sig.NotifyContext',
    '}',
  }
  vim.fn.writefile(source_lines, root .. '/main.go')
  vim.cmd.edit(root .. '/main.go')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  hc.setup({ root = root, language = 'go', timeout_ms = 30000 })
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local function wait(test, label)
    assert(vim.wait(35000, test, 10), 'timeout: ' .. label .. '\n' .. table.concat(notices, '\n'))
  end
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  end
  local function press(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
  end
  local function show_at(name)
    local col = assert(source_lines[7]:find(name, 1, true)) - 1
    vim.api.nvim_set_current_win(source_win)
    vim.api.nvim_win_set_cursor(0, { 7, col })
    press('s')
    wait(function() return vim.bo.buftype == 'nofile' end, 'syntax popup for ' .. name)
    assert(vim.api.nvim_win_get_config(0).relative == 'editor', 'shared popup must be used')
  end
  hc.mode()
  show_at('Println')
  assert(text():find('関数情報: Println', 1, true), text())
  assert(text():find('func fmt.Println', 1, true), text())
  assert(text():find('標準出力へ書き込みます', 1, true), 'Japanese SDK help must be visible: ' .. text())
  assert(not text():find('Println formats', 1, true), 'registered functions must use Japanese help')
  assert(text():find('GOROOT/src/fmt/print.go:', 1, true), text())
  press('q')
  assert(require('hodocode.mode').active() and vim.api.nvim_get_current_buf() == source)
  show_at('NotifyContext')
  assert(text():find('関数情報: NotifyContext', 1, true), text())
  for _, translated in ipairs({ '親コンテキストのコピー', '既定の動作（終了）', 'context.Cause', '関連するリソースを解放', '## 構文', '## 注意点', '## 参照元' }) do
    assert(text():find(translated, 1, true), 'missing translated paragraph or heading: ' .. translated)
  end
  for _, original in ipairs({ 'NotifyContext returns a copy', 'The stop function', '日本語説明は未登録', '## syntax', '## caution', '## reference' }) do
    assert(not text():find(original, 1, true), 'translated help must not retain fallback English: ' .. original)
  end
  assert(text():find('func os/signal.NotifyContext', 1, true), 'signature must stay unchanged')
  press('q')
  show_at('Double')
  assert(text():find('関数情報: Double', 1, true), text())
  assert(text():find('日本語説明は未登録', 1, true), text())
  assert(text():find('Double returns twice the input.', 1, true), text())
  assert(text():find('func example.test/importhelp/helper.Double(x int) int', 1, true), text())
  assert(text():find('helper/helper.go:', 1, true), text())
  local popup = vim.api.nvim_get_current_win()
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { '// unsaved' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(not vim.api.nvim_win_is_valid(popup), 'stale function help must close like syntax help')
  assert(require('hodocode.mode').active(), 'closing help must preserve reader mode')
  vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
  vim.bo[source].modified = false
  hc.exit_mode()
  require('hodocode.client').stop_all()
  assert(table.concat(vim.fn.readfile(root .. '/main.go'), '\n') == table.concat(source_lines, '\n'))
  vim.fn.delete(root, 'rf')
  print('PASS: real s mapping, pre-translated NotifyContext paragraphs/Japanese headings, imported SDK/local aliases, signatures/docs/source labels, UTF8 byte position, shared popup and stale cleanup; no AI/network')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
