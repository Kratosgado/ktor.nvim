local M = {}

---Jump the current window to a range inside a (possibly unloaded) buffer.
---Shared by the code lens, route tree, and endpoint picker features.
---@param bufnr number
---@param range {start_row:number, start_col:number, end_row?:number, end_col?:number}
function M.jump_to_range(bufnr, range)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.fn.bufload(bufnr)

  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(0, math.min(range.start_row, line_count - 1))
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local col = math.max(0, math.min(range.start_col, #line))

  vim.api.nvim_win_set_cursor(win, { row + 1, col })
  vim.cmd("normal! zz")
end

return M
