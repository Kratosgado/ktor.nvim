local M = {}

local NS = vim.api.nvim_create_namespace("ktor_tree")

---@class KtorTreeWindowState
---@field bufnr number|nil
---@field winid number|nil
---@field prev_win number|nil window to jump in, i.e. the one the tree was opened from
---@field unsubscribe (fun())|nil
---@field query string|nil
---@field meta table[]
local state = {
  bufnr = nil,
  winid = nil,
  prev_win = nil,
  unsubscribe = nil,
  query = nil,
  meta = {},
}

local function is_open()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

local close

local function build_and_render()
  local route_tree = require("ktor.route_tree")
  local index = require("ktor.index")

  local endpoints = route_tree.filter_endpoints(index.get_endpoints(), state.query)
  local tree = route_tree.build_tree(endpoints)
  local lines, meta = route_tree.render_lines(tree)
  state.meta = meta

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, NS, 0, -1)
  for i, entry in ipairs(meta) do
    if entry.hl then
      vim.api.nvim_buf_set_extmark(state.bufnr, NS, i - 1, entry.hl.col_start, {
        end_col = entry.hl.col_end,
        hl_group = entry.hl.group,
      })
    end
  end
end

local function jump_under_cursor()
  if not is_open() then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.winid)[1]
  local entry = state.meta[row]
  if not entry or not entry.node then
    return
  end
  local node = entry.node
  if not ((node.kind == "endpoint" or node.kind == "auth") and node.range and node.bufnr) then
    return
  end

  local is_float = require("ktor.config").get().route_tree.display == "float"

  -- Jump in the window the tree was opened from, not the tree's own window
  -- (jump.jump_to_range operates on the current window; doing this in-place
  -- would replace the tree's scratch buffer, and bufhidden=wipe deletes it).
  if state.prev_win and vim.api.nvim_win_is_valid(state.prev_win) then
    vim.api.nvim_set_current_win(state.prev_win)
  else
    -- no valid window to jump in (e.g. tree was the only window left) -
    -- split off a new one rather than clobbering the tree's own buffer.
    vim.cmd("split")
  end

  -- A float sits on top of the editor like a picker; jumping should
  -- dismiss it. A split behaves like a persistent sidebar and stays open.
  if is_float then
    close()
  end

  require("ktor.jump").jump_to_range(node.bufnr, node.range)
end

---Used as a 'foldtext' callback: swaps the expanded arrow for the collapsed
---one so a closed fold reads like a toggled node, not a "+-- N lines" banner.
function M._foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  return (line:gsub("▾", "▸", 1))
end

---Used as a 'foldexpr' callback, driven by each line's tree depth
---(state.meta[i].depth). A header line whose next line is *deeper* opens a
---fold starting at itself (">N"), so the fold covers "header + children" as
---one block; every other line just reports its own depth. Plain
---foldmethod=indent can't do this — it always excludes the header line from
---its own fold.
function M._foldexpr()
  local lnum = vim.v.lnum
  local entry = state.meta[lnum]
  if not entry then
    return 0
  end
  local next_entry = state.meta[lnum + 1]
  if next_entry and next_entry.depth > entry.depth then
    return ">" .. tostring(next_entry.depth)
  end
  return entry.depth
end

close = function()
  if state.unsubscribe then
    state.unsubscribe()
    state.unsubscribe = nil
  end
  if is_open() then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
  state.bufnr = nil
end
M.close = close

local function create_window()
  local cfg = require("ktor.config").get().route_tree

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "ktortree"
  vim.bo[bufnr].swapfile = false

  local winid
  if cfg.display == "split" then
    local side = cfg.split_side == "right" and "botright" or "topleft"
    vim.cmd("vertical " .. side .. " " .. cfg.width .. "split")
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
  else
    local width = cfg.width
    local height = math.floor(vim.o.lines * 0.7)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Ktor Route Tree ",
      title_pos = "center",
    })
  end

  vim.wo[winid].foldmethod = "expr"
  vim.wo[winid].foldexpr = "v:lua.require'ktor.ui.tree_window'._foldexpr()"
  vim.wo[winid].foldminlines = 0
  vim.wo[winid].foldenable = true
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].foldtext = "v:lua.require'ktor.ui.tree_window'._foldtext()"

  return bufnr, winid
end

---@param bufnr number
local function set_keymaps(bufnr)
  local opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set("n", "<Tab>", "za", opts)
  vim.keymap.set("n", "<CR>", "za", opts)
  vim.keymap.set("n", "l", "zo", opts)
  vim.keymap.set("n", "h", "zc", opts)
  vim.keymap.set("n", "o", jump_under_cursor, opts)
  vim.keymap.set("n", "R", function()
    require("ktor.index").refresh()
  end, opts)
  vim.keymap.set("n", "q", close, opts)
end

---Open (or focus, if already open) the route tree window.
---@param query string|nil pre-filter to endpoints whose full_path contains this substring
function M.open(query)
  if is_open() then
    state.query = query
    vim.api.nvim_set_current_win(state.winid)
    build_and_render()
    return
  end

  state.query = query
  state.prev_win = vim.api.nvim_get_current_win()
  local bufnr, winid = create_window()
  state.bufnr = bufnr
  state.winid = winid
  set_keymaps(bufnr)

  build_and_render()

  state.unsubscribe = require("ktor.index").on_index_updated(function()
    if is_open() then
      build_and_render()
    end
  end)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if state.unsubscribe then
        state.unsubscribe()
        state.unsubscribe = nil
      end
      state.winid = nil
      state.bufnr = nil
    end,
  })
end

return M
