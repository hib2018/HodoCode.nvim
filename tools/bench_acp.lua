-- Explicitly opt-in: real provider calls, public dummy source only, at most 14 turns.
assert(vim.env.HODOCODE_ACP_LIVE == '1', 'Set HODOCODE_ACP_LIVE=1 to authorize live model calls')
local workspace = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
vim.opt.runtimepath:prepend(workspace)
vim.o.hidden, vim.o.lines, vim.o.columns = true, 40, 120
local uv = vim.uv or vim.loop
local agent, chat = require('hodocode.agent'), require('hodocode.chat')
local session, acp = require('hodocode.session'), require('hodocode.acp')
local diff = require('hodocode.inline_diff')
local output = workspace .. '/docs/acp-benchmark-2026-11.json'
local temp = vim.fn.tempname()
local stage, turns = 'preflight', 0
local bench_only = vim.env.HODOCODE_BENCH_ONLY == '1'
local sample_count, turn_limit, prior_turns = bench_only and 2 or 3, bench_only and 8 or 14, 0
local report = {
  date = '2026-11-26', platform = 'Darwin 25.5', status = 'partial', max_model_turns = 14,
  command = 'HODOCODE_ACP_LIVE=1 nvim --headless -u NONE -l tools/bench_acp.lua',
  samples = {}, workflow = {},
  notes = {
    'Only public dummy fixtures in owned temporary directories are supplied to models.',
    'Native ACP persists its dummy-input sessions by design; no fx history is deleted.',
    'Same fx version/provider/model/effort/source/prompt/edit intent; serialized wire, system prompts, and history representation differ.',
    'ACP keeps one process/session within each pair; JSON includes adapter, CLI startup, and private working directory per request.',
    'HodoCode history is reset between every transport pair; both requests within a pair share history.',
    'JSON first_chunk_ms is null: its first JSON is the final result, not an observable first-token event.',
    'ACP complete_ms precedes application; apply_ms observes validating-to-done including patch validation, markers and undo guard.',
    'No speedup assumption; three samples per transport, initial and identical continuation inputs.',
  },
}
local function now() return uv.hrtime() / 1e6 end
local function check(value, reason) assert(value, reason) end
local function scalar_status()
  local result = vim.system({ 'fx', 'status', '--json' }, { text = true }):wait(10000)
  check(result.code == 0, 'status_unavailable')
  local s = vim.json.decode(result.stdout)
  return { model = s.model, effort = s.effort, connected_providers = s.connected_providers }
end
local function body(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end
local function value(n) return 'const Value = ' .. n end
local function set(buf, n)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd('let &l:undolevels = &l:undolevels')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { value(n) })
    vim.cmd('let &l:undolevels = &l:undolevels')
  end)
