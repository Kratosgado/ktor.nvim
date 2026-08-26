local M = {}

local NS = vim.api.nvim_create_namespace("ktor_diagnostics")

---Collapse "{schoolId}", "{id}", etc into a single placeholder so two
---routes that differ only in a path-param NAME (e.g. "/students/{id}" vs
---"/students/{studentId}") are recognized as structurally the same route,
---which Ktor's router would treat as ambiguous.
---@param full_path string
---@return string
local function normalize(full_path)
  return (full_path:gsub("%{[^}]+%}", "{}"))
end

---@param ep KtorEndpoint
---@return string
local function short_loc(ep)
  return vim.fn.fnamemodify(ep.file, ":t") .. ":" .. (ep.def_range.start_row + 1)
end

---@return table<number, table[]>
local function compute()
  local index = require("ktor.index")
  local endpoints = index.get_endpoints()

  ---@type table<string, KtorEndpoint[]>
  local exact = {}
  ---@type table<string, KtorEndpoint[]>
  local structural = {}

  for _, ep in ipairs(endpoints) do
    local ekey = ep.method .. " " .. ep.full_path
    exact[ekey] = exact[ekey] or {}
    table.insert(exact[ekey], ep)

    local skey = ep.method .. " " .. normalize(ep.full_path)
    structural[skey] = structural[skey] or {}
    table.insert(structural[skey], ep)
  end

  ---@type table<number, table[]>
  local by_buf = {}

  ---@param ep KtorEndpoint
  local function add(ep, message, severity)
    by_buf[ep.bufnr] = by_buf[ep.bufnr] or {}
    table.insert(by_buf[ep.bufnr], {
      lnum = ep.def_range.start_row,
      col = ep.def_range.start_col,
      end_lnum = ep.def_range.end_row,
      end_col = ep.def_range.end_col,
      message = message,
      severity = severity,
      source = "ktor",
    })
  end

  for _, group in pairs(exact) do
    if #group > 1 then
      for _, ep in ipairs(group) do
        local others = {}
        for _, other in ipairs(group) do
          if other ~= ep then
            table.insert(others, short_loc(other))
          end
        end
        add(
          ep,
          string.format("Duplicate route: %s %s also defined at %s", ep.method, ep.full_path, table.concat(others, ", ")),
          vim.diagnostic.severity.WARN
        )
      end
    end
  end

  for _, group in pairs(structural) do
    if #group > 1 then
      -- skip groups that are actually identical paths - already reported above
      local first_path = group[1].full_path
      local all_identical = true
      for _, ep in ipairs(group) do
        if ep.full_path ~= first_path then
          all_identical = false
          break
        end
      end
      if not all_identical then
        for _, ep in ipairs(group) do
          local others = {}
          for _, other in ipairs(group) do
            if other ~= ep then
              table.insert(others, other.full_path .. " (" .. short_loc(other) .. ")")
            end
          end
          add(
            ep,
            string.format(
              "Ambiguous route: %s %s overlaps with %s",
              ep.method,
              ep.full_path,
              table.concat(others, ", ")
            ),
            vim.diagnostic.severity.WARN
          )
        end
      end
    end
  end

  for _, call in ipairs(index.get_unresolved_calls()) do
    by_buf[call.bufnr] = by_buf[call.bufnr] or {}
    table.insert(by_buf[call.bufnr], {
      lnum = call.range.start_row,
      col = call.range.start_col,
      end_lnum = call.range.end_row,
      end_col = call.range.end_col,
      message = string.format(
        "Unresolved route call: %s() doesn't match any known route/verb or `fun Route.%s()`",
        call.name,
        call.name
      ),
      severity = vim.diagnostic.severity.HINT,
      source = "ktor",
    })
  end

  return by_buf
end

---@type table<number, boolean>
local last_bufs = {}

---Recompute and apply diagnostics for every affected buffer, clearing any
---buffer that no longer has anything to report.
function M.refresh()
  if not require("ktor.config").get().diagnostics.enabled then
    for bufnr in pairs(last_bufs) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.diagnostic.set(NS, bufnr, {})
      end
    end
    last_bufs = {}
    return
  end

  local by_buf = compute()

  for bufnr in pairs(last_bufs) do
    if vim.api.nvim_buf_is_valid(bufnr) and not by_buf[bufnr] then
      vim.diagnostic.set(NS, bufnr, {})
    end
  end

  last_bufs = {}
  for bufnr, diags in pairs(by_buf) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.diagnostic.set(NS, bufnr, diags)
      last_bufs[bufnr] = true
    end
  end
end

local initialized = false

function M.setup()
  if initialized then
    return
  end
  initialized = true

  require("ktor.index").on_index_updated(function()
    M.refresh()
  end)
end

return M
