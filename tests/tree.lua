local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.lines, vim.o.columns = 40, 120
  local tree = require('hodocode.tree')
  local ui = require('hodocode.ui')
  local notices = {}
  vim.notify = function(message) notices[#notices + 1] = message end
  local function wait(predicate, message)
    assert(vim.wait(3000, predicate, 5), message .. '\n' .. table.concat(notices, '\n'))
  end
  local function exercise(renderer)
    local source = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(source)
    local valid = true
    local project = vim.fn.tempname()
    vim.fn.mkdir(project, 'p')
    vim.fn.writefile({ 'package example', 'func a() {}' }, project .. '/main.go')
    vim.api.nvim_buf_set_name(source, project .. '/main.go')
    local ctx = { root = project, buf = source, row = 0, column = 0,
      valid = function() return valid end }
    local function definition(id) return { ID = id, File = 'main.go', Line = 1, End = 3 } end
    local a, b, c, d = definition('a'), definition('b'), definition('c'), definition('d')
    local pending, requests = {}, {}
    local client = { request = function(_, method, params, callback)
      assert(method == 'calls')
      local id = params['function']
      requests[id] = (requests[id] or 0) + 1
      pending[id] = callback
    end }
    local controller = tree.open(ctx, client, a, { tree = renderer })
    assert(controller.view.renderer == renderer, 'renderer silently changed')
    assert(pending.a and controller.state.selected.id == 'a', 'root not selected / lazy load absent')
    pending.a({ calls = {
      { From = 'a', To = 'b', Line = 1 }, { From = 'a', To = 'b', Line = 2 },
      { From = 'a', To = 'c' },
      { From = 'a', To = 'dynamic', Unknown = true, Reason = 'ambiguous', Candidates = { 'b', 'c' } },
      { From = 'a', To = 'missing', Candidates = vim.NIL },
    }, Targets = { b = b, c = c, dynamic = b } })
    local root = controller.state.root
    assert(#root.children == 4 and #root.children[1].sites == 2, 'edge dedup lost site information')
    local bn, cn, unknown, missing = unpack(root.children)
    controller:act('expand', unknown); controller:act('jump', unknown)
    controller:act('expand', missing); controller:act('jump', missing)
    assert(not controller.closed and not pending.dynamic and not pending.missing, 'unproven target followed')
    if renderer == 'snacks' then
      wait(function() return controller.view.picker:count() == 5 end, 'initial Snacks rows absent')
      controller.view.picker:action('list_top')
      controller.view.picker:action('list_down')
      controller.view.picker:action('tree_toggle')
    else
      vim.api.nvim_win_set_cursor(controller.view.win, { 3, 0 })
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(controller.view.buf, 'n')) do
        if map.lhs == '<Tab>' then map.callback() end
      end
    end
    assert(pending.b, 'renderer toggle did not expand selected node')
    controller:act('expand', cn)
    pending.c({ calls = { { To = 'd' } }, Targets = { d = d } })
    pending.b({ calls = { { To = 'a' } }, Targets = { a = a } })
    assert(bn.children[1].cycle, 'ancestor cycle not marked')
    controller:act('expand', bn.children[1])
    assert(requests.a == 1, 'cycle expanded')
    controller:act('collapse', bn)
    controller:act('expand', bn)
    assert(requests.b == 1, 'cached expansion requested again')
    controller:act('collapse', cn)
    controller.state.selected = bn
    controller:render()
    if renderer == 'snacks' then
      wait(function() return controller.view.picker:count() == 6 end, 'Snacks tree rows not rendered')
      wait(function() return (controller.view.picker:current() or {}).node == bn end, 'Snacks selection not restored')
      local items = controller.view.picker:items()
      assert(items[1].node == root and items[2].node == bn and items[3].node.cycle, 'Snacks reordered tree')
      assert(items[5].text:find('ambiguous', 1, true) and items[5].text:find('候補: b, c', 1, true), 'Snacks lost unresolved details')
    else
      local lines = vim.api.nvim_buf_get_lines(controller.view.buf, 0, -1, false)
      assert(lines[6]:find('ambiguous', 1, true), 'native lost unresolved reason')
      assert(lines[6]:find('候補: b, c', 1, true), 'native lost candidates')
    end
    controller:close()
    controller = tree.open(ctx, client, a, { tree = renderer })
    assert(controller.state.root == root and controller.state.selected == bn and bn.open and not cn.open,
      'reopen lost branches/selection')
    assert(requests.a == 1, 'reopen reloaded unchanged source')
    controller:close()
    controller = tree.open(ctx, client, c, { tree = renderer })
    assert(controller.state.root == root and controller.state.selected == cn, 'reading path not retained')
    local dn = cn.children[1]
    controller:act('expand', dn)
    assert(pending.d)
    valid = false
    pending.d({ calls = { { To = 'a' } }, Targets = { a = a } })
    assert(not dn.loaded, 'stale callback mutated tree')
    local jumped
    local jump = ui.jump
    ui.jump = function(_, target) jumped = target end
    controller:act('jump', bn)
    assert(not jumped, 'stale source allowed jump')
    controller:close()
    valid = true
    controller = tree.open(ctx, client, c, { tree = renderer })
    -- A fresh context with changed source invalidates the previous snapshot.
    valid = false
    local newctx = vim.tbl_extend('force', ctx, { valid = function() return true end })
    local fresh = tree.open(newctx, client, a, { tree = renderer })
    assert(fresh.state.root ~= root, 'changed source reused state')
    local old_response = pending.a
    fresh:close()
    local reopened = tree.open(newctx, client, a, { tree = renderer })
    local new_response = pending.a
    assert(new_response ~= old_response and reopened.state.root.loading, 'pending root was not retried on reopen')
    old_response({ calls = {}, Targets = {} })
    assert(not reopened.state.root.loaded and reopened.state.root.loading, 'closed callback changed reopened tree')
    new_response(nil, 'request failed')
    assert(not reopened.state.root.loaded and reopened.state.root.error, 'error marked node loaded')
    reopened:act('expand', reopened.state.root)
    pending.a({ calls = {}, Targets = {} })
    reopened:act('collapse', reopened.state.root)
    reopened:close()
    reopened = tree.open(newctx, client, a, { tree = renderer })
    assert(not reopened.state.root.open, 'reopen expanded a deliberately collapsed root')
    reopened:act('jump', reopened.state.root)
    assert(jumped == a, 'source jumps must use ui.jump')
    ui.jump = jump
    assert(reopened.closed)
    vim.fn.writefile({ 'package example', 'func a() { println(1) }' }, project .. '/main.go')
    local changed = tree.open(newctx, client, a, { tree = renderer })
    assert(changed.state.root ~= reopened.state.root, 'disk changes reused cached tree')
    local late = pending.a
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'unsaved edit' })
    late({ calls = {}, Targets = {} })
    assert(not changed.state.root.loaded, 'unsaved source accepted callback')
    changed:close()
    vim.bo[source].modified = false
    local active = tree.open(newctx, client, a, { tree = renderer })
    pending.a({ calls = { { To = 'b' } }, Targets = { b = b } })
    active:act('expand', active.state.root.children[1])
    local cleared_child, late_clear = active.state.root.children[1], pending.b
    local before_clear = requests.a
    tree.clear()
    assert(active.closed and not active.view:alive(), 'clear left an active tree open')
    tree.clear() -- Idempotent even after renderer windows have closed.
    late_clear({ calls = {}, Targets = {} })
    assert(not cleared_child.loaded, 'clear accepted a pending callback')
    local after_clear = tree.open(newctx, client, a, { tree = renderer })
    assert(after_clear.state.root ~= active.state.root and #after_clear.state.root.children == 0
      and requests.a == before_clear + 1, 'clear retained cached branches or skipped fresh backend request')
    after_clear:close()
    vim.api.nvim_set_current_buf(source)
    vim.fn.delete(project, 'rf')
  end
  exercise('native')
  local auto = tree.open({ root = '/tree-auto', buf = vim.api.nvim_get_current_buf(), valid = function() return true end },
    { request = function(_, _, _, callback) callback({ calls = {}, Targets = {} }) end },
    { ID = 'auto', File = 'main.go', Line = 1 }, { tree = 'auto' })
  assert(auto.view.renderer == 'native' and notices[#notices]:find('native fallback', 1, true), 'auto fallback was not explicit')
  auto:close()
  local snacks_path = vim.env.HODOCODE_SNACKS
  if snacks_path then
    vim.opt.runtimepath:prepend(snacks_path)
    require('snacks').setup({ picker = { enabled = true } })
    exercise('snacks')
    local preferred = tree.open({ root = '/tree-auto-snacks', buf = vim.api.nvim_get_current_buf(), valid = function() return true end },
      { request = function(_, _, _, callback) callback({ calls = {}, Targets = {} }) end },
      { ID = 'auto', File = 'main.go', Line = 1 }, { tree = 'auto' })
    assert(preferred.view.renderer == 'snacks', 'explicit auto did not prefer available Snacks')
    preferred:close()
  end
  print('tree: native' .. (snacks_path and ' + real Snacks' or '') .. ' passed')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
