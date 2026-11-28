local M = {}
local view = { config = {} }
local group
local return_mark
local links_ns = vim.api.nvim_create_namespace('HodoCodeChatLinks')
local ui = require('hodocode.ui')

local function valid_source(target)
  return target and target.buf and vim.api.nvim_buf_is_valid(target.buf)
    and vim.bo[target.buf].buftype == ''
end

local function capture()
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  if vim.bo[buf].buftype == '' and vim.api.nvim_win_get_config(win).relative == '' then
    return { buf = buf, win = win, cursor = vim.api.nvim_win_get_cursor(win) }
  end
end

function M.source()
  if not valid_source(view.source) then return nil end
  local source = vim.deepcopy(view.source)
  if source.win and vim.api.nvim_win_is_valid(source.win)
    and vim.api.nvim_win_get_buf(source.win) == source.buf then
    source.cursor = vim.api.nvim_win_get_cursor(source.win)
  end
  return source
end

function M.is_view(buf)
  return view.buf ~= nil and view.buf == buf
end

function M.visible()
  return view.win ~= nil and vim.api.nvim_win_is_valid(view.win)
end

function M.hide(keep_return)
  if not keep_return then return_mark = nil end
  local win = view.win
  local focused = M.visible() and vim.api.nvim_get_current_win() == win
  if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  view.win = nil
  local source = M.source()
  if focused and source and source.win and vim.api.nvim_win_is_valid(source.win)
    and vim.api.nvim_win_get_buf(source.win) == source.buf then
    vim.api.nvim_set_current_win(source.win)
  end
  return win ~= nil
end
M.stop = M.hide

