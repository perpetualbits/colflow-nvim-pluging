-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================================================
-- colflow/state.lua
-- =============================================================================
-- Central state store for colflow.nvim.
--
-- All mutable state lives here: which windows are managed, what buffer they
-- show, whether the plugin is currently active, and the augroup ID that owns
-- our autocmds. Every other module reads and writes state exclusively through
-- the functions exported by this module, which makes it easy to reason about
-- invariants and to reset everything on close().
--
-- No side effects are performed here except in apply_anchor_topline(), which
-- must call vim APIs to actually move the viewports.
-- =============================================================================

local M = {}

-- -----------------------------------------------------------------------------
-- Module-local state variables
-- -----------------------------------------------------------------------------

-- Whether colflow is currently active (open). False on startup and after close().
local active = false

-- Ordered list of managed window IDs (Neovim integers).
-- windows[1] is the anchor window (column 0, leftmost).
-- windows[2] is column 1, windows[3] is column 2, etc.
-- We use 1-based Lua indices; the column index (0-based) is list_index - 1.
local managed_windows = {}

-- The buffer number that every managed window must show.
-- If a window switches away from this buffer, colflow tears itself down.
local anchor_bufnr = nil

-- The nvim augroup ID that owns our WinScrolled / CursorMoved / etc. autocmds.
-- Stored so we can delete the entire group in one call on close().
local augroup_id = nil

-- The merged configuration table built by init.setup(). Kept here so any
-- module can call state.get_config() without importing init (which would be
-- a circular dependency).
local config = {}

-- Option values saved from the anchor window just before colflow modifies
-- them.  Restored on close() so the user's original wrap/fold/winbar settings
-- are not permanently clobbered.
local saved_anchor_options = nil

-- -----------------------------------------------------------------------------
-- State accessors (read-only)
-- -----------------------------------------------------------------------------

-- Returns true if colflow is currently active, false otherwise.
function M.is_active()
  return active
end

-- Returns the ordered list of managed window IDs.
-- The returned table is a direct reference; callers must not modify it.
function M.get_windows()
  return managed_windows
end

-- Returns the number of currently managed windows (equals the column count).
function M.get_column_count()
  return #managed_windows
end

-- Returns the buffer number that all managed windows show.
function M.get_anchor_bufnr()
  return anchor_bufnr
end

-- Returns the augroup ID for our synchronization autocmds.
function M.get_augroup_id()
  return augroup_id
end

-- Returns the current configuration table.
function M.get_config()
  return config
end

-- Returns the 0-based column index of win_id within the managed window list,
-- or nil if win_id is not one of our managed windows.
-- The anchor window (leftmost column) has column index 0.
function M.column_index_of(win_id)
  for list_index, managed_win_id in ipairs(managed_windows) do
    if managed_win_id == win_id then
      -- list indices are 1-based; column indices are 0-based
      return list_index - 1
    end
  end
  -- win_id is not in our managed list
  return nil
end

-- -----------------------------------------------------------------------------
-- State mutators (write)
-- -----------------------------------------------------------------------------

-- Stores the merged user configuration. Called once by init.setup().
-- new_config: the fully-merged config table (defaults + user overrides)
function M.set_config(new_config)
  config = new_config
end

-- Marks colflow as active with the given windows and buffer.
-- windows_list : ordered list of window IDs, anchor first
-- bufnr        : the buffer number all columns show
-- new_augroup  : the augroup ID for our autocmds (may be nil until sync.setup runs)
function M.set_active(windows_list, bufnr, new_augroup)
  managed_windows = windows_list
  anchor_bufnr    = bufnr
  augroup_id      = new_augroup
  active          = true
end

-- Updates the stored augroup ID after sync.setup_autocmds() runs.
-- Separate from set_active so init.lua can call set_active early (to make
-- state readable during autocmd setup) and then attach the augroup ID afterwards.
function M.set_augroup_id(new_augroup_id)
  augroup_id = new_augroup_id
end

-- Stores the option values snapshotted from the anchor window before open()
-- modifies them (wrap, foldenable, winbar).  Called by windows.open().
function M.set_saved_anchor_options(opts)
  saved_anchor_options = opts
end

-- Returns the saved anchor option snapshot, or nil if open() hasn't run yet.
function M.get_saved_anchor_options()
  return saved_anchor_options
end

-- Resets all module state to the initial empty values.
-- Called by close() after all managed windows have been torn down.
-- config is intentionally preserved so setup() does not need to be called again.
function M.clear()
  active                = false
  managed_windows       = {}
  anchor_bufnr          = nil
  augroup_id            = nil
  saved_anchor_options  = nil
end

-- -----------------------------------------------------------------------------
-- Core invariant enforcement
-- -----------------------------------------------------------------------------

-- Applies the anchor topline to every managed window, maintaining:
--
--   topline(window[i]) == anchor_topline + i * window_height   for i in 0..N-1
--
-- anchor_topline : the desired first visible line (1-based) of the anchor window
-- window_height  : the height in buffer lines of each column viewport
--
-- For the focused window the cursor is left untouched (the user is editing there).
-- For every other window the cursor is moved to the middle of the new viewport so
-- that Neovim does not fight our topline setting by scrolling to show the old
-- cursor position (which may now lie outside the new viewport).
--
-- All toplines are clamped to [1, total_buffer_lines] to avoid invalid values.
function M.apply_anchor_topline(anchor_topline, window_height)
  -- Total number of lines in the buffer, used to clamp toplines to valid range
  local total_lines = vim.api.nvim_buf_line_count(anchor_bufnr)

  -- Remember which window the user is focused on so we skip moving its cursor
  local focused_window_id = vim.api.nvim_get_current_win()

  for list_index, win_id in ipairs(managed_windows) do
    -- Convert 1-based list index to 0-based column index for the offset formula
    local column_index = list_index - 1

    -- A managed window may have been closed externally (e.g. :q) between the
    -- WinClosed event and the vim.schedule'd close() that cleans up state.
    -- Skip invalid windows rather than crashing; the scheduled close() will
    -- remove them from state momentarily.
    if not vim.api.nvim_win_is_valid(win_id) then
      return
    end

    -- Desired topline for this column: anchor offset by column_index * height
    local desired_topline = anchor_topline + column_index * window_height

    -- Clamp so we never tell Neovim to show a line that does not exist
    local clamped_topline = math.max(1, math.min(desired_topline, total_lines))

    -- nvim_win_call runs the callback in the context of win_id without changing
    -- the globally focused window. This is essential: we need to call winrestview
    -- for non-focused windows without disrupting the user's focus.
    vim.api.nvim_win_call(win_id, function()
      if win_id == focused_window_id then
        -- For the focused window: only reposition the viewport; leave cursor as-is.
        -- The user is actively editing here; touching the cursor would be disruptive.
        vim.fn.winrestview({ topline = clamped_topline })
      else
        -- For non-focused windows: set topline AND move the cursor inside the
        -- new viewport. If we only set topline and the cursor is outside the new
        -- viewport, Neovim will immediately re-scroll the window to bring the
        -- cursor back into view, undoing our topline change.
        local mid_line_in_viewport = clamped_topline + math.floor(window_height / 2)
        local clamped_mid_line = math.max(1, math.min(mid_line_in_viewport, total_lines))

        -- winrestview sets topline and lnum (cursor line) atomically in one call,
        -- avoiding the race between a separate winrestview + set_cursor sequence.
        vim.fn.winrestview({ topline = clamped_topline, lnum = clamped_mid_line })
      end
    end)
  end
end

return M
