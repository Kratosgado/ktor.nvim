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

  vim.api.nvim_create_user_command("KtorCodeLensEnable", function()
    require("ktor.codelens").enable()
  end, { desc = "Enable Ktor endpoint code lens" })

  vim.api.nvim_create_user_command("KtorCodeLensDisable", function()
    require("ktor.codelens").disable()
  end, { desc = "Disable Ktor endpoint code lens" })

  vim.api.nvim_create_user_command("KtorRouteTree", function(cmd_opts)
    local query = cmd_opts.args ~= "" and cmd_opts.args or nil
    require("ktor.ui.tree_window").open(query)
  end, { nargs = "?", desc = "Open the Ktor route tree" })
end

return M