end
local function fixture(name, transport)
  local root = temp .. '/' .. name
  vim.fn.mkdir(root, 'p')
  root = uv.fs_realpath(root)
  local path = root .. '/source.js'
  vim.fn.writefile({ value(0) }, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = 'javascript'
  local target = { buf = buf, win = vim.api.nvim_get_current_win(), cursor = { 1, 0 } }
  local config = vim.deepcopy(require('hodocode').config)
  config.root, config.agent_transport = root, transport
  config.agent_timeout_ms, config.max_agent_bytes = 60000, 1024 * 1024
  config.agent = transport == 'acp'
    and { 'fx', '--no-additional-dirs', 'acp', '--provider', 'codex', '--model', 'gpt-6.2-sol', '--effort', 'auto', '--permission-mode', 'ask' }
    or { 'python3', workspace .. '/examples/edit-fx.py' }
  return { root = root, path = path, buf = buf, target = target, config = config }
end
local function request(f, prompt, intent, hide)
  check(turns < turn_limit and prior_turns + turns < 14, 'turn_budget')
  turns = turns + 1
  local validating, done
  local hook = vim.api.nvim_create_autocmd('User', {
    pattern = 'HodoCodeAgentStatus', callback = function(ev)
      if ev.data.buf ~= f.buf then return end
      if ev.data.phase == 'validating' then validating = now() end
      if ev.data.phase == 'done' then done = now() end
    end,
  })
  local began = now()
  local launched = agent.run(f.config, prompt, intent, f.target)
  if not launched then vim.api.nvim_del_autocmd(hook); error('request_launch_failed') end
  local state, id = session.get(), session.get().id
  local req = state.request
  check(req and req.running, 'request_not_running')
  if hide then
    check(chat.visible(), 'chat_not_open')
    chat.hide()
    check(not chat.visible() and state.request == req and not req.cancelled, 'hide_cancelled_request')
  end
  local permission = false
  local finished = vim.wait(65000, function()
    local status = agent.status(f.buf)
    -- Never approve a permission panel; no tool use is required by these fixtures.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)
      if (lines[1] or ''):find('権限要求:', 1, true) == 1 then
        permission = true
        return true
      end
    end
    return status and not status.running
  end, 20)
  vim.api.nvim_del_autocmd(hook)
  check(not permission, 'unexpected_permission_request')
  check(finished, 'request_wait_timeout')
  local status = agent.status(f.buf)
  if status.phase ~= 'done' and f.config.agent_transport == 'acp' then
    local info = acp.info(f.root)
    local stream = req.stream or ''
    local json_ok = pcall(vim.json.decode, stream)
    report.failed_native = {
      session_id = info and info.sessionId or vim.NIL,
      metrics = info and info.metrics or {},
      streamed_bytes = #stream, streamed_json_valid = json_ok,
    }
  end
  check(status.phase == 'done', status.code or 'request_failed')
  check(session.get().id == id, 'history_id_changed')
  local result = {
    total_ms = status.elapsed_ms, wall_ms = now() - began,
    apply_ms = validating and done and (done - validating) or vim.NIL,
    startup_ms = vim.NIL, first_chunk_ms = vim.NIL, complete_ms = vim.NIL,
  }
  if f.config.agent_transport == 'acp' then
    local info = acp.info(f.root)
    check(info and info.alive and info.sessionId, 'acp_not_alive')
    check(not f.sid or f.sid == info.sessionId, 'acp_session_changed')
    f.sid = info.sessionId
    result.id_stable = true
    for _, key in ipairs({ 'startup_ms', 'first_chunk_ms', 'complete_ms' }) do
      result[key] = info.metrics[key] or vim.NIL
    end
  end
  return result
end
local function reset()
  agent.shutdown()
  chat.shutdown()
