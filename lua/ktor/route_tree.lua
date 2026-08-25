local M = {}

local highlights = require("ktor.highlights")

---@class KtorTreeNode
---@field kind "root"|"route"|"auth"|"endpoint"
---@field label string|nil display text for route/auth nodes
---@field bufnr number|nil
---@field range table|nil jump target range
---@field method string|nil set when kind == "endpoint"
---@field full_path string|nil set when kind == "endpoint"
---@field endpoint KtorEndpoint|nil set when kind == "endpoint"
---@field children KtorTreeNode[]

---Substring-match endpoints by full_path. Plain text, no fuzzy matching.
---@param endpoints KtorEndpoint[]
---@param query string|nil
---@return KtorEndpoint[]
function M.filter_endpoints(endpoints, query)
  if not query or query == "" then
    return endpoints
  end
  local out = {}
  for _, ep in ipairs(endpoints) do
    if ep.full_path:find(query, 1, true) then
      table.insert(out, ep)
    end
  end
  return out
end

---@param node KtorTreeNode
local function strip_internal(node)
  node._index = nil
  for _, child in ipairs(node.children) do
    strip_internal(child)
  end
end

---Build a nested route tree from a flat endpoint list. Nodes are grouped by
---PATH TEXT (route_scope_segments) rather than by which literal route("...")
---{ } call produced them: large Ktor apps commonly split routes across many
---files that each independently open their own `route("/api/v1") { ... }`,
---and those should all merge into one "/api/v1" node in the tree rather than
---appearing as separate siblings per file. Same idea for auth markers - two
---authenticate("jwt") blocks in different files merge into one "jwt" node.
---@param endpoints KtorEndpoint[]
---@return KtorTreeNode root
function M.build_tree(endpoints)
  local root = { kind = "root", children = {}, _index = {} }

  for _, ep in ipairs(endpoints) do
    local current = root

    for i, range in ipairs(ep.route_scope_ranges) do
      local segment = (ep.route_scope_segments and ep.route_scope_segments[i]) or ""
      local key = "route:" .. segment
      local node = current._index[key]
      if not node then
        node = { kind = "route", label = segment, bufnr = ep.bufnr, range = range, children = {}, _index = {} }
        table.insert(current.children, node)
        current._index[key] = node
      end
      current = node
    end

    if ep.auth_scheme then
      local key = "auth:" .. ep.auth_scheme
      local node = current._index[key]
      if not node then
        node = {
          kind = "auth",
          label = ep.auth_scheme,
          bufnr = ep.bufnr,
          range = ep.auth_range,
          children = {},
          _index = {},
        }
        table.insert(current.children, node)
        current._index[key] = node
      end
      current = node
    end

    table.insert(current.children, {
      kind = "endpoint",
      method = ep.method,
      full_path = ep.full_path,
      bufnr = ep.bufnr,
      range = ep.def_range,
      endpoint = ep,
      children = {},
      _index = {},
    })
  end

  strip_internal(root)
  return root
end

---@param node KtorTreeNode
---@param depth number
---@param lines string[]
---@param meta table[]
local function flatten(node, depth, lines, meta)
  for _, child in ipairs(node.children) do
    local indent = string.rep("  ", depth)
    local text
    local hl

    if child.kind == "endpoint" then
      local method_field = string.format("● %-6s", child.method)
      text = indent .. method_field .. " " .. child.full_path
      hl = { col_start = #indent, col_end = #indent + #method_field, group = highlights.method_hl(child.method) }
    elseif child.kind == "auth" then
      local marker = "🔒 " .. child.label
      text = indent .. marker
      hl = { col_start = #indent, col_end = #indent + #marker, group = "KtorAuthScheme" }
    else
      text = indent .. "▾ " .. child.label
    end

    table.insert(lines, text)
    table.insert(meta, { node = child, depth = depth, hl = hl })

    -- auth markers annotate their scope rather than adding their own
    -- indent level, so their children render at the same depth.
    local child_depth = (child.kind == "auth") and depth or (depth + 1)
    if #child.children > 0 then
      flatten(child, child_depth, lines, meta)
    end
  end
end

---Render a tree into buffer lines plus 1:1 per-line metadata for keymaps.
---@param root KtorTreeNode
---@return string[] lines
---@return table[] meta meta[i] = { node: KtorTreeNode, depth: number }
function M.render_lines(root)
  if #root.children == 0 then
    return { "No routes indexed yet." }, { { node = nil, depth = 0 } }
  end
  local lines, meta = {}, {}
  flatten(root, 0, lines, meta)
  return lines, meta
end

return M
