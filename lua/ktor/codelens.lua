local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("ktor_codelens")
local augroup = vim.api.nvim_create_augroup("KtorCodeLens", { clear = true })

---@type boolean
M._enabled = true
---@type boolean
local initialized = false

-- No method text: the source line right below/beside this already reads
-- get(/post(/etc, so spelling out "GET" again would just be noise. The
-- bullet's color is what carries the verb at a glance.
---@param prefix string
---@return {[1]:string,[2]:string}[]
local function build_chunks(method, full_path, auth_scheme, prefix)
  local highlights = require("ktor.highlights")
  local method_hl = highlights.method_hl(method)
  local chunks = {
    { prefix .. "● ", method_hl },
    { full_path, "Comment" },
  }
  if auth_scheme then
    table.insert(chunks, { "  [" .. auth_scheme .. "]", "KtorAuthScheme" })
  end
  return chunks
end

---@param bufnr number
---@param ep KtorEndpoint
---@param style "virt_lines"|"eol"
local function render_endpoint(bufnr, ep, style)
  local row = ep.def_range.start_row
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  -- ranges can go briefly stale between an edit and the next debounced
  -- rescan; skip instead of erroring on an out-of-range row.
  if row < 0 or row >= line_count then
    return
  end

  if style == "eol" then
    local chunks = build_chunks(ep.method, ep.full_path, ep.auth_scheme, "  ")
    vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, 0, {
      virt_text = chunks,
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  else
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local indent = line:match("^%s*") or ""
    local chunks = build_chunks(ep.method, ep.full_path, ep.auth_scheme, indent)
    vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, row, 0, {
      virt_lines = { chunks },
      virt_lines_above = true,
    })
  end
end

---Redraw code lens extmarks for a single buffer. Skips entirely if the
---buffer isn't Kotlin or has no indexed endpoints.
---@param bufnr number
function M.render_buffer(bufnr)
  if not M._enabled then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].filetype ~= "kotlin" then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)

  local index = require("ktor.index")
  local endpoints = {}
  for _, ep in ipairs(index.get_endpoints()) do
    if ep.bufnr == bufnr then
      table.insert(endpoints, ep)
    end
  end
  if #endpoints == 0 then
    return
  end

  local style = require("ktor.config").get().code_lens.style
  for _, ep in ipairs(endpoints) do
    local ok, err = pcall(render_endpoint, bufnr, ep, style)
    if not ok then
      vim.notify("ktor.codelens: failed to render endpoint: " .. tostring(err), vim.log.levels.DEBUG)
    end
  end
end

---Redraw every currently loaded Kotlin buffer.
function M.render_all_loaded()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "kotlin" then
      M.render_buffer(bufnr)
    end
  end
end

local function clear_all_loaded()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    end
  end
end

function M.enable()
  M._enabled = true
  M.render_all_loaded()
end

function M.disable()
  M._enabled = false
  clear_all_loaded()
end

function M.toggle()
  if M._enabled then
    M.disable()
  else
    M.enable()
  end
end

function M.setup()
  if initialized then
    return
  end
  initialized = true

  M._enabled = require("ktor.config").get().code_lens.enabled

  require("ktor.index").on_index_updated(function(bufnr)
    if bufnr then
      M.render_buffer(bufnr)
    else
      M.render_all_loaded()
    end
  end)

  vim.api.nvim_create_autocmd("FileType", {
    group = augroup,
    pattern = "kotlin",
    callback = function(args)
      M.render_buffer(args.buf)
    end,
  })
end

return M
