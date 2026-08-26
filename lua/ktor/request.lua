local M = {}

---@type table<string, boolean>
local BODY_METHODS = { POST = true, PUT = true, PATCH = true }

---Ktor path params use single braces ("/students/{id}"); kulala (like most
---.http tooling) uses double braces for variable substitution
---("/students/{{id}}").
---@param full_path string
---@return string
local function to_http_path(full_path)
  return (full_path:gsub("%{([%w_]+)%}", "{{%1}}"))
end

---Default local dev server, so the request is runnable with zero setup -
---it's a document-level `@var`, so anyone with a real kulala env
---(.env/http-client.env.json) can just delete this line instead.
local DEFAULT_BASE_URL = "http://localhost:8080"

---A single request block: a named `###` header, method + URL, an
---Authorization stub if it's auth-protected, and a Content-Type + empty
---JSON body for verbs that typically carry one. No `@base_url` line - that's
---document-level, added once by generate()/open(), not per block.
---@param ep KtorEndpoint
---@return string[]
local function request_block(ep)
  local lines = {}
  local auth_note = ep.auth_scheme and ("  [" .. ep.auth_scheme .. "]") or ""
  table.insert(lines, string.format("### %s %s%s", ep.method, ep.full_path, auth_note))
  table.insert(lines, string.format("%s {{base_url}}%s", ep.method, to_http_path(ep.full_path)))

  if ep.auth_scheme then
    table.insert(lines, "Authorization: Bearer {{token}}")
  end

  if BODY_METHODS[ep.method] then
    table.insert(lines, "Content-Type: application/json")
    table.insert(lines, "")
    -- best-effort: if the handler does call.receive<T>() and T resolves to
    -- a known data class, use a type-aware skeleton; otherwise a bare stub.
    local ok, body_lines = pcall(function()
      return require("ktor.body_gen").body_lines_for(ep)
    end)
    vim.list_extend(lines, (ok and body_lines) or { "{", "}" })
  end

  return lines
end

---Build a standalone kulala-ready .http document for a single endpoint: a
---`@base_url` default (so it runs with zero setup) followed by its request
---block.
---@param ep KtorEndpoint
---@return string
function M.generate(ep)
  local lines = { "@base_url = " .. DEFAULT_BASE_URL, "" }
  vim.list_extend(lines, request_block(ep))
  return table.concat(lines, "\n") .. "\n"
end

---A fixed, reused path inside the project (not a global cache dir) so
---kulala.nvim's own env-file discovery - which walks up parent directories
---looking for a .env/http-client.env.json - actually finds the project's
---env file, and repeated generations just overwrite the same scratch file
---instead of piling up new ones.
---@return string
local function request_file_path()
  return vim.fs.joinpath(vim.fn.getcwd(), ".ktor-nvim", "request.http")
end

---Generate the request and add it to the scratch .http file, put it on the
---unnamed/system registers, and open the file in the current window with
---the cursor on the new block's method/URL line. Deliberately NOT a floating
---window - if kulala.nvim is installed, running the request needs to
---`:split` to show the response, which floats can't do.
---
---kulala's .http format is built to hold multiple `###`-delimited requests
---in one document, so an *existing* file gets a new block appended (keeping
---its current `@base_url`/edits intact) rather than being clobbered; only a
---missing/empty file gets the full `@base_url` header written fresh.
---@param ep KtorEndpoint
function M.open(ep)
  local path = request_file_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")

  local existing = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  while #existing > 0 and existing[#existing] == "" do
    table.remove(existing)
  end

  local block = request_block(ep)
  vim.fn.setreg('"', table.concat(block, "\n") .. "\n")
  vim.fn.setreg("+", table.concat(block, "\n") .. "\n")

  local lines, block_start
  if #existing == 0 then
    lines = { "@base_url = " .. DEFAULT_BASE_URL, "" }
    block_start = #lines + 1
    vim.list_extend(lines, block)
  else
    lines = existing
    table.insert(lines, "")
    block_start = #lines + 1
    vim.list_extend(lines, block)
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "http"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.cmd("silent write!")

  -- block_start is the "### ..." header line; the method/URL line is next
  vim.api.nvim_win_set_cursor(0, { block_start + 1, 0 })
end

---Find the endpoint whose own def_range contains a buffer position, so a
---request can be generated straight from the Kotlin source - not just the
---route tree/picker - e.g. with the cursor sitting inside a get("/x") { }.
---@param bufnr number
---@param row number 0-indexed
---@return KtorEndpoint|nil
local function endpoint_at(bufnr, row)
  local match
  for _, ep in ipairs(require("ktor.index").get_endpoints()) do
    if ep.bufnr == bufnr and row >= ep.def_range.start_row and row <= ep.def_range.end_row then
      if not match or (ep.def_range.end_row - ep.def_range.start_row) < (match.def_range.end_row - match.def_range.start_row) then
        match = ep
      end
    end
  end
  return match
end

---Generate a request for whatever endpoint contains the cursor in the
---current buffer (see endpoint_at). Notifies instead of erroring if the
---cursor isn't inside any indexed endpoint.
function M.open_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local ep = endpoint_at(bufnr, row)
  if not ep then
    vim.notify("ktor: no endpoint at cursor", vim.log.levels.INFO)
    return
  end
  M.open(ep)
end

return M
