local M = {}
local ns = vim.api.nvim_create_namespace('HodoCodeAgentChanges')

function M.set(buf, before, after)
  local group = vim.api.nvim_create_augroup('HodoCodeAgentChanges' .. buf, { clear = true })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count, marked, positions = 0, {}, {}
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local function clamp(row) return math.max(0, math.min(last, row)) end
  local function mark(row, label)
    row = clamp(row)
    if marked[row] or count >= 1000 then return end
    marked[row], count = true, count + 1
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = { { '  🤖 ' .. label, 'DiagnosticInfo' } }, virt_text_pos = 'eol',
    })
  end
  -- Bound decoration cost on large rewrites; d always shows the full saved diff.
  for _, hunk in ipairs(vim.diff(before, after, { result_type = 'indices', algorithm = 'histogram' })) do
    positions[#positions + 1] = clamp(hunk[4] == 0 and hunk[3] or hunk[3] - 1) + 1
    if hunk[4] == 0 then mark(hunk[3], 'AI削除: ' .. hunk[2] .. '行')
    else
      for row = hunk[3] - 1, hunk[3] + hunk[4] - 2 do
        if count >= 1000 then break end
        mark(row, 'AI変更')
      end
    end
  end
  if count == 0 and before ~= after then
    mark(last, 'AI変更（末尾改行）')
    positions[#positions + 1] = last + 1
  end
  if count == 1000 then vim.notify('HodoCode: 変更マーカーは最大1000行です。全差分はdで確認できます。') end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost', 'BufFilePost', 'BufWipeout' }, {
    group = group, buffer = buf, callback = function(event)
      if event.event == 'TextChanged' or event.event == 'TextChangedI' then
        if vim.api.nvim_buf_get_changedtick(buf) == tick then return end
      end
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  return positions
end

return M
