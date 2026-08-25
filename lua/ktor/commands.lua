local M = {}

local initialized = false

function M.setup()
  if initialized then
    return
  end
  initialized = true

  vim.api.nvim_create_user_command("KtorCodeLensToggle", function()
    require("ktor.codelens").toggle()
  end, { desc = "Toggle Ktor endpoint code lens" })

  vim.api.nvim_create_user_command("KtorRouteTree", function(cmd_opts)
    local query = cmd_opts.args ~= "" and cmd_opts.args or nil
    require("ktor.ui.tree_window").open(query)
  end, { nargs = "?", desc = "Open the Ktor route tree" })

  vim.api.nvim_create_user_command("KtorRefresh", function()
    require("ktor.index").refresh()
  end, { desc = "Full project-wide Ktor route rescan" })

  vim.api.nvim_create_user_command("KtorEndpoints", function()
    require("ktor.picker").open()
  end, { desc = "Fuzzy-find Ktor endpoints (fzf-lua or telescope)" })
end

return M
