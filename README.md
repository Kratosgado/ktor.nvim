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
})
```

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

### Commands

| Command                 | Effect                          |
| ------------------------ | -------------------------------- |
| `:KtorCodeLensToggle`    | Toggle code lens on/off          |
| `:KtorCodeLensEnable`    | Turn code lens on                |
| `:KtorCodeLensDisable`   | Turn code lens off               |

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
  `KtorEndpoint[]`; the source of truth both features read from.
- `lua/ktor/highlights.lua` — shared `KtorMethod*`/`KtorAuthScheme` groups.
- `lua/ktor/jump.lua` — shared `jump_to_range(bufnr, range)`, used by both
  the route tree and (in the future) an endpoints picker.
- `lua/ktor/codelens.lua` — code lens rendering + toggle state.
- `lua/ktor/route_tree.lua` — pure tree construction/rendering logic from a
  flat endpoint list, independently testable from the UI.
- `lua/ktor/ui/tree_window.lua` — floating/split window, buffer, keymaps,
  and folding for the route tree.
