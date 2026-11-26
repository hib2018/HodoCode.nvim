local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.lines, vim.o.columns = 45, 140
  local ui = require('hodocode.ui')
  for value, label in pairs({ starting = '開始中', waiting = '応答待ち', received = '応答受信',
    validating = '検証中', applying = '反映中', done = '完了', completed = '完了',
    cancelled = '中止', error = '失敗', prompt = '指示入力', idle = '待機中',
    sent = '送信済み', applied = '適用済み', nochange = '変更なし',
    timeout = '時間制限超過', invalid_patch = '不正な変更', unknown = '処理中' }) do
    assert(ui.label(value) == label, 'wrong shared label for ' .. value)
  end
  assert(ui.label(nil) == '処理中')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  vim.bo[source].filetype = 'lua'
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'local untouched = true' })
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local global = { wrap = vim.o.wrap, linebreak = vim.o.linebreak,
    conceallevel = vim.o.conceallevel, concealcursor = vim.o.concealcursor,
    syntax_on = vim.g.syntax_on, syntax = vim.bo[source].syntax }
  local original = { '# Heading', '**bold** and `code`', '[link](https://example.com)', 'body and context unchanged' }
  local buf, win = ui.float(original, 'Ignored decorative title')
  local cfg = vim.api.nvim_win_get_config(win)
  assert(not cfg.title or #cfg.title == 0, 'decorative title remains')
  assert(vim.deep_equal(cfg.border, { '┌', '─', '┐', '│', '┘', '─', '└', '│' }), 'not a plain single border')
  assert(vim.wo[win].wrap and vim.wo[win].linebreak)
  assert(vim.wo[win].conceallevel == 2 and vim.wo[win].concealcursor == 'nc')
  assert(vim.bo[buf].filetype == 'markdown' and vim.b[buf].current_syntax == 'markdown')
  for _, item in ipairs({ { 1, 3, 'markdownH1' }, { 2, 3, 'markdownBold' },
    { 2, 15, 'markdownCode' }, { 3, 2, 'markdownLinkText' } }) do
    assert(vim.fn.synIDattr(vim.fn.synID(item[1], item[2], 1), 'name') == item[3], item[3] .. ' not highlighted under -u NONE')
  end
  local bold = vim.api.nvim_get_hl(0, { name = 'htmlBold', link = false })
  assert(bold.bold, 'native bold style missing')
  assert(vim.api.nvim_get_hl(0, { name = 'markdownCode' }).link == 'String', 'code has no theme highlight')
  assert(vim.api.nvim_get_hl(0, { name = 'markdownCodeBlock' }).link == 'String', 'code block has no theme highlight')
  assert(vim.fn.synconcealed(2, 1)[1] == 1, 'bold punctuation is not concealed')
  ui.markdown(buf)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), original), 'Markdown text was transformed')
  assert(not vim.bo[buf].modifiable, 'readonly popup became editable')
  for _, key in ipairs({ 'q', '<Esc>', '<C-c>', '<C-d>', '[', ']' }) do
    assert(vim.fn.maparg(key, 'n', false, true).callback, 'lost popup key ' .. key)
  end
  vim.o.lines, vim.o.columns = 30, 100
  vim.api.nvim_exec_autocmds('VimResized', {})
  cfg = vim.api.nvim_win_get_config(win)
  local width, height = ui.popup_size()
  assert(cfg.width == width and cfg.height == height and (not cfg.title or #cfg.title == 0))
  assert(vim.wo[win].conceallevel == 2 and vim.wo[win].linebreak, 'resize lost Markdown options')
  vim.fn.maparg('q', 'n', false, true).callback()
  assert(not vim.api.nvim_win_is_valid(win) and not vim.api.nvim_buf_is_valid(buf))
  assert(vim.api.nvim_get_current_win() == source_win)
  assert(vim.o.wrap == global.wrap and vim.o.linebreak == global.linebreak
    and vim.o.conceallevel == global.conceallevel and vim.o.concealcursor == global.concealcursor,
    'source/global window options changed')
  assert(vim.bo[source].syntax == global.syntax and vim.bo[source].filetype == 'lua'
    and vim.g.syntax_on == global.syntax_on, 'source/global syntax changed')
  assert(vim.api.nvim_buf_get_changedtick(source) == tick)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), { 'local untouched = true' }))
  local plain = vim.api.nvim_create_buf(false, true)
  vim.bo[plain].bufhidden = 'wipe'
  local plain_win = ui.open_popup(plain)
  assert(vim.bo[plain].filetype == '' and vim.b[plain].current_syntax == nil, 'plain buffer gained Markdown syntax')
  vim.api.nvim_win_close(plain_win, true)
  print('PASS: minimal popup, native Markdown syntax/conceal under -u NONE, resize, keys, text and source/global isolation')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