end
local function run()
  if bench_only then
    local previous = vim.json.decode(table.concat(vim.fn.readfile(output), '\n'))
    check(previous.status == 'partial' and previous.workflow.validated == true, 'resume_requires_validated_workflow')
    prior_turns = previous.model_turns
    check(type(prior_turns) == 'number' and prior_turns + turn_limit <= 14, 'resume_exceeds_cumulative_budget')
    report = previous
    report.prior_failure = { stage = report.failure_stage, reason = report.failure_reason }
    report.failure_stage, report.failure_reason, report.failed_native = nil, nil, nil
    report.samples, report.medians_ms = {}, nil
    report.workflow.pre_fix_timings = true
    report.workflow.first_chunk_comparable = false
    for i, note in ipairs(report.notes) do
      if note:find('No speedup assumption;', 1, true) == 1 then
        report.notes[i] = 'No speedup assumption; two samples per transport, initial and identical continuation inputs.'
      elseif note:find('model_turns counts', 1, true) == 1 then
        report.notes[i] = 'The prior run used three requests: two successful workflow requests and one invalid-response benchmark request.'
      end
    end
    report.command = 'HODOCODE_ACP_LIVE=1 HODOCODE_BENCH_ONLY=1 nvim --headless -u NONE -l tools/bench_acp.lua'
    report.notes[#report.notes + 1] = 'Benchmark-only resume preserves the successful prior workflow; two pairs per transport, eight new requests, three prior attempts, eleven cumulative requests.'
    report.notes[#report.notes + 1] = 'Preserved workflow question first_chunk_ms includes a pre-fix skill warning, not model TTFT; benchmark measurements use corrected notice capability.'
    report.notice_capability_fix = {
      cause = 'fx requires clientCapabilities.session.notices to be an object; boolean true did not opt in and skill warnings arrived as assistant text.',
      source = 'https://github.com/vercel-labs/fx/blob/6196071b3c1b/src/acp/server.zig#L2911',
      encoding = '{}',
    }
  end
  report.sample_pairs_per_transport, report.current_run_max_turns = sample_count, turn_limit
  local version = vim.system({ 'fx', '--version' }, { text = true }):wait(10000)
  check(version.code == 0, 'version_unavailable')
  report.fx_version = vim.trim(version.stdout)
  check(report.fx_version == '0.0.18', 'unexpected_fx_version')
  local current_profile = scalar_status()
  check(not bench_only or vim.deep_equal(report.profile, current_profile), 'resume_profile_mismatch')
  report.profile = current_profile
  check(report.profile.model == 'gpt-6.2-sol', 'default_model_mismatch')
  check(vim.tbl_contains(report.profile.connected_providers or {}, 'codex'), 'default_provider_mismatch')
  -- The fixed legacy helper inherits the default profile: never change user settings to make this pass.
  check(report.profile.effort == 'auto', 'default_effort_mismatch')
  report.native_argv = { 'fx', '--no-additional-dirs', 'acp', '--provider', 'codex', '--model', 'gpt-6.2-sol', '--effort', 'auto', '--permission-mode', 'ask' }
  local help = vim.list_extend(vim.deepcopy(report.native_argv), { '--help' })
  check(vim.system(help, { text = true }):wait(10000).code == 0, 'native_cli_flags_rejected')
  if not bench_only then
    stage = 'workflow'
    local f = fixture('workflow', 'acp')
    set(f.buf, 1)
    report.workflow.question = request(f,
      'Do not use tools. Remember HODO_ACP_FLOW_TOKEN for this conversation. Read the supplied current buffer and state the current Value (1).', 'chat', true)
    local state, id = session.get(), session.get().id
    check(#state.history == 2 and state.history[2].content:find('1', 1, true), 'question_value_missing')
    check(chat.open(f.config, f.target) and session.get().id == id, 'reopen_history_changed')
    check(body(f.buf) == value(1) and vim.fn.readfile(f.path)[1] == value(0), 'question_changed_source')
    set(f.buf, 2)
    report.workflow.edit = request(f,
      'Do not use tools. Change only const Value = 2 to const Value = 3. In your explanation include the remembered token from our previous question and the current starting value 2. Return the structured edit response expected by HodoCode.', 'edit')
    check(body(f.buf) == value(3) and vim.fn.readfile(f.path)[1] == value(0), 'edit_not_buffer_only')
    check(session.get().id == id and #state.history == 4, 'workflow_history_changed')
    check(state.history[1].request_id == state.history[2].request_id
      and state.history[3].request_id == state.history[4].request_id
      and state.history[1].request_id ~= state.history[3].request_id, 'request_ids_invalid')
    check(state.history[4].content:find('HODO_ACP_FLOW_TOKEN', 1, true)
      and state.history[4].content:find('2', 1, true), 'continuation_context_missing')
    vim.api.nvim_buf_call(f.buf, function() vim.cmd('undo') end)
    check(body(f.buf) == value(2), 'undo_lost_manual_edit')
    vim.api.nvim_buf_call(f.buf, function() vim.cmd('redo') end)
    check(body(f.buf) == value(3), 'redo_failed')
    check(agent.baseline(f.buf).lines[1] == value(0), 'baseline_not_disk')
    check(diff.toggle(f.buf, agent.baseline), 'diff_not_visible')
    local marks = vim.api.nvim_buf_get_extmarks(f.buf, vim.api.nvim_create_namespace('HodoCodeInlineDiff'), 0, -1, { details = true })
    local virtual = false
    for _, mark in ipairs(marks) do
      for _, line in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(line) do if chunk[1]:find(value(0), 1, true) then virtual = true end end
      end
    end
    check(virtual, 'diff_missing_disk_baseline')
    check(not diff.toggle(f.buf, agent.baseline) and body(f.buf) == value(3), 'diff_hide_changed_text')
    vim.api.nvim_buf_call(f.buf, function() vim.cmd('write') end)
    check(vim.fn.readfile(f.path)[1] == value(3), 'explicit_write_failed')
    report.workflow.validated = true
  end
  reset()
  local prompt = 'Change only const Value = 0 to const Value = 1. Do not use tools. Return the structured edit response expected by HodoCode.'
  report.prompt, report.source = prompt, value(0) .. '\n'
  for _, transport in ipairs({ 'acp', 'json' }) do
    for sample = 1, sample_count do
      stage = transport .. '_sample_' .. sample
      reset()
      local case = fixture(stage, transport)
      local row = { sample = sample, transport = transport }
      report.samples[#report.samples + 1] = row
      row.initial = request(case, prompt, 'edit')
      check(body(case.buf) == value(1) and vim.fn.readfile(case.path)[1] == value(0), 'initial_edit_incorrect')
      set(case.buf, 0)
      -- Restore the same modified flag as the initial snapshot as well as the exact source.
      vim.bo[case.buf].modified = false
      row.continuation = request(case, prompt, 'edit')
      check(body(case.buf) == value(1) and vim.fn.readfile(case.path)[1] == value(0), 'continuation_edit_incorrect')
      check(#session.get().history == 4, 'pair_history_invalid')
    end
  end
  report.medians_ms = {}
  for _, transport in ipairs({ 'acp', 'json' }) do
    report.medians_ms[transport] = {}
    for _, kind in ipairs({ 'initial', 'continuation' }) do
      local values = {}
      for _, row in ipairs(report.samples) do
        if row.transport == transport then values[#values + 1] = row[kind].total_ms end
      end
      table.sort(values)
      local middle = math.floor(#values / 2)
      report.medians_ms[transport][kind] = #values % 2 == 0
        and (values[middle] + values[middle + 1]) / 2 or values[middle + 1]
    end
  end
  check(turns == turn_limit, 'unexpected_turn_count')
  report.profile_finish = scalar_status()
  check(vim.deep_equal(report.profile, report.profile_finish), 'profile_changed_during_trial')
  report.status = 'passed'
end
local ok, err = xpcall(run, debug.traceback)
local cleanup_ok = pcall(function() agent.shutdown(); chat.shutdown(); diff.shutdown() end)
local profile_ok, profile_finish = pcall(scalar_status)
if profile_ok then report.profile_finish = profile_finish end
if not cleanup_ok or not profile_ok or (report.profile and not vim.deep_equal(report.profile, profile_finish)) then
  ok, err = false, ': finalization_failed\n'
end
-- Only this script's own fixture tree is removed. Native fx history is deliberately retained.
if vim.fn.isdirectory(temp) == 1 then vim.fn.delete(temp, 'rf') end
report.model_turns, report.cleanup_ok = prior_turns + turns, cleanup_ok
report.current_run_model_turns, report.prior_model_turns = turns, prior_turns
if not ok then
  report.status = 'partial'
  report.failure_stage = stage
  report.failure_reason = tostring(err):match(': ([%w_]+)\n') or 'validation_failed'
end
vim.fn.writefile({ vim.json.encode(report) }, output)
if ok then
  print(('PASS: %d real-fx turns this run, %d cumulative; workflow validated, %d edit pairs per transport; docs/acp-benchmark-2026-11.json'):format(turns, prior_turns + turns, sample_count))
  vim.cmd('qa!')
else
  io.stderr:write('FAIL: ' .. stage .. ': ' .. report.failure_reason .. '; docs/acp-benchmark-2026-11.json\n')
  vim.cmd('cquit 1')
end
