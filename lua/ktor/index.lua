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

---@type table<string, KtorEndpoint[]> absolute file path -> endpoints found scanning that file as a root
local by_file = {}

---@class KtorRouteFunctionEntry
---@field bufnr number
---@field file string
---@field body TSNode

---@type table<string, KtorRouteFunctionEntry> `fun Route.<name>()` name -> where it's defined, project-wide
local route_functions = {}

---@type table<string, string[]> file -> names it currently contributes to route_functions
local route_functions_by_file = {}

---@type table<string, table<string, boolean>> file -> set of root files whose last scan expanded through it
local dependents = {}

---@type table<string, table<string, boolean>> root file -> set of files its last scan expanded through
local scan_deps = {}

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
---@param route_fns table<string, KtorRouteFunction>
---@param deps table<string, boolean> output: every file reached via expansion during this scan
---@return KtorEndpoint[]
local function scan_buffer(bufnr, file, route_fns, deps)
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
      elseif name and route_fns[name] and depth < MAX_EXPANSION_DEPTH then
        -- Unresolved call at a routing-scope statement position matching a
        -- known `fun Route.<name>()` elsewhere - inline its body here,
        -- carrying over the current path/auth context.
        local target = route_fns[name]
        deps[target.file] = true
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

---Record which files a root file's scan expanded through, so a later edit
---to any of them knows to re-walk that root (see `dependents`/`scan_deps`).
---Removes stale edges left over from a previous scan of the same root.
---@param root_file string
---@param new_deps table<string, boolean>
local function update_dependents(root_file, new_deps)
  local old_deps = scan_deps[root_file] or {}
  for dep in pairs(old_deps) do
    if not new_deps[dep] and dependents[dep] then
      dependents[dep][root_file] = nil
    end
  end
  for dep in pairs(new_deps) do
    dependents[dep] = dependents[dep] or {}
    dependents[dep][root_file] = true
  end
  scan_deps[root_file] = new_deps
end

---Full project-wide rescan: collect every `fun Route.*` extension function
---across all files first (so call sites resolve regardless of scan order),
---then walk each file's own routing{} entry points, expanding into
---referenced functions - possibly in a different file - as needed. This is
---the only path that walks the *whole* project; only call it for an
---explicit, user-requested refresh (see M.refresh / :KtorRefresh) - a debounced
---per-edit rescan uses the far cheaper smart_rescan below instead.
local function full_rescan()
  local cwd = vim.fn.getcwd()
  local files = vim.fn.globpath(cwd, "**/*.kt", false, true)

  route_functions = {}
  route_functions_by_file = {}
  ---@type table<string, number>
  local file_bufnrs = {}

  for _, file in ipairs(files) do
    local key = file_key(file)
    local bufnr = ensure_buffer(key)
    if bufnr then
      file_bufnrs[key] = bufnr
      local owned = {}
      for name, body in pairs(collect_route_functions(bufnr)) do
        route_functions[name] = { bufnr = bufnr, file = key, body = body }
        table.insert(owned, name)
      end
      route_functions_by_file[key] = owned
    end
  end

  local new_by_file = {}
  dependents = {}
  scan_deps = {}
  for key, bufnr in pairs(file_bufnrs) do
    local deps = {}
    new_by_file[key] = scan_buffer(bufnr, key, route_functions, deps)
    update_dependents(key, deps)
  end
  by_file = new_by_file

  notify(nil)
end

---Force a full project-wide rescan. The only place that walks every file -
---call explicitly (:KtorRefresh, or the route tree's `R`), not on each edit.
function M.refresh()
  full_rescan()
end

---Lightweight rescan for a single edited buffer: refreshes just this file's
---own `fun Route.*` declarations (so callers elsewhere see fresh bodies),
---then re-walks only this file's own routing{} entry points plus whichever
---OTHER root files' last scan expanded through it - not the whole project.
---A brand-new file that hasn't been scanned yet (never opened/edited this
---session) won't be discovered by referencing it elsewhere until the next
---M.refresh(); that's expected, not a bug - full scans are opt-in now.
---@param bufnr number
local function smart_rescan(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local file = file_key(name)

  local old_owned = route_functions_by_file[file] or {}
  local fresh = collect_route_functions(bufnr)
  for _, old_name in ipairs(old_owned) do
    if not fresh[old_name] then
      route_functions[old_name] = nil
    end
  end
  local owned = {}
  for fn_name, body in pairs(fresh) do
    route_functions[fn_name] = { bufnr = bufnr, file = file, body = body }
    table.insert(owned, fn_name)
  end
  route_functions_by_file[file] = owned

  ---@type table<string, boolean>
  local roots = { [file] = true }
  for root in pairs(dependents[file] or {}) do
    roots[root] = true
  end

  for root_file in pairs(roots) do
    local root_bufnr = ensure_buffer(root_file)
    if root_bufnr then
      local deps = {}
      by_file[root_file] = scan_buffer(root_bufnr, root_file, route_functions, deps)
      update_dependents(root_file, deps)
    else
      by_file[root_file] = nil
    end
  end

  notify(bufnr)
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
      smart_rescan(bufnr)
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
