local M = {}
local reads = { read_file = true, grep_files = true, glob_files = true }
local kinds = { allow_once = true, allow_always = true, reject_once = true, reject_always = true }

local function string(value, limit)
  return type(value) == 'string' and #value > 0 and #value <= limit and not value:find('%z')
end

local function display(value)
  return type(value) == 'string' and value:sub(1, 320):gsub('[%c]', ' ') or ''
end

function M.request(params, done)
  local finished, buf, win, close_event, wipe_event
  local function finish(option)
    if finished then return end
    finished = true
    if close_event then pcall(vim.api.nvim_del_autocmd, close_event) end
    if wipe_event then pcall(vim.api.nvim_del_autocmd, wipe_event) end
    if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if buf and vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    done({ outcome = option and { outcome = 'selected', optionId = option.optionId } or { outcome = 'cancelled' } })
  end
  local handle = { cancel = function() finish() end }
  local tool = type(params) == 'table' and params.toolCall
  local options = type(params) == 'table' and params.options
  if type(params) ~= 'table' or not string(params.sessionId, 1024) or type(tool) ~= 'table'
    or not string(tool.toolCallId, 1024) or type(options) ~= 'table' or not vim.islist(options)
    or #options == 0 or #options > 16 then
    finish(); return handle
  end
  local ids = {}
  for _, option in ipairs(options) do
    if type(option) ~= 'table' or not string(option.optionId, 256) or ids[option.optionId]
      or not string(option.name, 512) or not kinds[option.kind] then
      finish(); return handle
    end
    ids[option.optionId] = true
  end
  local readonly = tool.kind == 'read' and reads[tool.name] == true
  local lines = {
    '権限要求: ' .. display(tool.title or tool.name),
    'ツール: ' .. display(tool.name) .. ' / ' .. display(tool.kind),
    '直接の編集・実行・不明な操作は許可できません。',
  }
  if type(tool.locations) == 'table' then
    for i, location in ipairs(tool.locations) do
      if i > 8 then break end
      if type(location) == 'table' and type(location.path) == 'string' then
        lines[#lines + 1] = '対象: ' .. display(location.path)
      end
    end
  end
  if type(tool.rawInput) == 'table' then
    for _, field in ipairs({ 'path', 'file_path', 'filePath', 'directory' }) do
      if type(tool.rawInput[field]) == 'string' then
        lines[#lines + 1] = '対象: ' .. display(tool.rawInput[field])
      end
    end
  end
  local keys = '123456789abcdefg'
  lines[#lines + 1] = '1-9/a-g/Enter: 選択 | q/Esc: 拒否 | x: 実行中止'
  for i, option in ipairs(options) do
    local allow = option.kind == 'allow_once' or option.kind == 'allow_always'
    lines[#lines + 1] = ('%s: %s (%s)%s'):format(keys:sub(i, i), display(option.name), option.kind,
      allow and not readonly and ' [不可: 直接操作未対応]' or '')
  end
  buf, win = require('hodocode.ui').float(lines, '権限要求')
  vim.bo[buf].filetype = 'text'
  vim.bo[buf].readonly = true
  vim.wo[win].conceallevel = 0
  local function choose(index)
    if finished then return end
    local option = options[index]
    if not option then return end
    if (option.kind == 'allow_once' or option.kind == 'allow_always') and not readonly then
      finish()
      vim.notify('HodoCode: 直接操作未対応のため権限要求を拒否しました', vim.log.levels.WARN)
      return
    end
    finish(option)
  end
  local start = #lines - #options
  for i = 1, #options do
    vim.keymap.set('n', keys:sub(i, i), function() choose(i) end, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set('n', '<CR>', function()
    if not finished then choose(vim.api.nvim_win_get_cursor(win)[1] - start) end
  end, { buffer = buf, silent = true })
  for _, key in ipairs({ 'q', '<Esc>', '<C-c>', '<C-d>' }) do
    vim.keymap.set('n', key, handle.cancel, { buffer = buf, nowait = true, silent = true })
  end
  vim.keymap.set('n', 'x', function()
    if finished then return end
    require('hodocode.agent').stop()
    handle.cancel()
  end, { buffer = buf, nowait = true, silent = true })
  close_event = vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win), once = true, callback = function() win = nil; finish() end,
  })
  wipe_event = vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf, once = true, callback = function() buf = nil; finish() end,
  })
  vim.api.nvim_win_set_cursor(win, { start + 1, 0 })
  return handle
end

return M
