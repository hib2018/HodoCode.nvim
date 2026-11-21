local M = {}
local ui = require('hodocode.ui')
local active, snapshots = nil, {}

local function disk(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('*a')
  f:close()
  return text
end

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. (vim.bo[buf].endofline and '\n' or '')
end

local function error_message(message)
  vim.notify('HodoCode: ' .. message, vim.log.levels.ERROR)
end

function M.stop()
  if not active then return end
  local state = active
  active = nil
  state.cancelled = true
  if state.process then state.process:kill(15) end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { 'エージェント要求を中止しました。' })
    vim.bo[state.buf].modifiable = false
  end
end

function M.run(config, prompt)
  if active then error_message('エージェントは実行中です。:HodoCodeCancelで中止できます'); return end
  if type(config.agent) ~= 'table' or #config.agent == 0 then
    error_message('AI接続先が未設定です。setup({ agent = { 実行ファイル, 引数... } })でJSONアダプターを指定してください')
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].buftype ~= '' or path == '' or not vim.bo[buf].modifiable then
    error_message('編集可能な通常のファイルバッファで実行してください'); return
  end
  if not prompt or prompt == '' then
    vim.ui.input({ prompt = 'HodoCode エージェントへの指示: ' }, function(value)
      if value and value ~= '' then
        if vim.api.nvim_get_current_buf() ~= buf then error_message('対象バッファが切り替わりました。再実行してください'); return end
        M.run(config, value)
      end
    end)
    return
  end
  local before = text(buf)
  local payload = vim.json.encode({ prompt = prompt, buffer = {
    path = path, content = before, modified = vim.bo[buf].modified,
    filetype = vim.bo[buf].filetype, cursor = vim.api.nvim_win_get_cursor(0),
  } })
  if #payload > config.max_agent_bytes then error_message('送信サイズ制限を超えています'); return end
  local tick, saved = vim.api.nvim_buf_get_changedtick(buf), disk(path)
  local endofline = vim.bo[buf].endofline
  local output_buf = ui.float({ '# エージェント', '', '実行中…' }, 'HodoCode エージェント')
  local state = { output = '', stderr = '', cancelled = false, buf = output_buf }
  active = state
  local function stream(field)
    return function(err, chunk)
      if err then state.failure = tostring(err) end
      if chunk then
        state[field] = state[field] .. chunk
        if #state[field] > config.max_agent_bytes then
          state[field] = state[field]:sub(1, config.max_agent_bytes)
          state.failure = 'エージェント出力がサイズ制限を超えています'
          if state.process then state.process:kill(15) end
        end
      end
    end
  end
  local ok, process = pcall(vim.system, config.agent, {
    cwd = vim.fs.dirname(path), stdin = payload .. '\n', text = true,
    timeout = config.agent_timeout_ms, stdout = stream('output'), stderr = stream('stderr'),
  }, vim.schedule_wrap(function(result)
    if active == state then active = nil end
    if state.cancelled then return end
    local function render(lines)
      if vim.api.nvim_buf_is_valid(output_buf) then
        vim.bo[output_buf].modifiable = true
        vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, lines)
        vim.bo[output_buf].modifiable = false
      end
    end
    if state.failure or result.code ~= 0 then
      local message = state.failure or ('agent exited (' .. result.code .. '): ' .. state.stderr)
      render(vim.split(message, '\n', { plain = true })); error_message(message); return
    end
    local decoded, response = pcall(vim.json.decode, state.output)
    if not decoded or type(response) ~= 'table' or type(response.message) ~= 'string'
      or (response.content ~= nil and type(response.content) ~= 'string') then
      render({ '不正なエージェント応答です。messageと任意のcontentを含むJSONが必要です。' }); return
    end
    local lines = vim.split(response.message, '\n', { plain = true })
    if response.content ~= nil then
      if response.content:find('\0', 1, true) then render({ 'NULを含む変更は適用できません' }); return end
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_name(buf) ~= path
        or not vim.bo[buf].modifiable or vim.bo[buf].endofline ~= endofline
        or vim.api.nvim_buf_get_changedtick(buf) ~= tick or disk(path) ~= saved then
        lines[#lines + 1] = '競合: 実行中にバッファまたはファイルが変更されたため、変更を適用していません。'
      else
        if not snapshots[buf] then
          vim.api.nvim_create_autocmd('BufWipeout', { buffer = buf, once = true, callback = function() snapshots[buf] = nil end })
        end
        snapshots[buf] = { content = before, endofline = vim.bo[buf].endofline, filetype = vim.bo[buf].filetype }
        local replacement = vim.split(response.content, '\n', { plain = true })
        local eol = response.content:sub(-1) == '\n'
        if eol then table.remove(replacement) end
        if #replacement == 0 then replacement = { '' } end
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, replacement)
        vim.bo[buf].endofline = eol
        lines[#lines + 1] = 'バッファへ反映しました（未保存）。qでソースに戻り、:HodoCodeDiffで変更前との差分を確認できます。'
      end
    end
    render(lines)
  end))
  if not ok then active = nil; error_message(tostring(process)); return end
  state.process = process
  if state.failure then process:kill(15) end
end

function M.diff()
  local buf = vim.api.nvim_get_current_buf()
  local snapshot = snapshots[buf]
  if not snapshot then error_message('このバッファにエージェント変更前の記録はありません'); return end
  local before = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(snapshot.content, '\n', { plain = true })
  if snapshot.endofline then table.remove(lines) end
  if #lines == 0 then lines = { '' } end
  vim.api.nvim_buf_set_lines(before, 0, -1, false, lines)
  vim.bo[before].filetype = snapshot.filetype
  vim.bo[before].endofline = snapshot.endofline
  vim.bo[before].bufhidden = 'wipe'
  vim.bo[before].modifiable = false
  vim.cmd.tabnew()
  vim.api.nvim_win_set_buf(0, before)
  vim.cmd.diffthis()
  vim.cmd.vsplit()
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd.diffthis()
end

return M
