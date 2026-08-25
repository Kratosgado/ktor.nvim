local M = {}

---@class KtorEndpoint
---@field method string HTTP method, e.g. "GET"
---@field full_path string fully resolved path, e.g. "/api/v1/schools/{schoolId}/students/{id}"
---@field bufnr number buffer the verb call itself lives in (may differ from the file containing the top-level routing{} block, if reached through an extension function)
---@field def_range {start_row:number, start_col:number, end_row:number, end_col:number}
---@field route_scope_ranges table[] ranges of enclosing route("...") { } blocks, outermost first
---@field route_scope_segments string[] path segment text for each entry in route_scope_ranges, same order
---@field own_segment string the verb call's own literal path argument (e.g. "/students/{id}" in get("/students/{id}")), "" if bare
---@field auth_scheme string|nil name from the nearest enclosing authenticate("name") { }
---@field auth_range table|nil range of that enclosing authenticate(...) call, if any
---@field file string absolute path of the file `bufnr` corresponds to

---@type table<string, string> lowercase call name -> HTTP method
local VERBS = {
  get = "GET",
  post = "POST",
  put = "PUT",
  delete = "DELETE",
  patch = "PATCH",
}

-- Calls like `authRoutes(...)` inside a routing scope don't nest verbs
-- directly - the routes live inside a `fun Route.authRoutes() { ... }`
-- defined possibly in another file. Expanding through one of these when
-- resolving another (in case they call each other) needs a cap to avoid
-- runaway/cyclic recursion.
local MAX_EXPANSION_DEPTH = 12

---@type table<string, KtorEndpoint[]> absolute file path -> endpoints found in that file
local by_file = {}

---@type (fun(bufnr: number|nil))[]
local subscribers = {}

---@param bufnr number|nil nil means "everything was rescanned", a bufnr scopes the change
local function notify(bufnr)
  for _, fn in ipairs(subscribers) do
    local ok, err = pcall(fn, bufnr)
    if not ok then
      vim.notify("ktor.index: subscriber error: " .. tostring(err), vim.log.levels.WARN)
    end
  end
end

---Subscribe to re-index events.
---@param fn fun(bufnr: number|nil)
---@return fun() unsubscribe
function M.on_index_updated(fn)
  table.insert(subscribers, fn)
  return function()
    for i, f in ipairs(subscribers) do
      if f == fn then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

---@param bufnr number
---@param node TSNode
---@return string|nil
local function get_text(bufnr, node)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if ok then
    return text
  end
  return nil
end

---@param node TSNode
---@return {start_row:number, start_col:number, end_row:number, end_col:number}
local function node_range(node)
  local srow, scol, erow, ecol = node:range()
  return { start_row = srow, start_col = scol, end_row = erow, end_col = ecol }
end

---@param bufnr number
---@param call_expr TSNode
---@return string|nil
local function callee_name(bufnr, call_expr)
  for child in call_expr:iter_children() do
    if child:type() == "simple_identifier" then
      return get_text(bufnr, child)
    end
  end
  return nil
end

---@param s string|nil
---@return string|nil
local function strip_quotes(s)
  if not s then
    return nil
  end
  return (s:gsub('^"(.*)"$', "%1"))
end

---First string-literal argument of a call, e.g. the "/students/{id}" in get("/students/{id}").
---@param bufnr number
---@param call_expr TSNode
---@return string|nil
local function first_string_arg(bufnr, call_expr)
  for suffix in call_expr:iter_children() do
    if suffix:type() == "call_suffix" then
      for args in suffix:iter_children() do
        if args:type() == "value_arguments" then
          for arg in args:iter_children() do
            if arg:type() == "value_argument" then
              local found
              local function search(n)
                if found then
                  return
                end
                if n:type() == "string_literal" then
                  found = n
                  return
                end
                for c in n:iter_children() do
                  search(c)
                  if found then
                    return
                  end
                end
              end
              search(arg)
              if found then
                return strip_quotes(get_text(bufnr, found))
              end
            end
          end
        end
      end
    end
  end
  return nil
end

---@param segments string[]
---@return string
local function join_segments(segments)
  local parts = {}
  for _, seg in ipairs(segments) do
    if seg and seg ~= "" then
      local trimmed = (seg:gsub("/+$", ""))
      if trimmed:sub(1, 1) ~= "/" then
        trimmed = "/" .. trimmed
      end
      table.insert(parts, trimmed)
    end
  end
  local path = table.concat(parts)
  return path == "" and "/" or path
end

