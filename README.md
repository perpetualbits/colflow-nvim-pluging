# colflow.nvim

Read and edit a buffer in newspaper-flow columns.

> **Demo:** *[record asciinema of :ColflowOpen 3 on a long file here]*

---

## Motivation

Ultrawide displays, long source files, and log review all share the same
problem: a single editor pane wastes horizontal space while forcing you to
scroll vertically through hundreds of lines.  `colflow.nvim` splits your
current buffer into N side-by-side vertical panes that scroll together as one
continuous document — the same way a newspaper lays out a long article in
columns.

```
  ┌─────────────┬─────────────┬─────────────┐
  │  lines 1–50 │ lines 51–100│lines 101–150│
  │             │             │             │
  │  [cursor]   │             │             │
  └─────────────┴─────────────┴─────────────┘
```

Pressing `j` past the bottom of column 1 reflows all columns:

```
  ┌─────────────┬─────────────┬─────────────┐
  │  lines 2–51 │ lines 52–101│lines 102–151│
  └─────────────┴─────────────┴─────────────┘
```

Every column shows the **same buffer**, so editing in any column is reflected
everywhere instantly.  The plugin only manages viewports, never copies data.

---

## Why not `:set scrollbind`?

Native `scrollbind` locks all windows to the **same** line.  Colflow needs
each window locked to an **offset** from the leftmost window — column 2 always
shows `window_height` lines below column 1, column 3 shows `2 × window_height`
lines below, and so on.  There is no built-in Neovim option for this; the
plugin drives it from autocmds.

---

## Requirements

- Neovim **0.9** or newer

---

## Installation

### lazy.nvim

```lua
{
  "your-github-username/colflow.nvim",
  config = function()
    require("colflow").setup({
      -- see Configuration below
    })
  end,
}
```

### packer.nvim

```lua
use {
  "your-github-username/colflow.nvim",
  config = function()
    require("colflow").setup({})
  end,
}
```

### vim-plug

```vim
Plug 'your-github-username/colflow.nvim'
```

Then in your `init.lua`:

```lua
require("colflow").setup({})
```

---

## Configuration

Call `setup()` in your Neovim config with any options you want to override.
All keys are optional; the defaults are shown below.

```lua
require("colflow").setup({
  -- Default number of columns when :ColflowOpen is called without an argument
  columns = 3,

  -- Minimum column width in characters.  If the current window is too narrow
  -- to fit N columns of this width, the column count is reduced automatically.
  min_col_width = 40,

  -- Keymaps (normal mode, set any to nil to disable)
  keymaps = {
    toggle = "<leader>cf",   -- toggle the column layout on/off
    open   = nil,            -- explicit open keymap (disabled by default)
    close  = nil,            -- explicit close keymap (disabled by default)
    inc    = "<leader>c+",   -- add one column
    dec    = "<leader>c-",   -- remove one column
  },

  -- Hide the sign column (git, diagnostics) in columns 2..N
  hide_signcolumn = true,

  -- Line-number visibility:
  --   "all"            → hide numbers in every column
  --   "rightmost-only" → show numbers only in the rightmost column
  --   "none"           → leave number settings untouched
  hide_numbers = "rightmost-only",
})
```

---

## Commands

| Command | Description |
|---|---|
| `:ColflowOpen [N]` | Open the current buffer in N columns (default from `setup`). |
| `:ColflowClose` | Close all columns, restore the single-window view. |
| `:ColflowToggle [N]` | Open if closed, close if open. |
| `:ColflowInc` | Add one column (up to what the window width allows). |
| `:ColflowDec` | Remove one column (minimum 1; closes the layout at 1 column). |

---

## Keymaps

Default keymaps (set via `setup()`):

| Key | Action |
|---|---|
| `<leader>cf` | Toggle the column layout |
| `<leader>c+` | Add a column |
| `<leader>c-` | Remove a column |

Disable any keymap by passing `nil` for that key in `setup()`.

---

## Health check

Run `:checkhealth colflow` to verify:

- Neovim version compatibility
- Whether `plenary.nvim` is installed (required to run the test suite)
- Current colflow state (active / column count / per-window validity)

---

## Known limitations

- **No `wrap` support.** All managed windows have `wrap` forced off.  The
  topline offset math counts buffer lines; with `wrap` on, a single long line
  would occupy multiple visual rows and the column offsets would be wrong.
  Proper wrap support is planned for a future version.

- **All columns must show the same buffer.**  Opening a different buffer in
  any managed window (`:bnext`, `:edit`, etc.) immediately tears down the
  layout.

- **Folds are disabled** in managed windows (`foldenable=false`).  Folded
  regions occupy zero visual rows but multiple buffer lines, which would break
  the offset invariant.

- **Large files with `relativenumber` may be slow.**  Every reflow sets the
  topline of all managed windows, which forces Neovim to renumber relative line
  numbers.  Disable `relativenumber` in managed columns via `hide_numbers =
  "all"` or `"rightmost-only"` if you notice lag.

---

## Running the tests

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted-style runner.  Install plenary and then:

```bash
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
```

Individual test files:

| File | What it tests |
|---|---|
| `tests/test_state.lua` | `state` module: `column_index_of`, lifecycle, accessors |
| `tests/test_sync.lua` | Topline offset arithmetic (pure Lua, no real windows) |
| `tests/test_windows.lua` | Window creation, option configuration, teardown |
| `tests/test_close.lua` | `close()`, `toggle()`, `inc()`, `dec()` public API |
| `tests/test_integration.lua` | End-to-end: open, scroll, reflow, Ex commands |

---

## How it works (brief)

1. **Opening:** `open(n)` records the current window as the anchor, creates
   `n-1` vertical splits all showing the same buffer, equalizes widths, and
   applies the initial topline offsets.

2. **Synchronization:** An `WinScrolled` / `CursorMoved` autocmd fires on every
   scroll or cursor movement.  The handler reads the topline of the focused
   managed window, derives what the anchor topline must be to satisfy the
   invariant, then writes the correct topline to every other column.  A
   re-entrancy guard (`syncing_in_progress`) prevents the handler from
   triggering itself.

3. **Closing:** `close()` deletes the autocmd group first (so the `WinClosed`
   events fired by closing extra windows don't re-trigger the handler), then
   closes all non-anchor windows, then clears state.
