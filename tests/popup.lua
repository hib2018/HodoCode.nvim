local project
local function run()
  local plugin = vim.fn.getcwd()
  vim.opt.runtimepath:prepend(plugin)
  vim.o.lines, vim.o.columns, vim.o.hidden = 45, 140, true
  local uv = vim.uv or vim.loop
  local ui = require('hodocode.ui')
  local tree = require('hodocode.tree')
  local chat = require('hodocode.chat')
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = tostring(message) end
  local function wait(predicate, label)
    assert(vim.wait(5000, predicate, 5), label .. '\n' .. table.concat(notices, '\n'))
  end
  local function size(win, label)
    local width, height = ui.popup_size()
    assert(width == math.max(1, math.min(math.floor(vim.o.columns * 0.9), vim.o.columns - 4)), 'popup width policy')
    assert(height == math.max(1, math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - 4)), 'popup height policy')
    assert(vim.api.nvim_win_get_width(win) == width, label .. ': wrong width')
    assert(vim.api.nvim_win_get_height(win) == height, label .. ': wrong height')
    local cfg = vim.api.nvim_win_get_config(win)
    assert(not cfg.title or #cfg.title == 0, label .. ': decorative title remains')
    assert(vim.deep_equal(cfg.border, { '┌', '─', '┐', '│', '┘', '─', '└', '│' }), label .. ': not a plain border')
    assert(cfg.relative == 'editor' and cfg.col == math.max(0, math.floor((vim.o.columns - width) / 2))
      and cfg.row == math.max(0, math.floor((vim.o.lines - height) / 2) - 1), label .. ': not centered')
  end
  local events = { 'VimResized', 'WinClosed', 'BufWipeout', 'TextChanged', 'TextChangedI',
    'BufWritePost', 'BufReadPost', 'BufDelete', 'CursorMoved' }
  local function watches()
    local count = 0
    for _, watch in ipairs(vim.api.nvim_get_autocmds({ event = events })) do
      -- A hidden persistent history buffer retains exactly its own wipe watcher.
      if not (watch.group_name == 'HodoCodeConversation' and watch.event == 'BufWipeout') then count = count + 1 end
    end
    return count
  end
  project = vim.fn.tempname()
  vim.fn.mkdir(project, 'p')
  project = uv.fs_realpath(project)
  vim.cmd.edit(project .. '/unsaved.py')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local original = { 'token = "SECRET"', 'print(token)' }
  vim.api.nvim_buf_set_lines(source, 0, -1, false, original)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local baseline = watches()
  local _, short = ui.float({ 'Short explanation' }, 'Short')
  local lines = {}
  for i = 1, 200 do lines[i] = 'Long explanation ' .. i end
  local _, long = ui.float(lines, 'Long')
  size(short, 'short explanation')
  size(long, 'long explanation')

  vim.api.nvim_set_current_win(source_win)
  local pending = {}
  local client = { request = function(_, method, params, callback)
    assert(method == 'calls')
    pending[params['function']] = callback
  end }
  vim.fn.writefile({ 'def root(): pass', 'def branch(): pass', 'def leaf(): pass' }, project .. '/tree.py')
  local root = { ID = 'root', File = 'tree.py', Line = 1 }
  local branch = { ID = 'branch', File = 'tree.py', Line = 2 }
  local leaf = { ID = 'leaf', File = 'tree.py', Line = 3 }
  local ctx = { root = project, buf = source, valid = function() return true end }
  local controller = tree.open(ctx, client, root, { tree = 'native' })
  local native = controller.view.win
  size(native, 'loading native tree')
  pending.root({ calls = { { To = 'branch' } }, Targets = { branch = branch } })
  size(native, 'short native tree')
  local node = controller.state.root.children[1]
  controller:act('expand', node)
  pending.branch({ calls = { { To = 'leaf' } }, Targets = { leaf = leaf } })
  assert(vim.api.nvim_buf_line_count(controller.view.buf) == 4, 'native tree did not expand')
  size(native, 'expanded native tree')
  controller:act('collapse', controller.state.root)
  assert(vim.api.nvim_buf_line_count(controller.view.buf) == 2, 'native tree did not collapse')
  size(native, 'collapsed native tree')

  vim.api.nvim_set_current_win(source_win)
  local config = { agent = { 'python3', '-c', [[import json,sys; json.load(sys.stdin); print('{"message":"local"}')]] } }
  assert(chat.open(config))
  local history_buf, chat_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  assert(vim.bo[history_buf].buftype == 'nofile', 'chat must be native, not terminal')
  size(chat_win, 'chat')

  for _, screen in ipairs({ { 100, 32 }, { 160, 50 } }) do
    vim.o.columns, vim.o.lines = screen[1], screen[2]
    vim.api.nvim_exec_autocmds('VimResized', {})
    wait(function()
      local width, height = ui.popup_size()
      for _, win in ipairs({ short, long, native, chat_win }) do
        if vim.api.nvim_win_get_width(win) ~= width or vim.api.nvim_win_get_height(win) ~= height then return false end
      end
      return true
    end, 'all popup renderers follow resize')
    for label, win in pairs({ short = short, long = long, native = native, chat = chat_win }) do size(win, label .. ' resized') end
    assert(vim.api.nvim_buf_is_valid(history_buf), 'resizing deleted persistent history')
  end
  chat.hide()
  assert(vim.api.nvim_buf_is_valid(history_buf), 'hide must retain history buffer')
  assert(#vim.api.nvim_get_autocmds({ buffer = history_buf, event = 'BufWipeout' }) == 1, 'persistent history watcher leaked')
  assert(not require('hodocode.session').get().request, 'opening chat must not launch an adapter')
  controller:close()
  vim.api.nvim_win_close(short, true)
  vim.api.nvim_win_close(long, true)
  wait(function() return watches() == baseline end, 'closed popups leaked autocommands')

  vim.api.nvim_set_current_win(source_win)
  local valid = true
  local _, guarded = ui.float({ 'Frozen explanation' }, 'Context', { buf = source, valid = function() return valid end })
  vim.o.columns, vim.o.lines = 90, 30
  vim.api.nvim_exec_autocmds('VimResized', {})
  size(guarded, 'context popup resized')
  valid = false
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(not vim.api.nvim_win_is_valid(guarded), 'resize lost source invalidation guard')
  wait(function() return watches() == baseline end, 'context popup leaked autocommands')

  for _, screen in ipairs({ { 20, 8 }, { 12, 4 } }) do
    vim.o.columns, vim.o.lines = screen[1], screen[2]
    local _, tiny = ui.float({ 'tiny' }, 'Tiny')
    size(tiny, 'tiny popup')
    assert(vim.api.nvim_win_get_width(tiny) >= 1 and vim.api.nvim_win_get_height(tiny) >= 1)
    vim.api.nvim_exec_autocmds('VimResized', {})
    size(tiny, 'tiny popup resized')
    vim.api.nvim_win_close(tiny, true)
    assert(watches() == baseline, 'tiny popup leaked autocommands')
  end
  assert(vim.api.nvim_buf_get_changedtick(source) == tick and vim.deep_equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), original),
    'popup lifecycle changed source')
  assert(not uv.fs_stat(project .. '/unsaved.py'), 'popup lifecycle wrote unsaved source')
  tree.clear()
  print('PASS: unified short/long/native/chat popup sizes, expansion/collapse, resize, tiny screens, context and autocmd cleanup; native persistent chat only, no AI/network')
end
local ok, err = xpcall(run, debug.traceback)
if package.loaded['hodocode.chat'] then pcall(require('hodocode.chat').shutdown) end
if project then vim.fn.delete(project, 'rf') end
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
