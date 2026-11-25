local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  local events = require('hodocode.edit_events')
  local result = { event = 'result', version = vim.fn.sha256('before\n'), message = 'done',
    edits = { { old_text = 'before', new_text = 'after' } } }
  local wire = vim.json.encode({ event = 'status', phase = 'waiting', elapsed_ms = 2 }) .. '\n' .. vim.json.encode(result)
  for step = 1, #wire do
    local phases = {}
    local parser = events.new(4096, function(phase) phases[#phases + 1] = phase end)
    for i = 1, #wire, step do assert(parser:feed(wire:sub(i, i + step - 1))) end
    assert(vim.deep_equal(assert(parser:finish()), result))
    assert(vim.deep_equal(phases, { 'waiting' }))
  end
  for _, wire_legacy in ipairs({ '{"message":"legacy","content":"after"}', '{\n  "message": "pretty",\n  "content": "after"\n}\n' }) do
    local parser = events.new(4096)
    for i = 1, #wire_legacy do assert(parser:feed(wire_legacy:sub(i, i))) end
    assert(assert(parser:finish()).content == 'after')
  end
  local bad = {
    wire .. '\n' .. vim.json.encode(result), wire .. '\n' .. '{"event":"status","phase":"waiting"}',
    wire .. '\n\n', '{"event":"status","phase":"thinking"}\n',
    '{"event":"status","phase":"waiting","elapsed_ms":-1}\n',
    '{"event":"status","phase":"waiting","context":"private"}\n',
    '{"event":"error","code":"unknown","message":"private"}',
    '{"message":"bad","content":"x","edits":[]}',
    '{"message":"bad","edits":[]}', '{"event":"result","message":"bad"}',
    '{"event":"status","phase":"waiting"}\n', '{}', 'null', '[]', 'garbage',
  }
  for _, input in ipairs(bad) do
    local parser = events.new(4096)
    parser:feed(input)
    local value, err = parser:finish()
    assert(not value and err == 'invalid_response', 'accepted invalid framing: ' .. input)
  end
  local parser = events.new(2)
  local value, err = parser:feed('123')
  assert(not value and err == 'size_limit')
  for code in pairs(events.codes) do
    parser = events.new(4096)
    assert(parser:feed(vim.json.encode({ event = 'error', code = code, message = 'ignored' })))
    assert(assert(parser:finish()).code == code)
  end
  print('PASS: edit events chunk framing, legacy JSON, terminal validation, bounded output')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