---@param node TSNode
---@return TSNode|nil
local function find_type_identifier(node)
  if node:type() == "type_identifier" then
    return node
  end
  for child in node:iter_children() do
    local found = find_type_identifier(child)
    if found then
      return found
    end
  end
  return nil
end

---Find every `fun Route.<name>(...) { ... }` extension function declared in
---a buffer - the common pattern for splitting a large Ktor app's routes
---across files (`fun Route.authRoutes(...) { route("/login") { ... } }`,
---called as just `authRoutes(...)` from the main routing {} block).
---@param bufnr number
---@return table<string, TSNode> name -> function_body node
local function collect_route_functions(bufnr)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "kotlin")
  if not ok_parser or not parser then
    return {}
  end
  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then
    return {}
  end

  local found = {}

  ---@param node TSNode
  local function visit(node)
    if node:type() == "function_declaration" then
      local receiver_text, name, body
      local past_receiver = false
      for child in node:iter_children() do
        if child:type() == "receiver_type" then
          local tid = find_type_identifier(child)
          if tid then
            receiver_text = get_text(bufnr, tid)
          end
          past_receiver = true
        elseif child:type() == "simple_identifier" and past_receiver and not name then
          name = get_text(bufnr, child)
        elseif child:type() == "function_body" then
          body = child
        end
      end
      if receiver_text == "Route" and name and body then
        found[name] = body
      end
    end
    for child in node:iter_children() do
      visit(child)
    end
  end

  local ok_visit = pcall(visit, trees[1]:root())
  if not ok_visit then
    return {}
  end
  return found
end

---@class KtorScanCtx
---@field path_segments string[]
---@field scope_ranges table[]
---@field auth_scheme string|nil
---@field auth_range table|nil
---@field in_scope boolean whether we're actually inside a routing{} block right now - false while just walking a file top-down looking for one, so a bare verb call in a `fun Route.*` body isn't mistaken for a real endpoint when that file is scanned on its own

---@class KtorRouteFunction
---@field bufnr number
---@field file string
---@field body TSNode

---Walk a buffer's own routing{} entry points, expanding into referenced
---`fun Route.*` extension functions (possibly in other files) wherever an
---unresolved call inside a routing scope matches a known one.
---@param bufnr number
---@param file string
---@param route_functions table<string, KtorRouteFunction>
---@return KtorEndpoint[]
local function scan_buffer(bufnr, file, route_functions)
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "kotlin")
  if not ok_parser or not parser then
    return {}
  end

  local ok_tree, trees = pcall(parser.parse, parser)
  if not ok_tree or not trees or not trees[1] then
    return {}
  end

  local endpoints = {}

  ---@param cur_bufnr number
  ---@param cur_file string
  ---@param node TSNode
  ---@param ctx KtorScanCtx
  ---@param depth number
  local function walk(cur_bufnr, cur_file, node, ctx, depth)
    if node:type() == "call_expression" then
      local name = callee_name(cur_bufnr, node)
      if name == "routing" then
        local new_ctx = vim.tbl_extend("force", ctx, { in_scope = true })
        for child in node:iter_children() do
          walk(cur_bufnr, cur_file, child, new_ctx, depth)
        end
        return
      elseif name == "route" then
        local seg = first_string_arg(cur_bufnr, node) or ""
        local new_ctx = {
          path_segments = vim.list_extend(vim.deepcopy(ctx.path_segments), { seg }),
          scope_ranges = vim.list_extend(vim.deepcopy(ctx.scope_ranges), { node_range(node) }),
          auth_scheme = ctx.auth_scheme,
          auth_range = ctx.auth_range,
          in_scope = ctx.in_scope,
        }
        for child in node:iter_children() do
          walk(cur_bufnr, cur_file, child, new_ctx, depth)
        end
        return
      elseif name == "authenticate" then
        local scheme = first_string_arg(cur_bufnr, node)
        local new_ctx = {
          path_segments = ctx.path_segments,
          scope_ranges = ctx.scope_ranges,
          auth_scheme = scheme or ctx.auth_scheme,
          auth_range = scheme and node_range(node) or ctx.auth_range,
          in_scope = ctx.in_scope,
        }
        for child in node:iter_children() do
          walk(cur_bufnr, cur_file, child, new_ctx, depth)
        end
        return
      elseif VERBS[name] and ctx.in_scope then
        local seg = first_string_arg(cur_bufnr, node) or ""
        local full_path = join_segments(vim.list_extend(vim.deepcopy(ctx.path_segments), { seg }))
        table.insert(endpoints, {
          method = VERBS[name],
          full_path = full_path,
          bufnr = cur_bufnr,
          def_range = node_range(node),
          route_scope_ranges = vim.deepcopy(ctx.scope_ranges),
          route_scope_segments = vim.deepcopy(ctx.path_segments),
          own_segment = seg,
          auth_scheme = ctx.auth_scheme,
          auth_range = ctx.auth_range,
          file = cur_file,
        })
        -- fall through: still walk children below in case of nested calls
      elseif name and route_functions[name] and depth < MAX_EXPANSION_DEPTH then
        -- Unresolved call at a routing-scope statement position matching a
        -- known `fun Route.<name>()` elsewhere - inline its body here,
        -- carrying over the current path/auth context.
        local target = route_functions[name]
        local ok_expand, err = pcall(walk, target.bufnr, target.file, target.body, ctx, depth + 1)
        if not ok_expand then
          vim.notify("ktor.index: failed expanding " .. name .. "(): " .. tostring(err), vim.log.levels.DEBUG)
        end
        return
      end
    end
    for child in node:iter_children() do
      walk(cur_bufnr, cur_file, child, ctx, depth)
    end
  end

  local root = trees[1]:root()
  local ok_walk, err = pcall(
    walk,
    bufnr,
    file,
    root,
    { path_segments = {}, scope_ranges = {}, auth_scheme = nil, auth_range = nil, in_scope = false },
    0
  )
  if not ok_walk then
    vim.notify("ktor.index: parse walk failed for " .. file .. ": " .. tostring(err), vim.log.levels.DEBUG)
    return {}
  end

  return endpoints
