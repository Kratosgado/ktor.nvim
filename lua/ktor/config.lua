local M = {}

---@class KtorConfig
---@field code_lens {enabled: boolean, style: "virt_lines"|"eol"}
---@field route_tree {display: "float"|"split", width: number, split_side: "left"|"right"}
M.defaults = {
  code_lens = {
    enabled = true,
    style = "virt_lines",
  },
  route_tree = {
    display = "float",
    width = 60,
    split_side = "left",
  },
}

M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
---@return KtorConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

---@return KtorConfig
function M.get()
  return M.options
end

return M
