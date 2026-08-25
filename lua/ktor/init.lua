local M = {}

---@param opts KtorConfig|nil
function M.setup(opts)
  require("ktor.config").setup(opts)
  require("ktor.highlights").setup()
  require("ktor.index")
  require("ktor.codelens").setup()
  require("ktor.commands").setup()
end

return M
