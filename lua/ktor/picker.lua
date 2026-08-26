local M = {}

---@param name string
---@return boolean
local function has_module(name)
  return (pcall(require, name))
end

---@param ep KtorEndpoint
---@return string
local function location(ep)
  local rel = vim.fn.fnamemodify(ep.file, ":.")
  return string.format("%s:%d", rel, ep.def_range.start_row + 1)
end

---Switch to the window the picker was opened from (falling back to a split)
---before acting in a real buffer - both request.open() and jump need a
---normal, non-floating window, and the picker's own window is current while
---these callbacks run.
---@param prev_win number
local function focus_prev_win(prev_win)
  if vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  else
    vim.cmd("split")
  end
end

---@param endpoints KtorEndpoint[]
---@param prev_win number
local function open_fzf(endpoints, prev_win)
  local fzf = require("fzf-lua")
  local futils = require("fzf-lua.utils")
  local highlights = require("ktor.highlights")
  local jump = require("ktor.jump")

  -- Don't key the lookup by the full ANSI-colored line - fzf round-trips
  -- selections through its own process/pipe and there's no guarantee escape
  -- sequences survive byte-for-byte, so an exact-string match can silently
  -- fail to find anything. Instead embed a plain "file:line" suffix (never
  -- colored) and parse just that back out, the same way fzf-lua's own
  -- built-in pickers resolve a selection to an underlying value.
  ---@type table<string, KtorEndpoint>
  local by_location = {}
  local lines = {}
  for _, ep in ipairs(endpoints) do
    local badge = futils.ansi_from_hl(highlights.method_hl(ep.method), string.format("%-6s", ep.method))
    local auth = ep.auth_scheme and ("  [" .. ep.auth_scheme .. "]") or ""
    local loc = location(ep)
    local line = string.format("%s %s%s  %s", badge, ep.full_path, auth, loc)
    by_location[loc] = ep
    table.insert(lines, line)
  end

  ---@param selected string[]
  ---@return KtorEndpoint|nil
  local function resolve(selected)
    local raw = selected and selected[1] and futils.strip_ansi_coloring(selected[1])
    local loc = raw and raw:match("(%S+:%d+)%s*$")
    return loc and by_location[loc]
  end

  fzf.fzf_exec(lines, {
    prompt = "Ktor Endpoints> ",
    actions = {
      ["enter"] = function(selected)
        local ep = resolve(selected)
        if ep then
          jump.jump_to_range(ep.bufnr, ep.def_range)
        end
      end,
      ["ctrl-y"] = function(selected)
        local ep = resolve(selected)
        if ep then
          -- deferred: fzf-lua tears down its own window around this call,
          -- and the exact ordering isn't guaranteed - scheduling ensures
          -- that's finished before we touch window/buffer state ourselves.
          vim.schedule(function()
            focus_prev_win(prev_win)
            require("ktor.request").open(ep)
          end)
        end
      end,
    },
  })
end

---@param endpoints KtorEndpoint[]
---@param prev_win number
local function open_telescope(endpoints, prev_win)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")
  local highlights = require("ktor.highlights")
  local jump = require("ktor.jump")

  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 7 },
      { remaining = true },
    },
  })

  ---@param entry table
  local function make_display(entry)
    local suffix = entry.auth_scheme and ("  [" .. entry.auth_scheme .. "]") or ""
    return displayer({
      { entry.method, highlights.method_hl(entry.method) },
      entry.full_path .. suffix .. "  " .. entry.location,
    })
  end

  pickers
    .new({}, {
      prompt_title = "Ktor Endpoints",
      finder = finders.new_table({
        results = endpoints,
        entry_maker = function(ep)
          return {
            value = ep,
            display = make_display,
            ordinal = ep.method .. " " .. ep.full_path,
            method = ep.method,
            full_path = ep.full_path,
            auth_scheme = ep.auth_scheme,
            location = location(ep),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry and entry.value then
            jump.jump_to_range(entry.value.bufnr, entry.value.def_range)
          end
        end)
        local function generate_request()
          local entry = action_state.get_selected_entry()
          if entry and entry.value then
            actions.close(prompt_bufnr)
            focus_prev_win(prev_win)
            require("ktor.request").open(entry.value)
          end
        end
        map("i", "<C-y>", generate_request)
        map("n", "<C-y>", generate_request)
        return true
      end,
    })
    :find()
end

---Open a fuzzy picker over every indexed endpoint. Prefers fzf-lua, falls
---back to telescope.nvim; both are optional (only required if installed and
---selected), configurable via `picker.backend` ("auto"|"fzf"|"telescope").
function M.open()
  local endpoints = require("ktor.index").get_endpoints()
  if #endpoints == 0 then
    vim.notify("ktor: no endpoints indexed yet", vim.log.levels.INFO)
    return
  end

  table.sort(endpoints, function(a, b)
    if a.full_path == b.full_path then
      return a.method < b.method
    end
    return a.full_path < b.full_path
  end)

  local backend = require("ktor.config").get().picker.backend
  local prev_win = vim.api.nvim_get_current_win()

  local function try_fzf()
    if has_module("fzf-lua") then
      open_fzf(endpoints, prev_win)
      return true
    end
    return false
  end

  local function try_telescope()
    if has_module("telescope") then
      open_telescope(endpoints, prev_win)
      return true
    end
    return false
  end

  local opened
  if backend == "fzf" then
    opened = try_fzf()
  elseif backend == "telescope" then
    opened = try_telescope()
  else
    opened = try_fzf() or try_telescope()
  end

  if not opened then
    vim.notify("ktor: neither fzf-lua nor telescope.nvim is installed", vim.log.levels.WARN)
  end
end

return M
