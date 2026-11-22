local M = {}
local prep = require('hodocode.prepare')
local ns = vim.api.nvim_create_namespace('HodoCodeExplain')
local active, records = nil, {}

local function clear(buf)
  local record = records[buf]
  records[buf] = nil
  if record and record.win and vim.api.nvim_win_is_valid(record.win) then pcall(vim.api.nvim_win_close, record.win, true) end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

function M.clear()
  for buf in pairs(records) do clear(buf) end
end

function M.stop()
  local stopped = prep.cancel(active)
  active = nil
  return stopped
end

local group = vim.api.nvim_create_augroup('HodoCodeExplain', { clear = true })
vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufWipeout', 'BufEnter', 'CursorMoved', 'CursorHold' }, {
  group = group, callback = function(event)
    local invalidating = event.event == 'TextChanged' or event.event == 'TextChangedI'
      or event.event == 'BufWritePost' or event.event == 'BufWipeout'
    if records[event.buf] and (invalidating or not records[event.buf].ctx.valid()) then clear(event.buf) end
    if active and active.ctx.buf == event.buf and (invalidating or not active.ctx.valid()) then M.stop() end
  end,
})

local function render(record)
  local buf = record.ctx.buf
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if record.hidden then return end
  for _, comment in ipairs(record.response.comments) do
    local summary = comment.text:gsub('%c', ' '):gsub('%s+', ' ')
    summary = vim.fn.strcharpart(summary, 0, 160)
    vim.api.nvim_buf_set_extmark(buf, ns, comment.line - 1, 0, {
      virt_text = { { '  🤖 ' .. summary, 'Comment' } }, virt_text_pos = 'eol',
    })
  end
end

function M.toggle()
  local buf = vim.api.nvim_get_current_buf()
  local record = records[buf]
  if not record then return false end
  if not record.ctx.valid() then clear(buf); return false end
  record.hidden = not record.hidden
  render(record)
  return true
end

function M.show()
  local buf = vim.api.nvim_get_current_buf()
  local record = records[buf]
  if not record then prep.notify('このバッファには行解説がありません'); return false end
  if not record.ctx.valid() then clear(buf); return false end
  if record.win and vim.api.nvim_win_is_valid(record.win) then vim.api.nvim_set_current_win(record.win); return true end
  local lines = { record.response.message }
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _, comment in ipairs(record.response.comments) do
    if row >= comment.line and row <= (comment.end_line or comment.line) then
      lines[#lines + 1] = '\n' .. comment.text
    end
  end
  local ok, _, win = pcall(require('hodocode.ui').float, vim.split(table.concat(lines, '\n'), '\n', { plain = true }), 'HodoCode 行解説')
  if not ok then prep.notify('Explanation popup could not open'); return false end
  record.win = win
  return true
end

local function valid_response(response, ctx)
  if type(response) ~= 'table' or response.version ~= ctx.version or type(response.message) ~= 'string'
    or type(response.comments) ~= 'table' or not vim.islist(response.comments) then return false end
  local count = ctx.start_line and ctx.end_line - ctx.start_line + 1 or ctx.count
  for _, c in ipairs(response.comments) do
    if type(c) ~= 'table' or c.file ~= ctx.file or type(c.text) ~= 'string' or c.text:find('\0', 1, true)
      or type(c.line) ~= 'number' or c.line ~= math.floor(c.line) or c.line < 1 or c.line > count
      or (c.end_line ~= nil and (type(c.end_line) ~= 'number' or c.end_line ~= math.floor(c.end_line)
        or c.end_line < c.line or c.end_line > count)) then return false end
  end
  return not response.message:find('\0', 1, true)
end

function M.run(config, prompt, row)
  if active then prep.notify('行解説は実行中です。:HodoCodeCancelで中止できます'); return false end
  if not prep.argv(config.explain_agent) then prep.notify('explain_agent にJSONアダプターのargvを設定してください'); return false end
  local ctx, err = prep.capture(config)
  if not ctx then prep.notify(err); return false end
  local state = { ctx = ctx }
  active = state
  local function finish(message)
    prep.clean_cwd(state)
    if active == state then active = nil end
    if message then prep.notify(message) end
  end
  state.on_error = function()
    clear(ctx.buf)
    finish('Explanation UI or callback failed; request cancelled')
  end
  local send = prep.guard(state, function(value)
    if state.cancelled then return end
    if not ctx.valid() or vim.api.nvim_get_current_buf() ~= ctx.buf then finish('対象バッファが変更されました'); return end
    if value == nil then finish(); return end
    if type(value) ~= 'string' then finish('prompt must be a string'); return end
    if value == '' then value = row and 'Explain this function line by line. Read-only; do not modify files.'
      or 'Explain this buffer line by line. Read-only; do not modify files.' end
    prep.run(state, config, ctx, value, function(envelope, prepare_err, encoded)
      if prepare_err then finish(prepare_err); return end
      ctx.start_line, ctx.end_line = envelope.buffer.start_line, envelope.buffer.end_line
      state.cwd = prep.tempdir()
      if not state.cwd then finish('Private explanation cwd could not be created'); return end
      -- This discourages automatic indexing, but adapters are not sandboxed.
      prep.system(state, config.explain_agent, { cwd = state.cwd, stdin = encoded, text = true,
        timeout = config.agent_timeout_ms or 120000 }, config.max_agent_bytes or 1048576, function(response, agent_err)
        finish()
        if agent_err then prep.notify(agent_err); return end
        if not ctx.valid() then prep.notify('ソースが変更されました。解説を破棄しました'); return end
        if not valid_response(response, ctx) then prep.notify('Invalid explanation response'); return end
        if ctx.start_line then
          for _, comment in ipairs(response.comments) do
            comment.line = comment.line + ctx.start_line - 1
            if comment.end_line then comment.end_line = comment.end_line + ctx.start_line - 1 end
          end
        end
        clear(ctx.buf)
        local record = { ctx = ctx, response = response }
        records[ctx.buf] = record
        render(record)
      end)
    end, row)
  end)
  if prompt == nil or prompt == '' then
    prep.guard(state, function() vim.ui.input({ prompt = 'HodoCode 行解説への指示: ' }, send) end)()
  else send(prompt) end
  return true
end

return M