end

---@param path string
---@return string
local function file_key(path)
  return vim.fn.fnamemodify(path, ":p")
end

---Load (without displaying) the buffer for a Kotlin file, tagging its filetype.
---@param file string
---@return number|nil bufnr
local function ensure_buffer(file)
  local bufnr = vim.fn.bufadd(file)
  if not bufnr or bufnr == 0 then
    return nil
  end
  local ok = pcall(vim.fn.bufload, bufnr)
  if not ok then
    return nil
  end
  vim.bo[bufnr].buflisted = false
  if vim.bo[bufnr].filetype ~= "kotlin" then
    vim.bo[bufnr].filetype = "kotlin"
  end
  return bufnr
end

---Rescan every *.kt file under cwd: first collect all `fun Route.*`
---extension functions project-wide (so call sites can resolve regardless of
---scan order), then walk each file's own routing{} entry points, expanding
---into referenced functions - possibly defined in a different file - as
---needed. Runs on every debounced edit, not just explicit refresh(), since
---an edit anywhere can change what a routing{} block elsewhere resolves to.
---@param notify_bufnr number|nil forwarded to notify() once done
local function full_rescan(notify_bufnr)
  local cwd = vim.fn.getcwd()
  local files = vim.fn.globpath(cwd, "**/*.kt", false, true)

  ---@type table<string, KtorRouteFunction>
  local route_functions = {}
  ---@type table<string, number>
  local file_bufnrs = {}

  for _, file in ipairs(files) do
    local key = file_key(file)
    local bufnr = ensure_buffer(key)
    if bufnr then
      file_bufnrs[key] = bufnr
      for name, body in pairs(collect_route_functions(bufnr)) do
        route_functions[name] = { bufnr = bufnr, file = key, body = body }
      end
    end
  end

  local new_by_file = {}
  for key, bufnr in pairs(file_bufnrs) do
    new_by_file[key] = scan_buffer(bufnr, key, route_functions)
  end
  by_file = new_by_file

  notify(notify_bufnr)
end

---Force a full project-wide rescan.
function M.refresh()
  full_rescan(nil)
end

---@return KtorEndpoint[]
function M.get_endpoints()
  local all = {}
  for _, endpoints in pairs(by_file) do
    vim.list_extend(all, endpoints)
  end
  return all
end

---@type table<number, uv_timer_t>
local debounce_timers = {}
local DEBOUNCE_MS = 150

---@param bufnr number
local function debounced_rescan(bufnr)
  local existing = debounce_timers[bufnr]
  if existing then
    existing:stop()
    existing:close()
  end
  local timer = vim.uv.new_timer()
  debounce_timers[bufnr] = timer
  timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      timer:stop()
      timer:close()
      debounce_timers[bufnr] = nil
      full_rescan(bufnr)
    end)
  )
end

local augroup = vim.api.nvim_create_augroup("KtorIndex", { clear = true })
vim.api.nvim_create_autocmd({ "BufWritePost", "TextChanged", "TextChangedI" }, {
  group = augroup,
  pattern = "*.kt",
  callback = function(args)
    debounced_rescan(args.buf)
  end,
})

return M
