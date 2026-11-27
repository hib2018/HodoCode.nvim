local temp
local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local uv = vim.uv or vim.loop
  local repository = require('hodocode.repository')
  temp = vim.fn.tempname()
  -- An absolute ancestor named build must not exclude this repository.
  local root = temp .. '/build/repo'
  vim.fn.mkdir(root, 'p')
  root = uv.fs_realpath(root)
  local function buffer(path, lines)
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { 'unsaved' })
    vim.bo[buf].endofline = true
    return buf
  end
  local target = root .. '/target.lua'
  local target_buf = buffer(target, { 'target unsaved' })
  vim.fn.writefile({ 'saved original' }, root .. '/other.lua')
  local other = buffer(root .. '/other.lua', { 'first', 'second' })
  local unchanged = buffer(root .. '/unchanged.lua')
  vim.bo[unchanged].modified = false
  buffer(temp .. '/external.lua')
  buffer('', { 'unnamed' })
  local special = buffer(root .. '/special')
  vim.bo[special].buftype = 'nofile'
  for _, dir in ipairs({ '.git', 'build', 'dist', 'target', 'node_modules', '.cache' }) do
    buffer(root .. '/nested/' .. dir .. '/generated.lua')
  end
  for _, name in ipairs({ '.env', '.env.local', 'credentials.pem', 'credentials.key' }) do
    buffer(root .. '/nested/' .. name, { 'SECRET must not enter context' })
  end
  vim.fn.mkdir(temp .. '/outside', 'p')
  assert(uv.fs_symlink(temp .. '/outside', root .. '/escape'))
  buffer(root .. '/escape/new.lua')
  local binary = buffer(root .. '/binary.lua')
  vim.bo[binary].binary = true
  local nul = buffer(root .. '/nul.lua', { 'a\0b' })
  local unloaded_path = root .. '/unloaded.lua'
  vim.fn.writefile({ 'disk only' }, unloaded_path)
  local unloaded = vim.fn.bufadd(unloaded_path)
  assert(not vim.api.nvim_buf_is_loaded(unloaded))
  local function snapshots(limit)
    return repository.snapshots(root, target, limit or 1024 * 1024)
  end
  local values = assert(snapshots())
  assert(#values == 1 and values[1].path == root .. '/other.lua')
  assert(values[1].content == 'first\nsecond\n')
  assert(not vim.api.nvim_buf_is_loaded(unloaded))
  assert(vim.fn.readfile(root .. '/other.lua')[1] == 'saved original' and vim.bo[other].modified)
  assert(not uv.fs_stat(target), 'must not create unsaved files')
  assert(vim.api.nvim_buf_get_lines(target_buf, 0, -1, false)[1] == 'target unsaved')
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'changed' })
  assert(values[1].content == 'first\nsecond\n', 'snapshot must be immutable')
  vim.bo[other].fileformat = 'dos'
  assert(snapshots()[1].content == 'changed\n', 'DOS buffers use logical LF')
  vim.bo[other].endofline = false
  assert(snapshots()[1].content == 'changed')
  local value, err = snapshots(6)
  assert(not value and err == 'size_limit')
  assert(snapshots(7)[1].content == 'changed')
  local second = buffer(root .. '/second.lua', { 'two' })
  assert(#snapshots() == 2, 'include unlisted modified normal buffers')
  value, err = snapshots(10)
  assert(not value and err == 'size_limit', 'limit is aggregate')
  vim.bo[second].modified = false
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { string.rep('x', 1024 * 1024 + 1) })
  local get_lines = vim.api.nvim_buf_get_lines
  vim.api.nvim_buf_get_lines = function(buf, ...)
    assert(buf ~= other, 'oversize buffer must not be copied')
    return get_lines(buf, ...)
  end
  value, err = snapshots()
  vim.api.nvim_buf_get_lines = get_lines
  assert(not value and err == 'size_limit')
  assert(vim.fn.readfile(root .. '/other.lua')[1] == 'saved original', 'must not overwrite disk')
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'small' })
  vim.bo[other].fileformat = 'mac'
  value, err = snapshots()
  assert(not value and err == 'invalid_buffer')
  vim.bo[other].fileformat = 'unix'
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { string.char(255) })
  value, err = snapshots()
  assert(value == nil and err == 'invalid_buffer', 'reject invalid UTF-8')
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'small' })
  -- Existing and missing paths under an in-root symlink share canonical identities.
  vim.fn.mkdir(root .. '/src', 'p')
  assert(uv.fs_symlink(root .. '/src', root .. '/alias'))
  local linked = buffer(root .. '/alias/new.lua', { 'linked' })
  vim.bo[target_buf].modified = false
  local skipped = repository.snapshots(root, root .. '/src/new.lua', 1024)
  assert(#skipped == 1 and skipped[1].path == root .. '/other.lua')
  assert(vim.bo[linked].modified and vim.bo[nul].modified)
  assert(not package.loaded['hodocode.agent'] and not package.loaded['hodocode.acp'], 'no AI dependencies')
end
local ok, err = xpcall(run, debug.traceback)
if temp then vim.fn.delete(temp, 'rf') end
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
print('repository_context: ok')
vim.cmd('qa!')
