local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  local links = require('hodocode.chat_links')
  local session = require('hodocode.session')
  local uv = vim.uv or vim.loop
  local cwd, temp = vim.fn.getcwd(), vim.fn.tempname()
  vim.fn.mkdir(temp .. '/project', 'p')
  local root = assert(uv.fs_realpath(temp .. '/project'))
  local function file(name, content)
    local path = root .. '/' .. name
    vim.fn.writefile(vim.split(content, '\n', { plain = true }), path, 'b')
    return path
  end
  local original = 'one\ntwo\nneedle\nfour\nfive\nsix\n'
  local source = file('a.lua', original)
  local other = file('日本語.lua', 'alpha\nbeta\n')
  file('space name.lua', 'space\n')
  local function link(text, sources, base)
    base = base or root
    local refs = links.capture(text, base, sources or {})
    return assert(links.scan({ text }, base, refs)[1]), refs
  end
  local function failure(item, description)
    local result, err = links.resolve(item)
    assert(not result and type(err) == 'string' and err:find('[\128-\255]'), description or tostring(err))
  end

  local text = '説明 (`a.lua:003`), a.lua:2: [日本語.lua:2]. `space name.lua:1`!'
  local refs = links.capture(text, root, { [source] = original })
  assert(refs['a.lua:003'] and not refs['a.lua:3'], 'literal lookup key')
  local scanned = links.scan({ 'header', text }, root, vim.deepcopy(refs))
  assert(#scanned == 4, 'multiple links and punctuation')
  for i, literal in ipairs({ 'a.lua:003', 'a.lua:2', '日本語.lua:2', 'space name.lua:1' }) do
    local item = scanned[i]
    local first = assert(text:find(literal, 1, true))
    assert(item.row == 2 and item.col == first - 1 and item.end_col == first - 1 + #literal, literal)
    assert(text:sub(item.col + 1, item.end_col) == literal)
  end
  local punctuation = links.scan({ "'a.lua:1'; **日本語.lua:2**" }, root)
  assert(#punctuation == 2 and punctuation[1].path == 'a.lua' and punctuation[2].path == '日本語.lua')
  vim.fn.mkdir(root .. '/src')
  local main = file('src/main.go', 'first\nsecond\nthird\n')
  file('_file.lua', 'underscore\n')
  local bold = '**src/main.go:3**'
  local bold_link, bold_refs = link(bold, { [main] = 'first\nsecond\nthird\n' })
  assert(bold_link.path == 'src/main.go' and bold_link.col == 2 and bold_link.end_col == #bold - 2)
  assert(bold_refs['src/main.go:3'].version and assert(links.resolve(bold_link)).row == 3)
  assert(links.scan({ '*src/main.go:3*' }, root)[1].path == 'src/main.go')
  assert(assert(links.resolve(link('_file.lua:1'))).row == 1)
  assert(#links.scan({ 'https://example.com/a.lua:2 http://x:3 ftp://x/y:4' }, root) == 0, 'URLs')
  assert(#links.scan({ 'a.lua:1' }, nil) == 0 and #links.scan({ 'a.lua:1' }, '') == 0)
  assert(next(links.capture('a.lua:1', nil, { [source] = original })) == nil)
  failure(links.scan({ 'a.lua:1' }, 'missing-root')[1])
  local oversized = string.rep('a/', 524288)
  assert(#links.scan({ oversized .. ':1' }, root) == 0, 'oversized paths are not links')
  assert(next(links.capture(oversized .. ':1', root, {})) == nil)
  failure({ path = oversized, line = 1, root = root })
  assert(#links.scan({ string.rep('a', 4096) .. ':1' }, root) == 1)
  assert(#links.scan({ string.rep('a', 4097) .. ':1' }, root) == 0)
  local canonical, lookups = uv.fs_realpath, 0
  uv.fs_realpath = function(path, ...)
    if path == source then lookups = lookups + 1 end
    return canonical(path, ...)
  end
  local paths_ok, paths_err = pcall(function()
    local citations = {}
    for row = 1, 1001 do citations[row] = 'a.lua:' .. row end
    local many = links.capture(table.concat(citations, ' '), root, {})
    assert(lookups == 1, 'canonicalize each literal target only once')
    for _, literal in ipairs(citations) do assert(many[literal], 'must not cap references') end
  end)
  uv.fs_realpath = canonical
  assert(paths_ok, paths_err)
  failure(link('missing.lua:1'))
  failure(link('a.lua:0'))
  failure(link('a.lua:999'))
  failure(link('a.lua:999999999999999999999999'))
  failure(link('../outside.lua:1'))
  vim.fn.writefile({ 'outside' }, temp .. '/outside.lua')
  failure(link('../outside.lua:1'))
  failure(link(temp .. '/outside.lua:1'))
  failure(link('.:1'))
  assert(uv.fs_symlink(temp .. '/outside.lua', root .. '/escape.lua'))
  failure(link('escape.lua:1'))

  local hash, split = vim.fn.sha256, vim.split
  local hashes, splits = 0, 0
  vim.fn.sha256 = function(content) hashes = hashes + 1; return hash(content) end
  vim.split = function(content, ...)
    if content == original then splits = splits + 1 end
    return split(content, ...)
  end
  local cache_ok, cache_err = pcall(function()
    local sources = { [source] = original, [other] = 'alpha\nbeta\n' }
    links.capture('no citations', root, sources)
    assert(hashes == 0 and splits == 0, 'unused sources must not be prepared')
    local repeated = links.capture('a.lua:1 a.lua:3 a.lua:6', root, sources)
    assert(hashes == 1 and splits == 1, 'prepare each cited source only once')
    assert(repeated['a.lua:1'].version == repeated['a.lua:6'].version)
    assert(repeated['a.lua:1'].context ~= repeated['a.lua:3'].context, 'anchors remain independent')
  end)
  vim.fn.sha256, vim.split = hash, split
  assert(cache_ok, cache_err)

  local known, captured = link('a.lua:3', { [source] = original })
  assert(captured['a.lua:3'].version == vim.fn.sha256(original))
  assert(#captured['a.lua:3'].context == 5 and captured['a.lua:3'].offset == 2)
  local history = session.append('assistant', 'a.lua:3', { root = root, references = captured }, { history = {} })
  captured['a.lua:3'].context[1] = 'changed copy'
  known.reference = history.references['a.lua:3']
  local result = assert(links.resolve(known))
  local buf = result.buf
  assert(result.row == 3 and result.path == source and vim.api.nvim_buf_is_loaded(buf))
  assert(vim.api.nvim_get_current_buf() ~= buf, 'resolver must not switch the chat buffer')
  local function set(lines)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  end
  local original_lines = { 'one', 'two', 'needle', 'four', 'five', 'six' }
  local invalid_known = link('a.lua:7', { [source] = original })
  assert(invalid_known.reference.invalid_line)
  invalid_known.reference = vim.deepcopy(invalid_known.reference)
  failure(invalid_known)
  set({ 'inserted', 'one', 'two', 'needle', 'four', 'five', 'six' })
  failure(invalid_known, 'known-source invalid line must stay invalid after file grows')
  assert(assert(links.resolve(link('a.lua:7'))).row == 7, 'unknown source can use the new line')
  assert(vim.bo[buf].modified)
  result = assert(links.resolve(known))
  assert(result.buf == buf and result.row == 4, 'unique context relocation in unsaved buffer')
  assert(table.concat(vim.fn.readfile(source), '\n') == original:sub(1, -2), 'must not write unsaved changes')
  set({ 'one', 'two', 'needle', 'four', 'five', 'one', 'two', 'needle', 'four', 'five' })
  failure(known, 'ambiguous context must not choose the original row')
  set({ 'one', 'two', 'changed', 'four', 'five', 'six' })
  failure(known, 'changed anchor must fail')
  set(original_lines) -- Restore/undo returns to the captured version.
  assert(assert(links.resolve(known)).row == 3)

  -- An unknown snapshot reuses an already loaded modified canonical alias without loading disk.
  assert(uv.fs_symlink(source, root .. '/alias.lua'))
  local alias = link('alias.lua:3')
  local before_add, before_load = vim.fn.bufadd, vim.fn.bufload
  vim.fn.bufadd = function() error('unexpected bufadd for loaded canonical path') end
  vim.fn.bufload = function() error('unexpected bufload for loaded canonical path') end
  set({ 'unsaved', 'two', 'three', 'four', 'five', 'six', 'extra' })
  assert(assert(links.resolve(alias)).buf == buf)
  assert(assert(links.resolve(link('a.lua:7'))).row == 7, 'unknown version uses current line bounds')
  failure(known)
  vim.fn.bufadd, vim.fn.bufload = before_add, before_load
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'unsaved')

  local switched = link('alias.lua:1', { [source] = original })
  assert(uv.fs_unlink(root .. '/alias.lua'))
  assert(uv.fs_symlink(other, root .. '/alias.lua'))
  failure(switched, 'changed symlink within root')
  assert(uv.fs_unlink(root .. '/alias.lua'))
  assert(uv.fs_symlink(temp .. '/outside.lua', root .. '/alias.lua'))
  failure(switched, 'changed symlink outside root')

  -- Only a valid, unloaded file is loaded, once; scan/capture never read file bodies.
  local add_count, load_count = 0, 0
  vim.fn.bufadd = function(path) add_count = add_count + 1; return before_add(path) end
  vim.fn.bufload = function(number) load_count = load_count + 1; return before_load(number) end
  local unknown = link('日本語.lua:2')
  assert(not unknown.reference.version)
  assert(assert(links.resolve(unknown)).row == 2)
  assert(assert(links.resolve(unknown)).row == 2)
  assert(add_count == 1 and load_count == 1)
  vim.fn.bufadd, vim.fn.bufload = before_add, before_load

  -- A relative root is recorded canonically at capture, not interpreted in the later cwd.
  vim.cmd.cd(temp)
  local relative = link('日本語.lua:1', {}, 'project')
  assert(relative.reference.root == root)
  vim.cmd.cd('/')
  assert(assert(links.resolve(relative)).path == other)
  assert(assert(links.resolve(links.scan({ '日本語.lua:1' }, root)[1])).path == other)
  vim.cmd.cd(cwd)

  -- Canonical source aliases, no-EOL versions, empty files, and deliberately pure scan.
  local no_eol = file('no-eol.lua', 'last')
  local no_eol_link = link('no-eol.lua:1', { [no_eol] = 'last' })
  assert(assert(links.resolve(no_eol_link)).row == 1)
  file('empty.lua', '')
  assert(assert(links.resolve(link('empty.lua:1', { [root .. '/empty.lua'] = '' }))).row == 1)
  local old_real, old_stat, old_open = uv.fs_realpath, uv.fs_stat, uv.fs_open
  uv.fs_realpath, uv.fs_stat, uv.fs_open = function() error('scan I/O') end, function() error('scan I/O') end, function() error('body read') end
  assert(#links.scan({ text }, root, refs) == 4)
  uv.fs_realpath, uv.fs_stat = old_real, old_stat
  assert(links.capture('no-eol.lua:1', root, { [no_eol] = 'last' })['no-eol.lua:1'].version)
  uv.fs_open = old_open

  vim.fn.delete(temp, 'rf')
  print('PASS: chat links parsing/byte spans, containment/symlink drift, versions/anchors, unsaved buffers, lazy loading, canonical roots, pure scan')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
