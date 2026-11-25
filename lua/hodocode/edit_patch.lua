local M = {}

-- All matches refer to the original snapshot, never to another edit's output.
function M.apply(before, edits, limit)
  limit = limit or 1024 * 1024
  if type(before) ~= 'string' or type(edits) ~= 'table' or not vim.islist(edits) then
    return nil, '部分編集は配列で指定してください。'
  end
  if #edits > 256 then return nil, '部分編集は1回256件までです。範囲を絞って再依頼してください。' end
  local ranges, size = {}, #before
  for _, edit in ipairs(edits) do
    if type(edit) ~= 'table' or type(edit.old_text) ~= 'string' or type(edit.new_text) ~= 'string'
      or edit.old_text:find('\0', 1, true) or edit.new_text:find('\0', 1, true) then
      return nil, '不正な部分編集です。old_textとnew_textにはNULのない文字列が必要です。'
    end
    for key in pairs(edit) do
      if key ~= 'old_text' and key ~= 'new_text' then return nil, '部分編集で他ファイルや追加の操作は指定できません。' end
    end
    if edit.old_text == '' then
      if before ~= '' or #edits ~= 1 then return nil, '空の置換元は空バッファの単独編集だけに指定できます。' end
      if #edit.new_text > limit then return nil, '適用後のバッファがサイズ制限を超えます。' end
      return edit.new_text
    end
    local first, last = before:find(edit.old_text, 1, true)
    if not first then return nil, '置換元が一致しません。現在の内容を確認して再依頼してください。' end
    if before:find(edit.old_text, first + 1, true) then
      return nil, '置換元が複数あります。前後の文脈を含めて再依頼してください。'
    end
    size = size - #edit.old_text + #edit.new_text
    ranges[#ranges + 1] = { first = first, last = last, text = edit.new_text }
  end
  if size > limit then return nil, '適用後のバッファがサイズ制限を超えます。' end
  table.sort(ranges, function(a, b) return a.first < b.first end)
  local pieces, next_byte = {}, 1
  for _, range in ipairs(ranges) do
    if range.first < next_byte then return nil, '部分編集の範囲が重なっています。変更をまとめて再依頼してください。' end
    pieces[#pieces + 1] = before:sub(next_byte, range.first - 1)
    pieces[#pieces + 1] = range.text
    next_byte = range.last + 1
  end
  pieces[#pieces + 1] = before:sub(next_byte)
  return table.concat(pieces)
end

return M
