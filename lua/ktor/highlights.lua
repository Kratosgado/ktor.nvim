local M = {}

---@type table<string, string>
M.method_groups = {
  GET = "KtorMethodGet",
  POST = "KtorMethodPost",
  PUT = "KtorMethodPut",
  DELETE = "KtorMethodDelete",
  PATCH = "KtorMethodPatch",
}

---@param method string
---@return string hl_group
function M.method_hl(method)
  return M.method_groups[(method or ""):upper()] or "KtorMethodGet"
end

-- default = true lets users override via nvim_set_hl without a load-order race
local defaults = {
  KtorMethodGet = { link = "DiagnosticOk" },
  KtorMethodPost = { link = "DiagnosticInfo" },
  KtorMethodPut = { link = "DiagnosticWarn" },
  KtorMethodPatch = { link = "DiagnosticWarn" },
  KtorMethodDelete = { link = "DiagnosticError" },
  KtorAuthScheme = { link = "Comment", italic = true },
}

function M.setup()
  for name, opts in pairs(defaults) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, opts))
  end
end

return M
