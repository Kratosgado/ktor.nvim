local M = {}

-- Sentinel for JSON `null`, since Lua tables can't hold a real `nil` value.
local NULL = setmetatable({}, { __tostring = function() return "null" end })

---@type table<string, fun():any>
local PRIMITIVE_PLACEHOLDERS = {
  String = function() return "" end,
  Char = function() return "" end,
  Int = function() return 0 end,
  Long = function() return 0 end,
  Short = function() return 0 end,
  Byte = function() return 0 end,
  Double = function() return 0.0 end,
  Float = function() return 0.0 end,
  BigDecimal = function() return 0 end,
  Boolean = function() return false end,
  UUID = function() return "" end,
  LocalDate = function() return "" end,
  LocalDateTime = function() return "" end,
  Instant = function() return "" end,
}

---@type table<string, boolean>
local LIST_TYPES = { List = true, MutableList = true, Set = true, MutableSet = true, Collection = true, Array = true }
---@type table<string, boolean>
local MAP_TYPES = { Map = true, MutableMap = true }

local MAX_DEPTH = 5

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

---@param bufnr number
---@param file string
---@return number|nil
local function ensure_buffer(bufnr_or_file)
  local bufnr = type(bufnr_or_file) == "number" and bufnr_or_file or vim.fn.bufadd(bufnr_or_file)
  if not bufnr or bufnr == 0 then
    return nil
  end
  if not pcall(vim.fn.bufload, bufnr) then
    return nil
  end
  return bufnr
end

---@class KtorParsedType
---@field name string
---@field nullable boolean
---@field args KtorParsedType[]

---@param bufnr number
---@param node TSNode a "user_type" or "nullable_type" node
---@return KtorParsedType
local function parse_type(bufnr, node)
  local nullable = false
  local inner = node
  if node:type() == "nullable_type" then
    nullable = true
    for c in node:iter_children() do
      if c:type() == "user_type" then
        inner = c
        break
      end
    end
  end

  local name, args = nil, {}
  for c in inner:iter_children() do
    if c:type() == "type_identifier" and not name then
      name = get_text(bufnr, c)
    elseif c:type() == "type_arguments" then
      for proj in c:iter_children() do
        if proj:type() == "type_projection" then
          for c2 in proj:iter_children() do
            if c2:type() == "user_type" or c2:type() == "nullable_type" then
              table.insert(args, parse_type(bufnr, c2))
            end
          end
        end
      end
    end
  end

  return { name = name or "", nullable = nullable, args = args }
end

---@class KtorClassEntry
---@field kind "class"|"enum"
---@field bufnr number
---@field node TSNode primary_constructor (kind="class") or enum_class_body (kind="enum")

---Every top-level-reachable `class`/`data class`/`enum class` declaration in
---a buffer, by name.
---@param bufnr number
---@return table<string, KtorClassEntry>
local function collect_classes(bufnr)
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
    if node:type() == "class_declaration" then
      local name, is_enum, ctor, enum_body
      for c in node:iter_children() do
        if c:type() == "type_identifier" and not name then
          name = get_text(bufnr, c)
        elseif c:type() == "enum" then
          is_enum = true
        elseif c:type() == "primary_constructor" then
          ctor = c
        elseif c:type() == "enum_class_body" then
          enum_body = c
        end
      end
      if name then
        if is_enum and enum_body then
          found[name] = { kind = "enum", bufnr = bufnr, node = enum_body }
        elseif ctor then
          found[name] = { kind = "class", bufnr = bufnr, node = ctor }
        end
      end
    end
    for c in node:iter_children() do
      visit(c)
    end
  end

  local ok_visit = pcall(visit, trees[1]:root())
  if not ok_visit then
    return {}
  end
  return found
end

---Lazy, on-demand project-wide class index - not part of the reactive
---ktor.index scan. Body generation is a rarer, user-triggered action, so
---this just re-walks every *.kt file each time rather than adding upkeep to
---the debounced edit path that ktor.index owns.
---@return table<string, KtorClassEntry>
---@param file string
---@return string joined raw file text, "" if unreadable
local function read_raw(file)
  local ok, lines = pcall(vim.fn.readfile, file)
  if not ok then
    return ""
  end
  return table.concat(lines, "\n")
end

---A full AST walk of every file - most of which have no class declaration
---at all - is the dominant cost here (same finding as ktor.index's project
---scan). Any `class`/`data class`/`enum class` declaration contains the
---literal text "class " somewhere, so a cheap plain-text check skips both
---the buffer load and the walk for files that plainly can't match.
---@return table<string, KtorClassEntry>
local function build_class_index()
  local files = vim.fn.globpath(vim.fn.getcwd(), "**/*.kt", false, true)
  local index = {}
  for _, file in ipairs(files) do
    if read_raw(file):find("class ", 1, true) then
      local bufnr = ensure_buffer(file)
      if bufnr then
        for name, entry in pairs(collect_classes(bufnr)) do
          index[name] = entry
        end
      end
    end
  end
  return index
end

---@param entry KtorClassEntry
---@return string|nil
local function first_enum_entry(entry)
  for c in entry.node:iter_children() do
    if c:type() == "enum_entry" then
      for c2 in c:iter_children() do
        if c2:type() == "simple_identifier" then
          return get_text(entry.bufnr, c2)
        end
      end
    end
  end
  return nil
end

local build_object -- forward decl, mutually recursive with placeholder_for_type

