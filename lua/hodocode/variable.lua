local M = {}
local active

function M.cancel()
  local state = active
  if not state then return end
  state.cancelled = true
  state.cleanup()
  active = nil
  if vim.api.nvim_win_is_valid(state.win) then vim.api.nvim_win_close(state.win, true) end
end

-- Only reads adapter-provided local/argument values; never evaluates expressions.
function M.attach(ctx, variable, buf, win)
  local state = { win = win }
  active = state
  local removals = {}
  function state.cleanup()
    if state.timer then state.timer:stop(); state.timer:close(); state.timer = nil end
    for _, remove in ipairs(removals) do remove() end
    removals = {}
  end
  local base = vim.api.nvim_buf_line_count(buf)
  local function valid()
    return active == state and not state.cancelled and ctx.valid()
      and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf
  end
  local function render(message)
    if not valid() then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, base, -1, false,
      vim.split('\n## 実行時の値（選択中の停止フレーム）\n' .. message, '\n', { plain = true }))
    vim.bo[buf].modifiable = false
  end
  local function finish(message)
    if state.done then return end
    state.done = true
    render(message)
  end
  vim.api.nvim_create_autocmd('WinClosed', { pattern = tostring(win), once = true, callback = function()
    state.cancelled = true
    state.cleanup()
    if active == state then active = nil end
  end })
  if variable.runtime_safe ~= true or not vim.tbl_contains({ 'ローカル変数', 'パラメータ', '戻り値' }, variable.kind)
    or type(variable.name) ~= 'string' or variable.name == '' then
    finish('不明: この変数は安全なローカル変数・引数の取得対象ではありません。'); return
  end
  local ok, dap = pcall(require, 'dap')
  if not ok then finish('不明: nvim-dap がありません（静的情報のみ）。'); return end
  local session = dap.session()
  if not session or not session.stopped_thread_id or not session.current_frame or not session.current_frame.id then
    finish('不明: デバッグセッションが停止していません。'); return
  end
  local frame, thread = session.current_frame, session.stopped_thread_id
  local frame_id, frame_line = frame.id, frame.line
  local frame_path = type(frame.source) == 'table' and frame.source.path
  local function same_frame()
    return not state.invalidated and valid() and dap.session() == session and session.stopped_thread_id == thread
      and session.current_frame == frame and session.current_frame.id == frame_id and frame.line == frame_line
      and type(frame.source) == 'table' and frame.source.path == frame_path
  end
  local path = frame_path
  if type(path) ~= 'string' or path:find('\0', 1, true) or (vim.uv or vim.loop).fs_realpath(path) ~= ctx.path
    or variable.function_file ~= ctx.file or type(variable.function_start_line) ~= 'number'
    or type(variable.function_end_line) ~= 'number' or type(frame.line) ~= 'number'
    or frame.line < variable.function_start_line or frame.line > variable.function_end_line then
    finish('不明: 選択中の停止フレームが対象ファイル・関数の範囲外です。同じ変数の束縛を確認できません。'); return
  end
  local label = string.format('選択中の停止フレーム: %s:%d / %s / id=%s', path, frame.line, frame.name or '?', tostring(frame_id))
  if frame.line ~= ctx.row + 1 then label = label .. '\nカーソル行の値ではありません。' end
  label = label .. '\nデバッグバイナリと保存済みソースの一致は未検証です。'
  local function invalidate()
    if state.invalidated then return end
    state.invalidated, state.done = true, true
    state.cleanup()
    render('不明: 実行再開・停止フレーム変更で値は無効です。再実行してください。')
  end
  if dap.listeners and dap.listeners.after then
    for _, event in ipairs({ 'event_continued', 'event_stopped', 'event_terminated', 'event_exited' }) do
      local listeners = dap.listeners.after[event]
      if listeners then
        listeners[state] = function(changed)
          if changed == session then
            state.done = true
            vim.schedule(invalidate)
          end
        end
        removals[#removals + 1] = function() listeners[state] = nil end
      end
    end
  end
  render('取得中…')
  state.timer = (vim.uv or vim.loop).new_timer()
  local started = (vim.uv or vim.loop).hrtime()
  state.timer:start(100, 100, vim.schedule_wrap(function()
    if not valid() then state.cleanup(); return end
    if not same_frame() then invalidate(); return end
    if not state.done and ((vim.uv or vim.loop).hrtime() - started) / 1e6 >= 3000 then
      finish('不明: デバッガーの応答がタイムアウトしました。')
    end
  end))
  local function request(command, args, callback)
    local success = pcall(session.request, session, command, args, function(err, response)
      vim.schedule(function()
        if state.done or not same_frame() then return end
        if err then finish('不明: デバッガーの取得エラー。'); return end
        callback(response)
      end)
    end)
    if not success then finish('不明: デバッガーへの要求に失敗しました。') end
  end
  request('scopes', { frameId = frame.id }, function(response)
    if type(response) ~= 'table' or type(response.scopes) ~= 'table' then
      finish('不明: デバッガーのスコープ応答が不正です。'); return
    end
    local scopes = {}
    for _, scope in ipairs(response.scopes) do
      if type(scope) ~= 'table' then finish('不明: デバッガーのスコープ応答が不正です。'); return end
      local name = type(scope.name) == 'string' and scope.name:lower() or ''
      if not scope.expensive and (scope.presentationHint == 'locals' or scope.presentationHint == 'arguments'
        or name == 'locals' or name == 'local' or name == 'arguments' or name == 'args' or name == 'parameters')
        and type(scope.variablesReference) == 'number' and scope.variablesReference > 0 then
        scopes[#scopes + 1] = scope
      end
    end
    if #scopes == 0 then finish('不明: ローカル変数・引数のスコープがありません。'); return end
    local remaining, matches = #scopes, {}
    for _, scope in ipairs(scopes) do
      if state.done then break end
      request('variables', { variablesReference = scope.variablesReference }, function(result)
        if type(result) ~= 'table' or type(result.variables) ~= 'table' then
          finish('不明: デバッガーの変数応答が不正です。'); return
        end
        for _, value in ipairs(result.variables) do
          if type(value) ~= 'table' then finish('不明: デバッガーの変数応答が不正です。'); return end
          if value.name == variable.name then matches[#matches + 1] = value end
        end
        remaining = remaining - 1
        if remaining ~= 0 then return end
        if #matches == 0 then finish('不明: 完全一致する変数がありません。')
        elseif #matches ~= 1 then finish('不明: 同名変数が複数あり、シャドーイングを判別できません。')
        elseif type(matches[1].value) ~= 'string' or matches[1].value:find('\0', 1, true) then finish('不明: 値が不正またはありません。')
        else finish(label .. '\n\n' .. variable.name .. ' = ' .. matches[1].value .. '\n\n停止フレームの値です。子要素の展開・式の評価は行いません。') end
      end)
    end
  end)
end

return M
