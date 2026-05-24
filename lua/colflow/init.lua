-- =============================================================================
-- colflow/init.lua
-- =============================================================================
-- Public API module for colflow.nvim.
--
-- Users call require("colflow").setup(opts) in their Neovim configuration to
-- configure the plugin and register optional keymaps.  The functions open(),
-- close(), toggle(), inc(), and dec() implement the plugin's core behaviour
-- and are also the targets of the Ex commands registered in commands.lua.
--
-- Architecture:
--   init.lua    — orchestrates state, windows, and sync sub-modules
--   state.lua   — holds all mutable state; single source of truth
--   windows.lua — creates / destroys / configures vsplit windows
--   sync.lua    — registers autocmds; contains the scroll sync handler
--   commands.lua— registers :ColflowOpen / Close / Toggle / Inc / Dec
--   health.lua  — implements :checkhealth colflow
-- =============================================================================

local M = {}

-- Default configuration. These values are merged with user-supplied options in
-- setup() and stored in state so every sub-module can access them without
-- importing init (which would create a circular dependency).
local default_config = {
  -- Default number of columns when :ColflowOpen is called without an argument
  columns = 3,

  -- Minimum column width in characters.  If the current window is too narrow
  -- to fit N columns of this width, the column count is silently reduced.
  min_col_width = 40,

  -- Keymaps to register in normal mode.  Set any entry to nil or false to
  -- disable that particular binding.
  keymaps = {
    toggle = "<leader>cf",   -- toggle the full column layout on/off
    open   = nil,            -- no default keymap for explicit open
    close  = nil,            -- no default keymap for explicit close
    inc    = "<leader>c+",   -- add one column
    dec    = "<leader>c-",   -- remove one column
  },

  -- Whether to suppress the sign column in columns 2..N.
  -- Signs (git, diagnostics) still appear in column 1 (the anchor).
  hide_signcolumn = true,

  -- Line-number visibility policy for managed columns:
  --   "all"            → hide numbers in every managed column
  --   "rightmost-only" → show numbers only in the rightmost column
  --   "none"           → leave all number settings untouched
  hide_numbers = "rightmost-only",
}

-- =============================================================================
-- setup()
-- =============================================================================

-- Configures colflow.nvim with user preferences.  Call this once in your
-- Neovim configuration (init.lua / init.vim) before using any commands.
-- Calling setup() more than once is safe; each call replaces the previous config.
--
-- opts: table of overrides for default_config; may be nil or empty ({})
function M.setup(opts)
  opts = opts or {}

  -- vim.tbl_deep_extend merges nested tables; "force" means opts wins on conflict
  local cfg = vim.tbl_deep_extend("force", default_config, opts)

  -- Persist the merged config in state so sub-modules can read it
  local state = require("colflow.state")
  state.set_config(cfg)

  -- Register keymaps if any are configured
  M._setup_keymaps(cfg)
end

-- Registers normal-mode keymaps from the given config table.
-- Exported so tests can exercise keymap registration in isolation.
-- cfg: the merged configuration table
function M._setup_keymaps(cfg)
  local keymaps = cfg.keymaps or {}

  -- Helper: register one normal-mode mapping if a key was provided
  local function map_action(key, action_fn, description)
    if key then
      -- "n" = normal mode, silent = suppress the key echo in the command line
      vim.keymap.set("n", key, action_fn, { silent = true, desc = description })
    end
  end

  map_action(keymaps.toggle, M.toggle, "colflow: toggle column layout on/off")
  map_action(keymaps.open,   M.open,   "colflow: open column layout")
  map_action(keymaps.close,  M.close,  "colflow: close column layout")
  map_action(keymaps.inc,    M.inc,    "colflow: add one column")
  map_action(keymaps.dec,    M.dec,    "colflow: remove one column")
end

-- =============================================================================
-- open()
-- =============================================================================

