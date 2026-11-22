if vim.g.loaded_hodocode then return end
vim.g.loaded_hodocode = true

local function invoke(method, arg)
  local ok, err = pcall(function() require('hodocode')[method](arg) end)
  if not ok then vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR) end
end
for command, method in pairs({
  HodoCodeFunctions = 'functions', HodoCodeCalls = 'calls', HodoCodeSyntax = 'syntax',
  HodoCodeReload = 'reload', HodoCodeDiff = 'diff',
  HodoCodeMode = 'mode', HodoCodeModeExit = 'exit_mode',
  HodoCodeFollow = 'follow', HodoCodeGraph = 'graph', HodoCodeChat = 'chat',
  HodoCodeNotesToggle = 'notes_toggle', HodoCodeNotesClear = 'notes_clear', HodoCodeNote = 'notes_show',
}) do
  vim.api.nvim_create_user_command(command, function() invoke(method) end, {})
end
vim.api.nvim_create_user_command('HodoCodeAgent', function(args) invoke('agent', args.args) end, { nargs = '*' })
vim.api.nvim_create_user_command('HodoCodeExplain', function(args) invoke('explain', args.args) end, { nargs = '*' })
vim.api.nvim_create_user_command('HodoCodeCancel', function() invoke('cancel') end, {})
require('hodocode').setup()
if vim.fn.maparg('<leader>h', 'n') == '' then
  vim.keymap.set('n', '<leader>h', '<cmd>HodoCodeMode<cr>', { desc = 'HodoCodeモード', nowait = true, silent = true })
end
