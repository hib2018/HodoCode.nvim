local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local hc = require('hodocode')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  root = (vim.uv or vim.loop).fs_realpath(root)
  local notices, starts = {}, 0
  vim.notify = function(message) notices[#notices + 1] = message end
  local client = require('hodocode.client')
  local start = client.start
  client.start = function() starts = starts + 1; error('invalid context must not start backend') end
  local function open(name, lines)
    vim.fn.writefile(lines, root .. '/' .. name)
    vim.cmd.edit(vim.fn.fnameescape(root .. '/' .. name))
  end
  local function rejects(fragment)
    local ok, err = pcall(hc.context)
    assert(not ok and err:find(fragment, 1, true), tostring(err))
    for _, method in ipairs({ 'functions', 'calls', 'syntax', 'reload' }) do
      hc[method]()
      assert(notices[#notices]:find(fragment, 1, true), notices[#notices])
    end
    assert(starts == 0, 'invalid context started backend')
  end
  hc.setup({ root = root, language = 'go' })
  open('init.lua', { 'return {}' })
  rejects('Luaは未対応')
  hc.config.language = 'auto'
  rejects('language = "auto"にしても解析できません')
  open('README', { 'notes' })
  rejects('拡張子なし')
  open('main.go', { 'package main', 'func main() {}' })
  rejects('Goの解析に必要なgo.mod')
  hc.config.language = 'go'
  rejects('go.mod配下の.goファイル')
  open('main_test.go', { 'package main' })
  rejects('_test.goは現在のHodoCodeでは解析対象外')
  open('example.py', { 'def example(): pass' })
  rejects('setupのlanguageを"auto"または"python"に変更')
  hc.config.language = ' PY '
  assert(pcall(hc.context), 'Python alias should not require go.mod')
  hc.config.language = 'auto'
  assert(pcall(hc.context), 'non-Go source should not require go.mod')
  vim.fn.mkdir(root .. '/nested', 'p')
  vim.fn.writefile({ 'module example.test/nested', '', 'go 1.23' }, root .. '/nested/go.mod')
  open('nested/main.go', { 'package main', 'func main() {}' })
  for _, language in ipairs({ 'go', ' GOLANG ', 'auto' }) do
    hc.config.language = language
    assert(pcall(hc.context), 'nested module and language alias must work: ' .. language)
  end
  local get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function() return { { attached_buffers = { [vim.api.nvim_get_current_buf()] = true } } } end
  assert(pcall(hc.context), 'Go LSP must not trigger non-Go duplicate guard')
  vim.lsp.get_clients = get_clients
  client.start = start
  client.stop_all()
  vim.fn.delete(root, 'rf')
  print('PASS: actionable unsupported-language, mismatch, missing-go.mod and test-file errors; no backend startup; aliases/nested modules/Go LSP preserved')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then
  io.stderr:write(err .. '\n')
  vim.cmd('cquit 1')
else
  vim.cmd('qa!')
end
