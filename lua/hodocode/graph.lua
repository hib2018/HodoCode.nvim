local M = {}

function M.open(ctx, client, current, config)
  local ui = require('hodocode.ui')
  local buf, win = ui.float({ '読み込み中…' }, 'HodoCode 図', ctx)
  local kind, generation = 'deps', 0
  local function render(lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  local function load()
    generation = generation + 1
    local request = generation
    if kind == 'calls' and not current then
      render({ '関数呼び出し図: カーソル位置に関数がありません。', 'Tab: import依存へ切替  q: 閉じる' })
      return
    end
    local params = { kind = kind }
    if kind == 'calls' then params['function'] = current.ID end
    render({ '読み込み中…', 'Tab: import依存 / 関数呼び出し  q: 閉じる' })
    client:request('graph', params, function(result, err)
      if request ~= generation or not ctx.valid() or not vim.api.nvim_buf_is_valid(buf) then return end
      if err then render({ '図の取得に失敗しました: ' .. err, 'Tab: 表示対象切替  q: 閉じる' }); return end
      local title = kind == 'deps' and 'import依存' or ('関数呼び出し: ' .. current.ID)
      local lines = { '# ' .. title, 'Tab: 表示対象切替  q: 閉じる',
        string.format('ノード: %d / エッジ: %d', #result.nodes, #result.edges), '',
        'Mermaidソース表示（図の視覚レンダリングではありません）', '```mermaid' }
      vim.list_extend(lines, vim.split(result.mermaid, '\n', { plain = true }))
      lines[#lines + 1] = '```'
      render(lines)
      if config.graph_renderer then
        local ok, failure = pcall(config.graph_renderer, result, { buf = buf, win = win, root = ctx.root })
        if not ok then vim.notify('HodoCode: 図レンダラー: ' .. tostring(failure), vim.log.levels.ERROR) end
      end
    end)
  end
  vim.keymap.set('n', '<Tab>', function() kind = kind == 'deps' and 'calls' or 'deps'; load() end, { buffer = buf, nowait = true })
  load()
  return buf, win
end

return M