-- Opens the current buffer in N newspaper-flow column windows.
-- If colflow is already active with a different column count, the existing
-- layout is closed and re-opened with the new count.
--
-- n: number of columns (integer >= 1). nil → use the value from setup().
function M.open(n)
  local state   = require("colflow.state")
  local windows = require("colflow.windows")
  local sync    = require("colflow.sync")

  local cfg = state.get_config()

  -- Resolve column count: argument → config → built-in default
  local column_count = n or cfg.columns or default_config.columns

  -- Ensure we have at least one column
  column_count = math.max(1, column_count)

  -- If a layout is already open, tear it down before building the new one.
  -- This handles `:ColflowOpen 4` when a 3-column layout is already running.
  if state.is_active() then
    M.close()
  end

  -- Create the vertical splits and configure their display options.
  -- windows.open() returns the ordered window list and the effective column count
  -- (which may be < column_count if the window is too narrow).
  local ordered_windows, effective_n = windows.open(column_count)
  if not ordered_windows then
    -- windows.open() returns (nil, error_message) on failure
    vim.notify("colflow: " .. tostring(effective_n), vim.log.levels.ERROR)
    return
  end

  -- Read the anchor buffer number from the first (anchor) window
  local anchor_bufnr = vim.api.nvim_win_get_buf(ordered_windows[1])

  -- Mark colflow as active so that the autocmd handlers set up below can
  -- query state.is_active() and state.column_index_of() correctly.
  -- We pass nil for augroup_id here and update it after setup_autocmds().
  state.set_active(ordered_windows, anchor_bufnr, nil)

  -- Register WinScrolled, CursorMoved, WinClosed, BufWinEnter, and resize
  -- autocmds.  Must run AFTER set_active() so the handlers see valid state.
  local augroup_id = sync.setup_autocmds()

  -- Attach the augroup ID now that we have it
  state.set_augroup_id(augroup_id)

  -- Notify the user when more than one column was actually created.
  -- Suppress the message for single-column "open" (unusual but valid).
  if effective_n > 1 then
    vim.notify(
      string.format("colflow: %d columns", effective_n),
      vim.log.levels.INFO
    )
  end
end

-- =============================================================================
-- close()
-- =============================================================================

-- Closes all extra column windows and restores the single-window view.
-- Deletes the autocmd group first so that the WinClosed events generated by
-- closing the extra windows do not recursively trigger another close().
-- Safe to call when colflow is not active (no-op).
function M.close()
  local state   = require("colflow.state")
  local windows = require("colflow.windows")
  local sync    = require("colflow.sync")

  -- No-op guard: close() may be called from WinClosed while already closing
  if not state.is_active() then
    return
  end

  -- Delete the autocmd group FIRST so that WinClosed events fired by
  -- nvim_win_close() below do not call close() again (re-entrancy)
  sync.teardown()

  -- Close all extra windows; the anchor window (column 0) is left open.
  -- Windows already closed by the user are skipped silently.
  windows.close_extra_windows()

  -- Restore wrap, foldenable, and winbar on the anchor window to the values
  -- they had before open() modified them. Must run before state.clear() wipes
  -- the saved snapshot and the managed_windows list.
  windows.restore_anchor_options()

  -- Reset all module state; config is preserved for the next open() call
  state.clear()
end

-- =============================================================================
-- toggle()
-- =============================================================================

-- Opens N columns if colflow is currently closed; closes the layout if open.
-- n: column count for the open case; nil uses the config default.
function M.toggle(n)
  local state = require("colflow.state")

  if state.is_active() then
    M.close()
  else
    M.open(n)
  end
end

-- =============================================================================
-- inc() / dec()
-- =============================================================================

-- Adds one column to the current layout.
-- If colflow is not active, opens with (config.columns + 1) columns.
-- Has no visible effect if the window is too narrow for another column of
-- min_col_width characters.
function M.inc()
  local state = require("colflow.state")
  local cfg   = state.get_config()

  -- Base column count: current layout count if active, else the config default
  local current_count = state.is_active()
    and state.get_column_count()
    or  (cfg.columns or default_config.columns)

  -- open() handles width-based clamping internally
  M.open(current_count + 1)
end

-- Removes one column from the current layout, with a minimum of 1.
-- If the count would drop to 1, calls close() for a cleaner teardown.
function M.dec()
  local state = require("colflow.state")
  local cfg   = state.get_config()

  -- Base column count: current layout count if active, else the config default
  local current_count = state.is_active()
    and state.get_column_count()
    or  (cfg.columns or default_config.columns)

  -- Enforce the minimum: 1 column means "just the anchor" which equals closed
  local new_count = math.max(1, current_count - 1)

  if new_count == 1 then
    -- A 1-column "layout" is indistinguishable from normal editing; just close
    M.close()
  else
    -- Re-open with one fewer column
    M.open(new_count)
  end
end

-- =============================================================================
-- statusline()
-- =============================================================================

-- Returns a short statusline string for use in lualine, heirline, or a plain
-- statusline expression.  Returns "[col:N]" when N columns are active, or ""
-- when colflow is inactive (so the component vanishes when not in use).
--
-- Lualine example:
--   require("lualine").setup({
--     sections = { lualine_x = { require("colflow").statusline } },
--   })
--
-- Plain statusline example:
--   vim.o.statusline = "%{%v:lua.require('colflow').statusline()%} ..."
function M.statusline()
  local state = require("colflow.state")
  if not state.is_active() then return "" end
  return string.format("[col:%d]", state.get_column_count())
end

return M
