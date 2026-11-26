local M = {}
local ns = vim.api.nvim_create_namespace('HodoCodeInlineDiff')
local states = {}
local group = vim.api.nvim_create_augroup('HodoCodeInlineDiff', { clear = true })

-- Diff the body independently of file metadata so EOF changes cannot shift hunks.
local function body(snapshot)
  local lines = snapshot.lines
  if #lines == 0 or (#lines == 1 and lines[1] == '' and not snapshot.endofline) then return '' end
  return table.concat(lines, '\n') .. '\n'
end

local function render(buf, state)
  if not state.visible or not vim.api.nvim_buf_is_loaded(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local old = state.baseline
  local current = {
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    endofline = vim.bo[buf].endofline, fileformat = vim.bo[buf].fileformat, bomb = vim.bo[buf].bomb,
  }
  local last = #current.lines - 1
  local function deleted(row, lines, above)
    vim.api.nvim_buf_set_extmark(buf, ns, math.max(0, math.min(last, row)), 0, {
      virt_lines = lines, virt_lines_above = above or false,
    })
  end
  for _, hunk in ipairs(vim.diff(body(old), body(current), { result_type = 'indices', algorithm = 'histogram' })) do
    local old_start, old_count, new_start, new_count = unpack(hunk)
    if new_count == 0 then
      local lines = {}
      for i = 0, old_count - 1 do lines[#lines + 1] = { { '- ' .. old.lines[old_start + i], 'DiffDelete' } } end
      deleted(new_start - 1, lines, new_start == 0)
    else
      for i = 0, new_count - 1 do
        local row = new_start + i - 1
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
          end_row = row + 1, end_col = 0, hl_eol = true,
          hl_group = old_count == 0 and 'DiffAdd' or 'DiffChange',
        })
        if i < old_count then
          local lines = { { { '- ' .. old.lines[old_start + i], 'DiffDelete' } } }
          if i == new_count - 1 then
            for j = i + 1, old_count - 1 do
              lines[#lines + 1] = { { '- ' .. old.lines[old_start + j], 'DiffDelete' } }
            end
          end
          deleted(row, lines)
        end
      end
    end
  end
  local hints = {}
  if old.endofline ~= current.endofline then
    hints[#hints + 1] = { { (old.endofline and '- 末尾改行あり' or '- 末尾改行なし'), 'DiffText' } }
    hints[#hints + 1] = { { (current.endofline and '+ 末尾改行あり' or '+ 末尾改行なし'), 'DiffText' } }
  end
  if old.fileformat ~= current.fileformat then
    hints[#hints + 1] = { { '- fileformat: ' .. tostring(old.fileformat), 'DiffText' } }
    hints[#hints + 1] = { { '+ fileformat: ' .. current.fileformat, 'DiffText' } }
  end
  if old.bomb ~= current.bomb then
    hints[#hints + 1] = { { (current.bomb and '+ BOM' or '- BOM'), 'DiffText' } }
  end
  if #hints > 0 then deleted(last, hints) end
end

local function queue(buf, state)
  if not state.visible or state.pending then return end
  state.pending = true
  local generation = state.generation
  vim.schedule(function()
    if states[buf] ~= state or state.generation ~= generation then return end
    state.pending = false
    if vim.api.nvim_buf_is_valid(buf) then render(buf, state) end
  end)
end

local function ensure(buf)
  if states[buf] then return states[buf] end
  local state = { visible = false, generation = 0 }
  states[buf] = state
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function() queue(buf, state) end,
    on_reload = function() queue(buf, state) end,
    on_detach = function() if states[buf] == state then states[buf] = nil end end,
  })
  return state
end

function M.visible(buf)
  return states[buf] ~= nil and states[buf].visible
end

function M.clear(buf)
  local state = states[buf]
  if state then
    state.visible, state.baseline, state.pending = false, nil, false
    state.generation = state.generation + 1
  end
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
end

function M.toggle(buf, provider)
  if M.visible(buf) then M.clear(buf); return false end
  if not vim.api.nvim_buf_is_loaded(buf) then return false end
  local baseline, err = provider(buf)
  if not baseline then
    vim.notify('HodoCode: ' .. tostring(err or '差分の基準を取得できません'), vim.log.levels.ERROR)
    return false
  end
  local state = ensure(buf)
  state.baseline, state.visible = vim.deepcopy(baseline), true
  render(buf, state)
  return true
end

function M.refresh(buf, baseline)
  local state = states[buf]
  if not state or not state.visible then return end
  if baseline then state.baseline = vim.deepcopy(baseline) end
  render(buf, state)
end

function M.shutdown()
  for buf in pairs(states) do M.clear(buf) end
end

vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufFilePost' }, {
  group = group, callback = function(event)
    M.clear(event.buf)
    if event.event == 'BufWipeout' then states[event.buf] = nil end
  end,
})
vim.api.nvim_create_autocmd('OptionSet', {
  group = group, pattern = { 'endofline', 'fileformat', 'bomb' },
  callback = function()
    local buf = vim.api.nvim_get_current_buf()
    if states[buf] then queue(buf, states[buf]) end
  end,
})

return M