---@param t KtorParsedType
---@param class_index table<string, KtorClassEntry>
---@param depth number
---@return any
local function placeholder_for_type(t, class_index, depth)
  if t.nullable then
    return NULL
  end
  if depth > MAX_DEPTH then
    return { __kind = "object", fields = {} }
  end

  if PRIMITIVE_PLACEHOLDERS[t.name] then
    return PRIMITIVE_PLACEHOLDERS[t.name]()
  end
  if LIST_TYPES[t.name] then
    local elem = t.args[1] and placeholder_for_type(t.args[1], class_index, depth + 1)
      or { __kind = "object", fields = {} }
    return { __kind = "array", items = { elem } }
  end
  if MAP_TYPES[t.name] then
    return { __kind = "object", fields = {} }
  end

  local entry = class_index[t.name]
  if not entry then
    return { __kind = "object", fields = {} }
  end
  if entry.kind == "enum" then
    return first_enum_entry(entry) or ""
  end
  return build_object(entry, class_index, depth)
end

---@param entry KtorClassEntry
---@param class_index table<string, KtorClassEntry>
---@param depth number
---@return {__kind: "object", fields: {name:string, value:any}[]}
build_object = function(entry, class_index, depth)
  local fields = {}
  for param in entry.node:iter_children() do
    if param:type() == "class_parameter" then
      local name, type_node
      for c in param:iter_children() do
        if c:type() == "simple_identifier" and not name then
          name = get_text(entry.bufnr, c)
        elseif c:type() == "user_type" or c:type() == "nullable_type" then
          type_node = c
        end
      end
      if name and type_node then
        local t = parse_type(entry.bufnr, type_node)
        table.insert(fields, { name = name, value = placeholder_for_type(t, class_index, depth + 1) })
      end
    end
  end
  return { __kind = "object", fields = fields }
end

---@param value any
---@param indent number
---@return string
local function serialize(value, indent)
  local pad, pad_in = string.rep("  ", indent), string.rep("  ", indent + 1)

  if value == NULL then
    return "null"
  elseif type(value) == "string" then
    return '"' .. value .. '"'
  elseif type(value) == "number" or type(value) == "boolean" then
    return tostring(value)
  elseif type(value) == "table" and value.__kind == "array" then
    if #value.items == 0 then
      return "[]"
    end
    local parts = {}
    for _, item in ipairs(value.items) do
      table.insert(parts, pad_in .. serialize(item, indent + 1))
    end
    return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
  elseif type(value) == "table" and value.__kind == "object" then
    if #value.fields == 0 then
      return "{}"
    end
    local parts = {}
    for _, f in ipairs(value.fields) do
      table.insert(parts, pad_in .. '"' .. f.name .. '": ' .. serialize(f.value, indent + 1))
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  end
  return "null"
end

---@param bufnr number
---@param node TSNode
---@return boolean
local function is_receive_call(bufnr, node)
  if node:type() ~= "call_expression" then
    return false
  end
  local callee, has_type_args = nil, false
  for c in node:iter_children() do
    if c:type() == "navigation_expression" then
      callee = c
    elseif c:type() == "call_suffix" then
      for c2 in c:iter_children() do
        if c2:type() == "type_arguments" then
          has_type_args = true
        end
      end
    end
  end
  if not (callee and has_type_args) then
    return false
  end
  local text = get_text(bufnr, callee) or ""
  return text:match("%.receive$") ~= nil or text:match("%.receiveNullable$") ~= nil
end

---First `<T>` in a call.receive<T>()/call.receiveNullable<T>() call.
---@param bufnr number
---@param node TSNode
---@return string|nil
local function receive_type_name(bufnr, node)
  for c in node:iter_children() do
    if c:type() == "call_suffix" then
      for c2 in c:iter_children() do
        if c2:type() == "type_arguments" then
          for proj in c2:iter_children() do
            if proj:type() == "type_projection" then
              for c3 in proj:iter_children() do
                if c3:type() == "user_type" then
                  for c4 in c3:iter_children() do
                    if c4:type() == "type_identifier" then
                      return get_text(bufnr, c4)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return nil
end

---Find the first call.receive<T>()/call.receiveNullable<T>() anywhere under
---a node and return its T, or nil if there isn't one.
---@param bufnr number
---@param node TSNode
---@return string|nil
local function find_receive_type(bufnr, node)
  if is_receive_call(bufnr, node) then
    return receive_type_name(bufnr, node)
  end
  for c in node:iter_children() do
    local found = find_receive_type(bufnr, c)
    if found then
      return found
    end
  end
  return nil
end

---@param bufnr number
---@param range {start_row:number, start_col:number}
---@return TSNode|nil
local function call_expression_at(bufnr, range)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { range.start_row, range.start_col } })
  if not ok or not node then
    return nil
  end
  while node and node:type() ~= "call_expression" do
    node = node:parent()
  end
  return node
end

---Best-effort JSON body for an endpoint, from an explicit
---call.receive<T>() in its handler resolved against a project-wide
---data-class index. Returns nil (not an empty stub) if there's no
---call.receive<T>() at all, or T can't be resolved to a known class -
---callers should fall back to a generic stub in that case.
---@param ep KtorEndpoint
---@return string[]|nil lines
function M.body_lines_for(ep)
  local call_node = call_expression_at(ep.bufnr, ep.def_range)
  if not call_node then
    return nil
  end

  local type_name = find_receive_type(ep.bufnr, call_node)
  if not type_name then
    return nil
  end

  local class_index = build_class_index()
  local entry = class_index[type_name]
  if not entry or entry.kind ~= "class" then
    return nil
  end

  local ok, object = pcall(build_object, entry, class_index, 0)
  if not ok then
    return nil
  end

  return vim.split(serialize(object, 0), "\n", { plain = true })
end

return M
