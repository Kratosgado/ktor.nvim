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

---Split "/api/v1" into {"/api", "/v1"}. Every route level - whether it came
---from an explicit route("...") wrapper or is embedded directly in a bare
---verb call's own literal argument - gets decomposed into these atomic
---single-component pieces before building the tree. Without this, the same
---logical prefix written two different ways (one route("/api/v1") call vs.
---nested route("/api") { route("/v1") { ... } } vs. embedded directly in a
---wrapper-less post("/api/v1/test/reset") call) would each produce distinct,
---un-mergeable tree nodes - which is exactly what caused both "/api/v1"
---showing up as multiple separate siblings and endpoints with no route()
---wrapper at all (own_segment carrying their whole path) rendering as
---disconnected top-level entries instead of nesting under their real prefix.
---@param text string|nil
---@return string[]
local function split_path_segments(text)
  local pieces = {}
  if not text or text == "" then
    return pieces
  end
  for piece in text:gmatch("[^/]+") do
    table.insert(pieces, "/" .. piece)
  end
  return pieces
end

---@param current KtorTreeNode
---@param segment string
---@return KtorTreeNode
local function descend(current, segment)
  local key = "route:" .. segment
  local node = current._index[key]
  if not node then
    node = { kind = "route", label = segment, children = {}, _index = {} }
    table.insert(current.children, node)
    current._index[key] = node
  end
  return node
end

---Build a nested route tree from a flat endpoint list. Nodes are grouped by
---atomic path-component text rather than by which literal route("...") { }
---call (or bare verb-call literal) produced them, so the same logical prefix
---always merges into one node regardless of how the source code structures
---its route()/verb calls. Auth markers merge the same way - two
---authenticate("jwt") blocks anywhere under the same parent become one
---"jwt" node.
---@param endpoints KtorEndpoint[]
---@return KtorTreeNode root
function M.build_tree(endpoints)
  local root = { kind = "root", children = {}, _index = {} }

  for _, ep in ipairs(endpoints) do
    local current = root

    for i in ipairs(ep.route_scope_ranges) do
      local segment = (ep.route_scope_segments and ep.route_scope_segments[i]) or ""
      for _, piece in ipairs(split_path_segments(segment)) do
        current = descend(current, piece)
      end
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

    for _, piece in ipairs(split_path_segments(ep.own_segment)) do
      current = descend(current, piece)
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
