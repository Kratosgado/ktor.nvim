# ktor.nvim

Neovim tooling for Kotlin/Ktor backend projects: inline route info at the
cursor, and a full route-tree visualizer for the project.

## Setup

```lua
{
  "kratosgado/ktor.nvim",
  ft = "kotlin",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  opts = {},
  config = function(_, opts)
    require("ktor").setup(opts)
    require("ktor.index").refresh()
  end,
},
```

Requires the `kotlin` parser for `nvim-treesitter` (`:TSInstall kotlin`).

### Configuration

```lua
require("ktor").setup({
  code_lens = {
    enabled = true,       -- draw code lens on load
    style = "virt_lines",  -- "virt_lines" | "eol"
  },
  route_tree = {
    display = "float",    -- "float" | "split"
    width = 60,
    split_side = "left",  -- "left" | "right" (only applies when display = "split")
  },
  picker = {
    backend = "auto",     -- "auto" | "fzf" | "telescope" ("auto" prefers fzf-lua, falls back to telescope)
  },
  diagnostics = {
    enabled = true,       -- duplicate/ambiguous routes + unresolved route calls, via vim.diagnostic
  },
})
```

### Keeping the index fresh

Editing any `.kt` file reactively rescans just that file (and, if it's an
extension function referenced from elsewhere via `route_functions`, whatever
other files reference it) - never the whole project. Run `:KtorRefresh` (or
`R` in the route tree window) after things like a branch switch, `git pull`,
or moving routes into a brand-new file the plugin hasn't seen yet in this
session - those cases aren't picked up by the reactive per-edit path.

`fun Route.*` extension functions are resolved by NAME only, project-wide -
there's no real Kotlin import/package resolution behind it. Two unrelated
files defining `fun Route.healthRoutes()` (say) would collide, and whichever
was scanned last wins. Rare in practice, but worth knowing if a route
resolves to a path that looks wrong.

## Endpoint Code Lens

Shows the fully-resolved path and HTTP method above (or after) each route
handler, reactively updated as you edit.

```kotlin
route("/api/v1") {
    route("/schools/{schoolId}") {
        authenticate("admin-jwt") {
            get("/students/{id}") {
            -- ● GET /api/v1/schools/{schoolId}/students/{id}  [admin-jwt]
                call.respond(...)
            }
        }
    }
}
```

The method is colored per verb via highlight groups (override any of these
with `vim.api.nvim_set_hl`):

| Group              | Default link       |
| ------------------ | ------------------ |
| `KtorMethodGet`    | `DiagnosticOk`     |
| `KtorMethodPost`   | `DiagnosticInfo`   |
| `KtorMethodPut`    | `DiagnosticWarn`   |
| `KtorMethodPatch`  | `DiagnosticWarn`   |
| `KtorMethodDelete` | `DiagnosticError`  |
| `KtorAuthScheme`   | `Comment` (italic) |

## Route Tree Visualizer

`:KtorRouteTree [query]` opens a collapsible tree of the project's route
nesting (not just a flat endpoint list), reconstructed from the index.

```
▾ /api/v1
  ▾ /schools/{schoolId}
    🔒 admin-jwt
    ● GET    /api/v1/schools/{schoolId}/students/{id}
    ● PUT    /api/v1/schools/{schoolId}/students/{id}
    ● DELETE /api/v1/schools/{schoolId}/students/{id}
    ● GET    /api/v1/schools/{schoolId}/students
    ● POST   /api/v1/schools/{schoolId}/students
  ▾ /auth
    ● POST   /api/v1/auth/login
▾ /health
  ● GET    /health
```

An optional query pre-filters to endpoints whose full path contains that
substring (plain text, not fuzzy): `:KtorRouteTree students`.

## Endpoints Picker

