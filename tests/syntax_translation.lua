local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local hc = require('hodocode')
  local prep = require('hodocode.prepare')
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  vim.fn.writefile({ 'def private_function():', '    return "SOURCE_SECRET"' }, root .. '/private.py')
  vim.cmd.edit(root .. '/private.py')
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local help = { title = 'dependency.lookup', description = 'Original documentation', syntax = 'lookup(key)',
    reference = 'external reference', translate = true, documentation = 'Look up the supplied key.' }
  package.loaded['hodocode.client'] = { stop_all = function() end, start = function()
    return { request = function(_, method, _, cb)
      cb(method == 'syntax' and vim.deepcopy(help) or {})
    end }
  end }
  local notices = {}
  vim.notify = function(msg) notices[#notices + 1] = msg end
  local adapter = [[import sys,json,os,stat,time
r=json.load(sys.stdin)
b=r['buffer']
assert set(r)=={'prompt','buffer'}
assert set(b)=={'file','path','language','content','version'}
assert b['file']==b['path']=='external-documentation.txt' and b['language']=='text'
assert b['content'].startswith('Look up')
assert len(b['version'])==64
assert 'dependency.lookup' in r['prompt'] and 'lookup(key)' in r['prompt']
assert 'Preserve all code, literals' in r['prompt'] and r'\u002a' in r['prompt'] and r'\u0060' in r['prompt']
s=json.dumps(r)
assert all(x not in s for x in ['SOURCE_SECRET','private_function','private.py',ROOT])
assert os.getcwd()!=ROOT and stat.S_IMODE(os.stat(os.getcwd()).st_mode)==0o700
DELAY
s=json.dumps(dict(version=VERSION,message=MESSAGE,comments=COMMENTS),ensure_ascii=False)
sys.stdout.write(s.replace('*',r'\u002a').replace('`',r'\u0060'))
]]
  local function argv(options)
    options = options or {}
    local code = adapter:gsub('ROOT', string.format('%q', root))
      :gsub('DELAY', options.delay and ('time.sleep(' .. options.delay .. ')') or '')
      :gsub('VERSION', options.version or "b['version']")
      :gsub('MESSAGE', options.message or "'キーを検索します。'")
      :gsub('COMMENTS', options.comments or '[]')
    return { 'python3', '-c', code }
  end
  hc.setup({ root = root, explain_agent = argv(), agent_timeout_ms = 1000, max_agent_bytes = 16384 })
  local starts, dirs = 0, {}
  local original_system, original_tempdir = prep.system, prep.tempdir
  prep.system = function(...)
    starts = starts + 1
    return original_system(...)
  end
  prep.tempdir = function()
    local dir = original_tempdir()
    dirs[#dirs + 1] = dir
    return dir
  end
  local function wait(test, label)
    assert(vim.wait(4000, test, 10), label .. '\n' .. table.concat(notices, '\n'))
  end
  local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n') end
  local function open()
    vim.api.nvim_set_current_win(source_win)
    hc.syntax()
    return vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  end
  local function close(win)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    vim.api.nvim_set_current_win(source_win)
  end
  local function fresh()
    help.documentation = help.documentation .. ' More.'
  end
  local function clean()
    for _, dir in ipairs(dirs) do assert(not uv.fs_stat(dir), 'private cwd leaked: ' .. dir) end
  end
  -- Standard and local help must never invoke an adapter, even when configured.
  help.translate = nil
  for _ = 1, 2 do
    local _, win = open()
    assert(starts == 0 and text():find('Original documentation', 1, true))
    close(win)
  end
  help.translate = true
  hc.config.explain_agent = nil
  local _, win = open()
  assert(starts == 0 and text():find('explain_agent', 1, true) and text():find('Original documentation', 1, true))
  close(win)

  hc.config.explain_agent = argv({ delay = 0.15 })
  local buf
  buf, win = open()
  assert(text(buf):find('翻訳中', 1, true) and text(buf):find('Original documentation', 1, true))
  vim.api.nvim_set_current_win(source_win)
  vim.api.nvim_win_set_cursor(source_win, { 2, 3 })
  wait(function() return text(buf):find('キーを検索します。', 1, true) end, 'successful Japanese translation')
  assert(vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf, 'must update same popup')
  assert(vim.api.nvim_get_current_win() == source_win, 'must not steal focus after cursor movement')
  assert(text(buf):find('lookup(key)', 1, true) and text(buf):find('external reference', 1, true))
  assert(not text(buf):find('Original documentation', 1, true))
  assert(starts == 1)
  clean()
  close(win)
  buf, win = open()
  assert(starts == 1 and text(buf):find('キーを検索します。', 1, true), 'cache successful translations')
  close(win)

  for _, options in ipairs({ { version = "'wrong'" }, { message = "'   '" }, { message = "'bad\\x00text'" },
    { message = "'Look up the supplied key.'" },
    { comments = "[dict(line=1,text='unwanted')]" }, { comments = "dict(arbitrary='note')" }, { delay = 1 } }) do
    fresh()
    hc.config.explain_agent = argv(options)
    hc.config.agent_timeout_ms = options.delay and 40 or 1000
    buf, win = open()
    wait(function() return text(buf):find('翻訳に失敗', 1, true) end, 'invalid/timeout response must retain original')
    assert(text(buf):find('Original documentation', 1, true))
    clean()
    close(win)
    local before = starts
    buf, win = open()
    assert(starts == before + 1, 'failures must not be cached')
    close(win)
    clean()
  end

  local original_docs = help.documentation
  help.documentation = 'Look up `*Client` and return its value.'
  hc.config.agent_timeout_ms = 1000
  for _, message in ipairs({ "'Client を検索します。'", "'`Client` を検索します。'", "'*Client を検索します。'" }) do
    hc.config.explain_agent = argv({ message = message })
    local before = starts
    buf, win = open()
    assert(starts == before + 1, 'lost pointer/markup response must not be cached')
    wait(function() return text(buf):find('翻訳に失敗', 1, true) end, 'reject lost pointer or backticks')
    assert(text(buf):find('Original documentation', 1, true))
    close(win)
    clean()
  end
  hc.config.explain_agent = argv({ message = "'`*Client` を検索して値を返します。'" })
  buf, win = open()
  wait(function() return text(buf):find('`*Client` を検索して値を返します。', 1, true) end,
    'JSON Unicode escapes must preserve pointer and backticks')
  close(win)
  clean()
  help.documentation = original_docs

  fresh()
  hc.config.agent_timeout_ms = 1000
  hc.config.explain_agent = argv({ delay = 0.3, message = "'STALE_TRANSLATION'" })
  buf, win = open()
  close(win)
  clean()
  hc.config.explain_agent = argv({ delay = 0.05 })
  local nextbuf, nextwin = open()
  wait(function() return text(nextbuf):find('キーを検索します。', 1, true) end, 'reopened popup translates')
  vim.wait(400, function() return false end, 10)
  assert(not text(nextbuf):find('STALE_TRANSLATION', 1, true), 'closed popup response cannot affect reopened popup')
  clean()
  close(nextwin)

  fresh()
  hc.config.explain_agent = argv({ delay = 1 })
  buf, win = open()
  hc.cancel()
  assert(not vim.api.nvim_win_is_valid(win), 'cancel closes pending popup')
  clean()

  fresh()
  buf, win = open()
  vim.api.nvim_buf_set_lines(source, 1, 2, false, { '    return "EDITED"' })
  vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
  assert(not vim.api.nvim_win_is_valid(win), 'source edits close pending popup')
  clean()
  prep.system, prep.tempdir = original_system, original_tempdir
  hc.cancel()
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(root, 'rf')
  print('PASS: syntax translation synthetic-only payload, private cwd, same-window/no-focus update, cache, invalid response/timeout, popup close/cancel/source edits and stale responses; local adapters only')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
