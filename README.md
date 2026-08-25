# ktor.nvim

Neovim tooling for Kotlin/Ktor backend projects: inline route info at the
cursor, and a full route-tree visualizer for the project.

## Setup

```lua
{
  dir = "~/projects/configs/ktor.nvim",
  name = "ktor.nvim",
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
})
```

### Keeping the index fresh

Editing any `.kt` file reactively rescans just that file (and, if it's an
extension function referenced from elsewhere via `route_functions`, whatever
other files reference it) - never the whole project. Run `:KtorRefresh` (or
`R` in the route tree window) after things like a branch switch, `git pull`,
or moving routes into a brand-new file the plugin hasn't seen yet in this
session - those cases aren't picked up by the reactive per-edit path.

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

| Group               | Default link      |
| -------------------- | ------------------ |
| `KtorMethodGet`      | `DiagnosticOk`     |
| `KtorMethodPost`     | `DiagnosticInfo`   |
| `KtorMethodPut`      | `DiagnosticWarn`   |
| `KtorMethodPatch`    | `DiagnosticWarn`   |
| `KtorMethodDelete`   | `DiagnosticError`  |
| `KtorAuthScheme`     | `Comment` (italic) |

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
`telescope.nvim`; set `picker.backend` to force one. Selecting an entry jumps
straight to its definition via the same `jump_to_range` the route tree uses.

## Commands

| Command                 | Effect                                       |
| ------------------------ | --------------------------------------------- |
| `:KtorCodeLensToggle`    | Toggle code lens on/off                       |
| `:KtorRouteTree [query]` | Open the route tree, optionally pre-filtered  |
| `:KtorEndpoints`         | Fuzzy-find endpoints (fzf-lua or telescope)   |
| `:KtorRefresh`           | Full project-wide rescan (manual only)        |

ktor.nvim doesn't bind any global keymaps itself - wire up whatever you want
in your own config, e.g. via lazy.nvim's `keys`:

```lua
keys = {
  { "<leader>kt", "<cmd>KtorRouteTree<cr>", ft = "kotlin", desc = "Ktor: Route Tree" },
  { "<leader>kl", "<cmd>KtorCodeLensToggle<cr>", ft = "kotlin", desc = "Ktor: Toggle Code Lens" },
  { "<leader>ke", "<cmd>KtorEndpoints<cr>", ft = "kotlin", desc = "Ktor: Endpoints" },
  { "<leader>kr", "<cmd>KtorRefresh<cr>", ft = "kotlin", desc = "Ktor: Refresh Index" },
},
```

### Keymaps (in the tree window)

| Key                  | Effect                                              |
| --------------------- | ---------------------------------------------------- |
| `<Tab>` / `<CR>` / `za` | Toggle fold under cursor                          |
| `l`                    | Open (expand) fold under cursor                    |
| `h`                    | Close (collapse) fold under cursor                 |
| `o`                    | Jump to the route/`authenticate` block under cursor (closes the tree if it's a float; a split stays open) |
| `/`                    | Native Neovim search within the tree                |
| `R`                    | Re-run `ktor.index.refresh()` and redraw            |
| `q`                    | Close the window                                    |

## Architecture

- `lua/ktor/index.lua` — treesitter-based project scanner producing a flat
  `KtorEndpoint[]`; the source of truth every feature reads from. Resolves
  routes split across files via `fun Route.*` extension functions, and tracks
  a reverse dependency graph so a per-file edit only rescans the files it can
  actually affect - a full project-wide walk only happens via `M.refresh()`.
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