`:KtorEndpoints` opens a fuzzy picker over every indexed endpoint - method,
full path, auth scheme, and source location - method-colored the same way as
the code lens and route tree. Prefers `fzf-lua` if installed, falls back to
`telescope.nvim`; set `picker.backend` to force one. Selecting an entry
(`<CR>`/`enter`) jumps to its definition; `<C-y>`/`ctrl-y` generates a request
for it instead (see below) without closing the picker.

## Route Diagnostics

Reported via `vim.diagnostic`, so they show up wherever you already surface
diagnostics (signs, virtual text, `:Trouble`, etc.):

- **Duplicate route** (warning) - the same method + exact path defined more
  than once.
- **Ambiguous route** (warning) - same method and path *shape* but different
  param names (`/students/{id}` vs `/students/{studentId}`), which Ktor's
  router would treat as conflicting.
- **Unresolved route call** (hint) - a bare call sitting exactly where a
  route delegation would (no trailing lambda, directly inside a
  `routing{}`/`route(){}`/`authenticate(){}` body) that doesn't match any
  known verb, `route()`, or `fun Route.*` - possibly a real gap in the index,
  possibly a legitimate call the heuristic doesn't recognize.

Disable with `diagnostics = { enabled = false }`.

## Generate Request

Turns an endpoint into a ready-to-run [kulala.nvim](https://github.com/mistweaverco/kulala.nvim)
`.http` request - a `@base_url` default so it runs with zero setup, method,
URL (path params become `{{param}}` placeholders), an
`Authorization: Bearer {{token}}` stub if it's auth-protected, and a JSON
body stub for POST/PUT/PATCH. Triggered with `y` in the route tree,
`<C-y>`/`ctrl-y` in the endpoints picker, or `:KtorGenerateRequest`
(suggested as `<leader>kg`) for whatever endpoint contains the cursor
directly in Kotlin source.

```http
@base_url = http://localhost:8080

### GET /api/v1/schools/{schoolId}/students/{id}  [admin-jwt]
GET {{base_url}}/api/v1/schools/{{schoolId}}/students/{{id}}
Authorization: Bearer {{token}}
```

Appended as a new `###`-delimited block to a shared scratch file at
`<project root>/.ktor-nvim/request.http` (root = `getcwd()`, same as the
rest of the index) - kulala's `.http` format is built to hold multiple
requests in one document, so generating another endpoint doesn't clobber
ones you already generated. Opened directly in the current window (not a
float - kulala's response UI needs to `:split`, which floating windows
can't do) with the cursor on the new block's method/URL line, and that
block's text copied to the unnamed/system registers. Run it with whatever your own
kulala keymap is (kulala doesn't ship one by default; see kulala.nvim's own
README for `require("kulala").run()`). If you already have a real kulala env
(`.env`, `http-client.env.json`) with its own `base_url`, delete the
generated `@base_url` line so there's no ambiguity about which one wins -
the file lives inside the project specifically so kulala's parent-directory
env-file discovery can find yours either way. Add `.ktor-nvim/` to that
project's own `.gitignore`.

## Commands

| Command                  | Effect                                       |
| ------------------------ | -------------------------------------------- |
| `:KtorCodeLensToggle`    | Toggle code lens on/off                      |
| `:KtorRouteTree [query]` | Open the route tree, optionally pre-filtered |
| `:KtorEndpoints`         | Fuzzy-find endpoints (fzf-lua or telescope)  |
| `:KtorGenerateRequest`   | Generate a request for the endpoint under cursor in Kotlin source |
| `:KtorRefresh`           | Full project-wide rescan (manual only)       |

### Keymaps

ktor.nvim doesn't bind any global keymaps itself - none of these commands are
mapped by default, so add whatever you want in your own config. With
lazy.nvim, the `keys` field on the plugin spec is the natural place, since it
also lazy-loads on first press:

```lua
keys = {
  { "<leader>kt", "<cmd>KtorRouteTree<cr>", ft = "kotlin", desc = "Ktor: Route Tree" },
  { "<leader>kl", "<cmd>KtorCodeLensToggle<cr>", ft = "kotlin", desc = "Ktor: Toggle Code Lens" },
  { "<leader>ke", "<cmd>KtorEndpoints<cr>", ft = "kotlin", desc = "Ktor: Endpoints" },
  { "<leader>kg", "<cmd>KtorGenerateRequest<cr>", ft = "kotlin", desc = "Ktor: Generate Request" },
  { "<leader>kr", "<cmd>KtorRefresh<cr>", ft = "kotlin", desc = "Ktor: Refresh Index" },
},
```

Without lazy.nvim (or to scope it more precisely), map the commands directly
in an `ftplugin/kotlin.lua` or a `FileType kotlin` autocmd instead:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "kotlin",
  callback = function(args)
    local opts = { buffer = args.buf, silent = true }
    vim.keymap.set("n", "<leader>kt", "<cmd>KtorRouteTree<cr>", opts)
    vim.keymap.set("n", "<leader>kl", "<cmd>KtorCodeLensToggle<cr>", opts)
    vim.keymap.set("n", "<leader>ke", "<cmd>KtorEndpoints<cr>", opts)
    vim.keymap.set("n", "<leader>kg", "<cmd>KtorGenerateRequest<cr>", opts)
    vim.keymap.set("n", "<leader>kr", "<cmd>KtorRefresh<cr>", opts)
  end,
})
```

The tree window's own keymaps (fold/jump/filter/refresh/close) are separate
from these - they're buffer-local to the tree and always active, see below.

### Keymaps (in the tree window)

| Key                     | Effect                                                                                                    |
| ----------------------- | --------------------------------------------------------------------------------------------------------- |
| `<Tab>` / `<CR>` / `za` | Toggle fold under cursor                                                                                  |
| `l`                     | Open (expand) fold under cursor                                                                           |
| `h`                     | Close (collapse) fold under cursor                                                                        |
| `o`                     | Jump to the route/`authenticate` block under cursor (closes the tree if it's a float; a split stays open) |
| `y`                     | Generate a kulala `.http` request for the endpoint under cursor                                           |
| `/`                     | Prompt for a filter query, hiding non-matching endpoints (same as `:KtorRouteTree <query>`)               |
| `R`                     | Re-run `ktor.index.refresh()` and redraw                                                                  |
| `q`                     | Close the window                                                                                          |

## Architecture

- `lua/ktor/index.lua` — treesitter-based project scanner producing a flat
  `KtorEndpoint[]` (plus `KtorUnresolvedCall[]`); the source of truth every
  feature reads from. Resolves routes split across files via `fun Route.*`
  extension functions, and tracks a reverse dependency graph so a per-file
  edit only rescans the files it can actually affect - a full project-wide
  walk only happens via `M.refresh()`.
- `lua/ktor/highlights.lua` — shared `KtorMethod*`/`KtorAuthScheme` groups.
- `lua/ktor/jump.lua` — shared `jump_to_range(bufnr, range)`, used by the
  route tree and the endpoints picker.
- `lua/ktor/codelens.lua` — code lens rendering + toggle state.
- `lua/ktor/route_tree.lua` — pure tree construction/rendering logic from a
  flat endpoint list, independently testable from the UI.
- `lua/ktor/ui/tree_window.lua` — floating/split window, buffer, keymaps,
  and folding for the route tree.
- `lua/ktor/picker.lua` — fzf-lua/telescope adapters over the same endpoint
  list.
- `lua/ktor/diagnostics.lua` — duplicate/ambiguous route and unresolved-call
  detection, applied via `vim.diagnostic`.
- `lua/ktor/request.lua` — pure `generate(ep)` (kulala-ready `.http` text)
  plus `open(ep)`, which writes it to a scratch file and opens it in the
  current (non-floating) window; `open_at_cursor()` resolves `ep` from the
  cursor position in Kotlin source. Shared by the route tree's `y`, the
  picker's `<C-y>`, and `:KtorGenerateRequest`.
