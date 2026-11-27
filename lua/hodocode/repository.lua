local M = {}
local uv = vim.uv or vim.loop
local session = require('hodocode.session')
local excluded = { ['.git'] = true, build = true, dist = true, target = true, node_modules = true, ['.cache'] = true }

function M.snapshots(root, target_path, limit)
  local result, total = {}, 0
  local target = session.realpath(target_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].modified
      and not vim.bo[buf].binary and vim.api.nvim_buf_get_name(buf) ~= '' then
      local scope = session.project({ root = root }, buf)
      if scope then
        local path = session.realpath(vim.api.nvim_buf_get_name(buf))
        local relative = path:sub(#scope + (scope == '/' and 1 or 2))
        local name = vim.fs.basename(path):lower()
        local skip = path == target or name == '.env' or name:match('^%.env%.')
          or name:match('%.pem$') or name:match('%.key$')
        for part in relative:gmatch('[^/]+') do skip = skip or excluded[part] end
        local stat = uv.fs_stat(path)
        if not skip and (not stat or stat.type == 'file') then
          if (vim.bo[buf].fileformat ~= 'unix' and vim.bo[buf].fileformat ~= 'dos')
            or (vim.bo[buf].fileencoding ~= '' and vim.bo[buf].fileencoding:lower() ~= 'utf-8') then
            return nil, 'invalid_buffer'
          end
          local bytes = vim.api.nvim_buf_get_offset(buf, vim.api.nvim_buf_line_count(buf))
          if bytes < 0 then return nil, 'invalid_buffer' end
          bytes = bytes - (vim.bo[buf].endofline and 0 or 1)
          if bytes > limit then return nil, 'size_limit' end
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local binary = false
          for _, line in ipairs(lines) do
            if line:find('\0', 1, true) or line:find('\n', 1, true) then binary = true; break end
            if line:find('\r', 1, true) then return nil, 'invalid_buffer' end
          end
          if not binary then
            if total + bytes > limit then return nil, 'size_limit' end
            local content = table.concat(lines, '\n') .. (vim.bo[buf].endofline and '\n' or '')
            if not pcall(vim.fn.json_encode, content) then return nil, 'invalid_buffer' end
            total = total + #content
            result[#result + 1] = { path = path, content = content }
          end
        end
      end
    end
  end
  return result
end

return M
