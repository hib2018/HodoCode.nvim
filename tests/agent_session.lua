local function run()
  vim.opt.runtimepath:prepend(vim.fn.getcwd())
  vim.o.hidden = true
  vim.notify = function() end
  local opened, refreshed = 0, 0
  package.loaded['hodocode.chat'] = { open = function() opened = opened + 1 end }
  package.loaded['hodocode.inline_diff'] = { visible = function() return true end, refresh = function(_, baseline)
    assert(baseline.lines); refreshed = refreshed + 1
  end }
  local agent, session = require('hodocode.agent'), require('hodocode.session')
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  local path = root .. '/source.txt'
  vim.fn.writefile({ 'disk' }, path)
  vim.cmd.edit(path)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local target = { buf = buf, win = win, cursor = { 1, 0 } }
  local config = { agent = { 'mock' }, max_agent_bytes = 1024 * 1024, agent_timeout_ms = 1000 }
  local pending, sent, kills = {}, {}, 0
  local system = vim.system
  vim.system = function(_, opts, callback)
    sent[#sent + 1] = vim.json.decode(opts.stdin)
    pending[#pending + 1] = function(response)
      opts.stdout(nil, vim.json.encode(response))
      callback({ code = 0, signal = 0 })
    end
    return { kill = function() kills = kills + 1 end }
  end
  local function answer(response)
    table.remove(pending, 1)(response)
    vim.wait(30, function() return session.get().request == nil end, 1)
  end
  local function body() return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
  local id = session.get().id
  assert(agent.run(config, 'why?', 'chat', target))
  assert(sent[1].intent == 'chat' and #sent[1].history == 0)
  local count = #session.history()
  agent.run(config, 'busy', 'edit', target)
  assert(#sent == 1 and #session.history() == count)
  answer({ message = 'Because.' })
  assert(body() == 'disk' and session.history()[2].status == 'nochange')
  local copy = session.history(); copy[1].content = 'mutated'
  assert(session.history()[1].content == 'why?')

  -- Prompt capture happens on send, not when the draft opens.
  local submit, dismiss
  package.loaded['hodocode.edit_prompt'] = { open = function(send, cancel)
    submit, dismiss = send, cancel
    return nil, nil, cancel
  end }
  agent.run(config, nil, 'edit', target)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'manual', 'latest' })
  vim.api.nvim_win_set_cursor(win, { 2, 3 })
  submit('change')
  assert(sent[2].buffer.content == 'manual\nlatest\n')
  assert(vim.deep_equal(sent[2].buffer.cursor, { 2, 3 }))
  assert(#sent[2].history == 2 and sent[2].history[2].content == 'Because.')
  assert(sent[2].session_id == id and sent[2].request_id ~= sent[1].request_id)
  -- No view/window ownership: close the source window and move elsewhere in flight.
  vim.cmd.vsplit()
  vim.api.nvim_win_close(win, true)
  vim.cmd.enew()
  local unrelated = vim.api.nvim_get_current_buf()
  answer({ message = 'Changed.', content = 'AI\n' })
  assert(body() == 'AI' and vim.api.nvim_get_current_buf() == unrelated)
  assert(session.history()[4].status == 'applied' and refreshed == 1)
  assert(agent.baseline(buf).lines[1] == 'disk')
  vim.api.nvim_buf_call(buf, function() vim.cmd.undo() end)
  assert(body() == 'manual\nlatest')

  local history = #session.history()
  agent.run(config, nil, 'edit', target); dismiss()
  assert(#session.history() == history and session.get().id == id)
  assert(agent.run(config, 'cancel', 'edit', target))
  agent.stop()
  assert(session.history()[history + 2].status == 'cancelled' and kills > 0)
  answer({ message = 'too late', content = 'NO\n' })
  assert(body() == 'manual\nlatest' and #session.history() == history + 2)

  assert(agent.run(config, 'conflict', 'edit', target))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'mine' })
  answer({ message = 'applied?', content = 'NO\n' })
  assert(body() == 'mine' and session.history()[#session.history()].status == 'conflict')
  assert(agent.run(config, 'question', 'chat', target))
  answer({ message = 'bad', version = vim.fn.sha256('mine\n'), edits = { { start_line = 1, end_line = 1, text = 'NO' } } })
  assert(body() == 'mine' and session.history()[#session.history()].status == 'invalid_patch')
  assert(agent.run(config, 'question', 'chat', target))
  answer({ message = 'answer' })
  assert(sent[#sent].history[#sent[#sent].history].status == 'invalid_patch')

  for _, changes in ipairs({ { content = '' }, { edits = { unexpected = true } } }) do
    assert(agent.run(config, 'strict question', 'chat', target))
    changes.message, changes.version = 'not an answer', vim.fn.sha256('mine\n')
    answer(changes)
    assert(body() == 'mine' and session.history()[#session.history()].status == 'invalid_patch')
  end

  -- Answers belong to the send-time snapshot, not the subsequently edited source.
  assert(agent.run(config, 'pending question', 'chat', target))
  local sent_version = vim.fn.sha256(sent[#sent].buffer.content)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'manual while asking' })
  local question_focus = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(question_focus)
  vim.fn.writefile({ 'disk changed during question' }, path)
  answer({ message = 'Answer to the sent snapshot.', version = sent_version })
  assert(body() == 'manual while asking' and vim.api.nvim_get_current_buf() == question_focus)
  local turn = session.history()[#session.history()]
  assert(turn.content == 'Answer to the sent snapshot.' and turn.status == 'nochange')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'mine' })

  -- Read-only input is rejected before a request/history is created.
  local before = #session.history()
  vim.bo[buf].readonly = true
  assert(not agent.run(config, 'readonly', 'edit', target))
  assert(#session.history() == before)
  vim.bo[buf].readonly = false
  assert(agent.run(config, 'disk conflict', 'edit', target))
  vim.fn.writefile({ 'disk changed' }, path)
  answer({ message = 'bad', content = 'NO\n' })
  assert(body() == 'mine' and session.history()[#session.history()].status == 'conflict')
  local old_diff, baseline = package.loaded['hodocode.inline_diff'], agent.baseline
  package.loaded['hodocode.inline_diff'] = nil
  agent.baseline = function() error('hidden inline diff must not compute its baseline') end
  assert(agent.run(config, 'EOL', 'edit', target))
  answer({ message = 'no final newline', content = 'without EOL' })
  assert(body() == 'without EOL' and not vim.bo[buf].endofline)
  assert(package.loaded['hodocode.inline_diff'] == nil, 'unused inline diff was loaded')
  agent.baseline, package.loaded['hodocode.inline_diff'] = baseline, old_diff
  vim.api.nvim_buf_call(buf, function() vim.cmd.undo() end)
  vim.wait(30, function() return vim.bo[buf].endofline end, 1)
  assert(body() == 'mine' and vim.bo[buf].endofline)

  -- User callbacks may change the source during validation.
  local hook = vim.api.nvim_create_autocmd('User', { pattern = 'HodoCodeAgentStatus', callback = function(ev)
    if ev.data.phase == 'validating' then vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'callback edit' }) end
  end })
  assert(agent.run(config, 'reentrant', 'edit', target))
  answer({ message = 'bad', content = 'NO\n' })
  assert(body() == 'callback edit' and session.history()[#session.history()].status == 'conflict')
  vim.api.nvim_del_autocmd(hook)
  local disposable = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(disposable, root .. '/disposable.txt')
  assert(agent.run(config, 'wipe', 'chat', { buf = disposable }))
  answer({ message = 'answer' })
  assert(agent.status(disposable))
  local retained = #session.history()
  vim.api.nvim_buf_delete(disposable, { force = true })
  assert(agent.status(disposable) == nil and #session.history() == retained)
  assert(agent.run(config, 'shutdown', 'edit', target))
  local request = session.get().request
  agent.shutdown()
  assert(request.cancelled and request.timer == nil and request.cwd == nil)
  assert(#session.history() == 0 and session.get().request == nil and session.get().id ~= id)
  answer({ message = 'late shutdown', content = 'NO\n' })
  assert(#session.history() == 0 and body() == 'callback edit')
  vim.system = system
  vim.fn.delete(root, 'rf')
  assert(opened > 0)
  print('agent_session: ok')
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') else vim.cmd('qa!') end