local function append(lines, text)
  for _, line in ipairs(vim.split(tostring(text or ''), '\n', { plain = true })) do
    lines[#lines + 1] = line
  end
end

local quiet = { sent = true, nochange = true, done = true, completed = true, idle = true }
local fields = { 'role', 'intent', 'file', 'content', 'message', 'outcome', 'status' }

local function history_body(history)
  local cached = view.history_cache or {}
  local changed = view.history ~= history or #cached ~= #history
  for i, entry in ipairs(history) do
    local previous = cached[i]
    local dirty = not previous
      or previous.root ~= entry.root or previous.references ~= entry.references
      or previous.changes ~= entry.changes
    for _, field in ipairs(fields) do
      if not previous or previous[field] ~= entry[field] then dirty = true end
    end
    if dirty then
      changed = true
      local lines = { '**' .. (entry.role == 'user' and 'あなた' or 'アシスタント') .. '**' }
      if entry.intent or entry.file then
        local intent = entry.intent == 'edit' and '編集依頼' or entry.intent == 'chat' and '質問' or nil
        lines[#lines + 1] = table.concat(vim.tbl_filter(function(value) return value ~= '' end,
          { intent or '', entry.file and ('対象: ' .. entry.file) or '' }), ' | ')
      end
      append(lines, entry.content or entry.message)
      if entry.role == 'assistant' then
        for _, change in ipairs(entry.changes or {}) do
          lines[#lines + 1] = '変更箇所: `' .. change.path .. ':' .. change.line .. '`'
        end
      end
      local outcome = entry.outcome or entry.status
      if outcome and not quiet[outcome] then lines[#lines + 1] = '[' .. ui.label(outcome) .. ']' end
      previous = { lines = lines, root = entry.root, references = entry.references, changes = entry.changes }
      previous.links = entry.role == 'assistant' and entry.root
        and require('hodocode.chat_links').scan(lines, entry.root, entry.references) or {}
      for _, field in ipairs(fields) do previous[field] = entry[field] end
      cached[i] = previous
    end
  end
  for i = #cached, #history + 1, -1 do cached[i] = nil end
  if changed or not view.body then
    local lines, links = {}, {}
    for _, entry in ipairs(cached) do
      if #lines > 0 then lines[#lines + 1] = '' end
      for _, link in ipairs(entry.links) do
        links[#links + 1] = { link = link, row = #lines + link.row }
      end
      vim.list_extend(lines, entry.lines)
    end
    view.body, view.body_links = lines, links
  end
  view.history, view.history_cache = history, cached
  return view.body
end

local function latest()
  vim.api.nvim_win_call(view.win, function()
    vim.cmd('normal! G$zb')
  end)
end

function M.render(force)
  if return_mark and return_mark.session ~= require('hodocode.session').get() then return_mark = nil end
  if not view.buf or not vim.api.nvim_buf_is_valid(view.buf) or (force ~= true and not M.visible()) then return end
  local session = require('hodocode.session').get()
  local body = history_body(session.history or {})
  local missing_agent = type(view.config.agent) ~= 'table' or #view.config.agent == 0
  local base = view.base
  local redecorate = not view.painted or view.base_body ~= body or view.missing_agent ~= missing_agent
  if not base or view.base_body ~= body or view.missing_agent ~= missing_agent then
    base = {}
    if missing_agent then
      base[#base + 1] = '設定: 質問・編集依頼には `agent` にコマンドと引数を設定してください。'
      base[#base + 1] = ''
    end
    vim.list_extend(base, body)
    if #body == 0 then base[#base + 1] = 'Enter: 質問 / A: 編集依頼 / ?: ヘルプ' end
  end
  local lines = {}
  local request = session.request
  if request and type(request.stream) == 'string' and request.stream ~= '' then
    lines[#lines + 1] = ''
    lines[#lines + 1] = '**アシスタント（受信中・未確定）**'
    if request.intent == 'edit' then lines[#lines + 1] = '```json' end
    append(lines, request.stream)
    if request.intent == 'edit' then lines[#lines + 1] = '```' end
  end
  if request and type(request.tool) == 'table' then
    local tool = request.tool
    local function compact(value)
      return type(value) == 'string' and value:sub(1, 160):gsub('[%c]', ' ') or ''
    end
    if tool.sessionUpdate == 'notice' then
      lines[#lines + 1] = '通知を受信'
    else
      lines[#lines + 1] = 'ツール: ' .. compact(tool.title or tool.kind) .. ' / ' .. ui.label(tool.status)
    end
  end
  local status = request and require('hodocode.agent').status(request.source) or session.last_status
  local phase = type(status) == 'table' and status.phase or status or (request and request.phase)
  if phase and not quiet[phase] then
    lines[#lines + 1] = ''
    if type(status) == 'table' then
      lines[#lines + 1] = ('状態: %s（経過 %.0f秒）%s'):format(ui.label(phase),
        (status.elapsed_ms or 0) / 1000, status.code and (' [' .. ui.label(status.code) .. ']') or '')
    else
      lines[#lines + 1] = '状態: ' .. (ui.label(phase))
    end
  end
  local footer = lines
  local offset = 0
  local old
  if base == view.base and view.painted then
    old, offset = view.footer, #base
  else
    old = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
    lines = vim.list_extend(vim.list_extend({}, base), footer)
  end
  view.base, view.base_body, view.missing_agent, view.footer = base, body, missing_agent, footer
  local prefix = 0
  while prefix < #old and prefix < #lines and old[prefix + 1] == lines[prefix + 1] do prefix = prefix + 1 end
  local unchanged = prefix == #old and prefix == #lines
  if unchanged and not redecorate then return end
  local suffix = 0
  while suffix < #old - prefix and suffix < #lines - prefix
    and old[#old - suffix] == lines[#lines - suffix] do suffix = suffix + 1 end
  local saved, tail
  if M.visible() then
    vim.api.nvim_win_call(view.win, function()
      saved = vim.fn.winsaveview()
      tail = vim.fn.line('w$') == vim.api.nvim_buf_line_count(view.buf)
    end)
  end
  local replacement = {}
  for i = prefix + 1, #lines - suffix do replacement[#replacement + 1] = lines[i] end
  vim.bo[view.buf].readonly, vim.bo[view.buf].modifiable = false, true
  if not unchanged then
    vim.api.nvim_buf_set_lines(view.buf, offset + prefix, offset + #old - suffix, false, replacement)
  end
  vim.bo[view.buf].readonly, vim.bo[view.buf].modifiable = true, false
  vim.bo[view.buf].modified = false
  view.painted = true
  if redecorate then
    vim.api.nvim_buf_clear_namespace(view.buf, links_ns, 0, -1)
    view.links = {}
    for _, mapped in ipairs(view.body_links or {}) do
      local link = mapped.link
      local row = mapped.row + (missing_agent and 2 or 0)
      local col = link.col
      local finish = link.end_col
      view.links[#view.links + 1] = { row = row, col = col, finish = finish, link = link }
      vim.api.nvim_buf_set_extmark(view.buf, links_ns, row - 1, col,
        { end_col = finish, hl_group = 'HodoCodeChatLink', strict = false })
    end
  end
  if saved then
    if tail then latest() else vim.api.nvim_win_call(view.win, function() vim.fn.winrestview(saved) end) end
  end
end

local function compose(intent)
  require('hodocode.edit_prompt').open(function(prompt)
    local target = M.source()
    if not target then
      vim.notify('HodoCode: 有効なソースバッファがありません', vim.log.levels.ERROR)
      return
    end
    require('hodocode.agent').run(view.config, prompt, intent, target)
  end)
end

local function normal_window(win)
  return win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ''
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
end

local function jump_link()
  local cursor = vim.api.nvim_win_get_cursor(view.win)
  local selected
  for _, item in ipairs(view.links or {}) do
    if item.row == cursor[1] and cursor[2] >= item.col and cursor[2] < item.finish then
      selected = item.link
      break
    end
  end
  if not selected then compose('chat'); return end
  local saved = vim.fn.winsaveview()
  local chat_win = view.win
  local ok, err = pcall(function()
    local mode = require('hodocode.mode')
    local active = mode.active()
    local dest, reason = require('hodocode.chat_links').resolve(selected)
    if not dest then error(reason, 0) end
    local win = view.source and view.source.win
    if not normal_window(win) then
      win = nil
      for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if normal_window(candidate) then win = candidate; break end
      end
    end
    if not win then error('移動先の編集ウィンドウがありません', 0) end
    local old = vim.api.nvim_win_get_buf(win)
    local old_cursor = vim.api.nvim_win_get_cursor(win)
    if old ~= dest.buf and vim.bo[old].modified
      and ({ wipe = true, delete = true, unload = true })[vim.bo[old].bufhidden] then
      error('未保存バッファを保持できないため移動できません', 0)
    end
    -- :hide preserves unsaved buffers even when 'hidden' is disabled.
    local switched, switch_err = pcall(function()
      vim.api.nvim_win_call(win, function() vim.cmd('hide buffer ' .. dest.buf) end)
      vim.api.nvim_win_set_cursor(win, { dest.row, 0 })
    end)
    if not switched then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd('hide buffer ' .. old)
        vim.api.nvim_win_set_cursor(win, old_cursor)
      end)
      error(switch_err, 0)
    end
    return_mark = { session = require('hodocode.session').get(), chat_buf = view.buf,
      view = saved, destPath = dest.path, root = selected.root }
    vim.api.nvim_set_current_win(win)
    if active then mode.start() end
    M.hide(true)
    vim.api.nvim_set_current_win(win)
  end)
  if not ok then
    return_mark = nil
    if vim.api.nvim_win_is_valid(chat_win) then
      view.win = chat_win
      vim.api.nvim_set_current_win(chat_win)
      vim.fn.winrestview(saved)
    end
    vim.notify('HodoCode: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

local function returning(source, target)
  local mark = return_mark
  return_mark = nil
  if target or not mark or mark.session ~= require('hodocode.session').get()
    or mark.chat_buf ~= view.buf or not vim.api.nvim_buf_is_valid(mark.chat_buf)
    or not valid_source(source) then return nil end
  local uv = vim.uv or vim.loop
  local path = uv.fs_realpath(vim.api.nvim_buf_get_name(source.buf))
  local root = mark.root
  if path and (path == mark.destPath or (type(root) == 'string'
    and (path == root or path:sub(1, #root + 1) == root .. '/' or root == '/'))) then
    return mark.view
  end
end

local function setup()
  if group then return end
  vim.api.nvim_set_hl(0, 'HodoCodeChatLink', { underline = true })
  group = vim.api.nvim_create_augroup('HodoCodeConversation', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group, pattern = 'HodoCodeSessionChanged', callback = M.render,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = M.shutdown })
end

function M.configure(config)
  view.config = config or {}
  M.render()
end

function M.open(config, target)
  setup()
  local selected = config or view.config
  local source = target or capture() or M.source()
  local restore = returning(source, target)
  if selected.agent_transport == 'acp' and not restore then
    if not valid_source(source) then
      vim.notify('HodoCode: 有効なソースバッファがありません', vim.log.levels.ERROR)
      return false
    end
    local session, reason = require('hodocode.session').activate(selected, source.buf)
    if not session then
      vim.notify('HodoCode: ' .. (reason == 'busy'
        and 'エージェントは実行中です。:HodoCodeCancelで中止できます'
        or 'プロジェクトを選択できません: ' .. tostring(reason)), vim.log.levels.INFO)
      return false
    end
  end
  if config then M.configure(config) end
  if valid_source(source) then view.source = vim.deepcopy(source) end
  if not view.buf or not vim.api.nvim_buf_is_valid(view.buf) then
    view.buf = vim.api.nvim_create_buf(false, true)
    local buf = view.buf
    view.painted = nil
    vim.bo[buf].bufhidden = 'hide'
    require('hodocode.ui').markdown(buf)
    vim.bo[buf].swapfile, vim.bo[buf].readonly, vim.bo[buf].undolevels = false, true, -1
    for _, key in ipairs({ 'q', '<Esc>', '<C-c>', '<C-d>' }) do
      vim.keymap.set('n', key, function()
        M.hide()
        if key == '<C-c>' or key == '<C-d>' then require('hodocode.mode').stop() end
      end, { buffer = buf, nowait = true, silent = true })
    end
    vim.keymap.set('n', '<CR>', jump_link, { buffer = buf, silent = true })
    vim.keymap.set('n', 'i', function() compose('chat') end, { buffer = buf, silent = true })
    vim.keymap.set('n', 'A', function() compose('edit') end, { buffer = buf, silent = true })
    vim.keymap.set('n', '?', function()
      require('hodocode.ui').float({
        'Enter/i: 質問（読み取り専用） | A: 編集依頼',
        'x: 実行中の依頼を中止 | Esc/q: 会話を隠す',
        '入力: Ctrl-s/Ctrl-Enterで送信',
        '質問への回答は送信時点のコードに基づきます（送信後の変更は含みません）。',
      }, 'ヘルプ')
    end, { buffer = buf, silent = true })
    vim.keymap.set('n', 'x', function() require('hodocode').cancel() end, { buffer = buf, silent = true })
    vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = buf, once = true, callback = function()
      if view.buf == buf then view.buf = nil; view.win = nil; return_mark = nil end
    end })
  end
  M.render(true)
  if M.visible() then
    vim.api.nvim_set_current_win(view.win)
  else
    local win = require('hodocode.ui').open_popup(view.buf, 'HodoCode 会話')
    view.win = win
    vim.wo[win].wrap = true
    vim.api.nvim_create_autocmd('WinClosed', {
      group = group, pattern = tostring(win), once = true, callback = function()
        if view.win == win then view.win = nil end
      end,
    })
  end
  if restore then
    vim.api.nvim_win_call(view.win, function() vim.fn.winrestview(restore) end)
  else
    latest()
  end
  return true
end

function M.shutdown()
  M.hide()
  if view.buf and vim.api.nvim_buf_is_valid(view.buf) then
    vim.api.nvim_buf_delete(view.buf, { force = true })
  end
  view = { config = {} }
  if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
end

return M
