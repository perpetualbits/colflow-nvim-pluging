-- =============================================================================
-- colflow/windows.lua
-- =============================================================================
-- Creates, configures, and destroys the vertical-split windows that make up a
-- colflow column layout.
--
-- Responsibilities:
--   * Splitting the current window into N vertical panes.
--   * Ensuring every pane shows the same buffer as the anchor.
--   * Setting per-window display options (wrap, fold, number, signcolumn) so
--     that extra columns look like seamless continuation panels, not separate
--     editors.
--   * Equalizing column widths.
--   * Tearing down extra windows on close.
--   * Re-equalizing and re-applying toplines after a terminal resize.
--
-- This module does NOT manage scroll synchronization; that lives in sync.lua.
-- =============================================================================

local M = {}

-- Lazy-load state to avoid a circular dependency at module load time
local state = require("colflow.state")

-- -----------------------------------------------------------------------------
-- Internal helpers
-- -----------------------------------------------------------------------------

-- Configures display options on a single managed window to make it look and
-- behave correctly as a colflow column.
--
-- win_id    : the Neovim window ID to configure
-- is_anchor : true if this is the leftmost (column 0) window
-- col_index : 0-based column index (0 = anchor, N-1 = rightmost)
-- n_columns : total number of columns in the layout
-- cfg       : the merged colflow configuration table
local function configure_single_window(win_id, is_anchor, col_index, n_columns, cfg)
  -- Force wrap off: our topline offset math counts buffer lines, not visual rows.
  -- If wrap were on, a long buffer line would occupy multiple visual rows and
  -- the "topline + i * height" invariant would silently give wrong offsets.
  vim.api.nvim_set_option_value("wrap", false, { win = win_id })

  -- Disable folds: folded sections occupy zero visual rows but multiple buffer
  -- lines, which would break the offset invariant in the same way wrap does.
  -- Documented as a v1 limitation in the README.
  vim.api.nvim_set_option_value("foldenable", false, { win = win_id })

  -- Suppress the winbar (breadcrumb / LSP location line that some plugins add).
  -- A winbar in column 2 would make it look like a separate file rather than
  -- a continuation of the same document.
  vim.api.nvim_set_option_value("winbar", "", { win = win_id })

  -- Columns beyond the anchor get additional decoration hiding so they blend
  -- into a seamless multi-column view.
  if not is_anchor then
    -- Hide the sign column (git status, diagnostic icons) in non-anchor columns.
    -- These decorations still appear in the anchor (column 0) where they are useful.
    if cfg.hide_signcolumn then
      vim.api.nvim_set_option_value("signcolumn", "no", { win = win_id })
    end

    -- Apply the line-number visibility policy from config:
    --   "all"            → hide line numbers in every non-anchor column
    --   "rightmost-only" → hide in all non-anchor columns except the rightmost;
    --                      open() re-enables numbers on the rightmost after the loop
    --   "none"           → leave existing number settings untouched
    local hide_numbers = cfg.hide_numbers
    if hide_numbers == "all" then
      -- Disable both absolute and relative line numbers for a clean look
      vim.api.nvim_set_option_value("number",         false, { win = win_id })
      vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
    elseif hide_numbers == "rightmost-only" then
      -- Hide in all non-anchor, non-rightmost columns here; open() re-enables
      -- numbers on the rightmost column after iterating all windows.
      if col_index < n_columns - 1 then
        -- Not the rightmost column: hide numbers
        vim.api.nvim_set_option_value("number",         false, { win = win_id })
        vim.api.nvim_set_option_value("relativenumber", false, { win = win_id })
      end
      -- col_index == n_columns - 1 (rightmost): leave numbers as inherited
    end
    -- hide_numbers == "none": no changes to number options
  end
end

-- Sets the topline of every window in the list to match the offset invariant,
-- computed from the anchor window's current topline.
--
-- Called once immediately after windows are created to establish the initial
-- split view.  Must be called BEFORE sync.setup_autocmds() to avoid triggering
-- the WinScrolled handler during setup.
--
-- windows_list : ordered list of window IDs (anchor at index 1)
-- bufnr        : buffer number shown in all windows (used for line-count clamping)
local function apply_initial_toplines(windows_list, bufnr)
  -- Use the anchor window's current topline as the starting reference point
  local anchor_topline = vim.fn.line("w0", windows_list[1])

  -- All columns should have equal height after equalization; read from the anchor
  local window_height = vim.api.nvim_win_get_height(windows_list[1])

  -- Total buffer lines, used to clamp toplines to the valid range [1, N]
  local total_lines = vim.api.nvim_buf_line_count(bufnr)

  for list_index, win_id in ipairs(windows_list) do
    -- 0-based column index for the offset formula
    local column_index = list_index - 1

    -- Desired topline: anchor offset by column_index * window_height
    local desired_topline = anchor_topline + column_index * window_height

    -- Clamp to [1, total_lines] so we never request a non-existent line
    local clamped_topline = math.max(1, math.min(desired_topline, total_lines))

    -- Apply topline (and for non-anchor windows, cursor position) via nvim_win_call
    -- so we don't change the globally focused window.
    vim.api.nvim_win_call(win_id, function()
      if column_index == 0 then
        -- Anchor: only set topline; the user's cursor position is already here
        vim.fn.winrestview({ topline = clamped_topline })
      else
        -- Non-anchor: set topline and move cursor to middle of viewport to prevent
        -- Neovim from scrolling away from the topline we just set
        local mid_line = clamped_topline + math.floor(window_height / 2)
        local clamped_mid = math.max(1, math.min(mid_line, total_lines))
        vim.fn.winrestview({ topline = clamped_topline, lnum = clamped_mid })
      end
    end)
  end
end

-- -----------------------------------------------------------------------------
-- Public API
-- -----------------------------------------------------------------------------

-- Creates N vertical-split windows all showing the same buffer as the current
-- window.  Configures each window's display options and applies the initial
-- topline offsets so each column shows the correct segment of the buffer.
--
-- n   : number of columns to create (must be >= 1)
--
-- Returns (windows_list, effective_n) on success, or (nil, error_string) on failure.
-- effective_n may be less than n if the window was too narrow for n columns of
-- min_col_width each.
function M.open(n)
  -- Reject obviously invalid column counts
  if n < 1 then
    return nil, "column count must be at least 1"
  end

  local cfg = state.get_config()

  -- The current window becomes the anchor (column 0)
  local anchor_win_id = vim.api.nvim_get_current_win()
  local anchor_bufnr  = vim.api.nvim_win_get_buf(anchor_win_id)

  -- Enforce the minimum column width: reduce n until each column is at least
  -- min_col_width characters wide, or until only 1 column remains.
  local total_width = vim.api.nvim_win_get_width(anchor_win_id)
  local min_width   = cfg.min_col_width or 40
  local effective_n = n
  while effective_n > 1 and math.floor(total_width / effective_n) < min_width do
    effective_n = effective_n - 1
  end

  -- Start the ordered window list with just the anchor
  local ordered_windows = { anchor_win_id }

  -- Temporarily set splitright = true so new vertical splits always open to the
  -- right of the current window. Restore the user's original setting afterwards.
  local saved_splitright = vim.o.splitright
  vim.o.splitright = true

  -- Create effective_n - 1 additional vertical splits
  for _ = 2, effective_n do
    -- Split from the rightmost existing column so each new window appears further right
    local rightmost_win = ordered_windows[#ordered_windows]

    -- Capture the new window ID INSIDE the nvim_win_call callback.
    -- nvim_win_call restores the focused window after the callback returns, so
    -- calling nvim_get_current_win() OUTSIDE would return the anchor again.
    -- Inside the callback, vsplit has already moved focus to the new window
    -- (because splitright = true), so nvim_get_current_win() returns the new ID.
    local new_win_id
    vim.api.nvim_win_call(rightmost_win, function()
      -- :vsplit opens a new vertical split showing the same buffer; we re-set the
      -- buffer explicitly below for safety in case an autocmd changes it
      vim.cmd("vsplit")
      -- Grab the new window ID now, while focus is still on it inside the callback
      new_win_id = vim.api.nvim_get_current_win()
    end)

    -- Ensure the new window shows the anchor buffer (vsplit inherits it, but an
    -- explicit set protects against BufWinEnter autocmds that might change it)
    vim.api.nvim_win_set_buf(new_win_id, anchor_bufnr)

    table.insert(ordered_windows, new_win_id)
  end

  -- Restore the user's original splitright preference
  vim.o.splitright = saved_splitright

  -- Equalize all column widths so each column occupies the same number of cells.
  -- wincmd = distributes available width evenly across all windows in the tabpage.
  vim.cmd("wincmd =")

  -- Configure display options for each window (wrap, folds, numbers, signcolumn)
  for list_index, win_id in ipairs(ordered_windows) do
    local is_anchor = (list_index == 1)
    local col_index = list_index - 1
    configure_single_window(win_id, is_anchor, col_index, effective_n, cfg)
  end

  -- Apply initial toplines so column i shows the buffer starting at
  -- anchor_topline + i * window_height
  apply_initial_toplines(ordered_windows, anchor_bufnr)

  -- Return the window list and the effective column count (may be < n if
  -- the window was too narrow to fit n full-width columns)
  return ordered_windows, effective_n
end

-- Closes all managed windows except the anchor, restoring the single-window view.
-- Windows that have already been closed by the user (e.g. via :q) are skipped
-- silently — vim.api.nvim_win_is_valid() returns false for closed windows.
--
-- Does NOT delete autocmds or clear state; init.close() is responsible for that.
function M.close_extra_windows()
  local windows = state.get_windows()

  -- Iterate in reverse order (last column first) so the layout collapses from
  -- right to left, avoiding jarring mid-close layout jumps.
  for list_index = #windows, 2, -1 do
    local win_id = windows[list_index]

    -- Only attempt to close the window if it still exists
    if vim.api.nvim_win_is_valid(win_id) then
      -- force = false means an unsaved buffer will block the close and show an
      -- error. The user's data is preserved; they see their original single window.
      vim.api.nvim_win_close(win_id, false)
    end
  end
end

-- Re-equalizes column widths and reapplies topline offsets after a resize event.
-- Called by the VimResized and WinResized autocmd handlers in sync.lua.
--
-- Returns the new window height (pixels may have changed after resize).
function M.on_resize()
  local windows      = state.get_windows()
  local anchor_bufnr = state.get_anchor_bufnr()

  -- Nothing to do if colflow is inactive (belt-and-suspenders guard)
  if #windows == 0 then
    return 0
  end

  -- Re-equalize widths first; the new height we read below will be post-equalization
  vim.cmd("wincmd =")

  -- Read the updated window height from the anchor window
  local new_height = vim.api.nvim_win_get_height(windows[1])

  -- Re-anchor toplines from the current anchor window position
  local anchor_topline = vim.fn.line("w0", windows[1])
  local total_lines    = vim.api.nvim_buf_line_count(anchor_bufnr)

  for list_index, win_id in ipairs(windows) do
    local column_index    = list_index - 1
    local desired_topline = anchor_topline + column_index * new_height
    local clamped_topline = math.max(1, math.min(desired_topline, total_lines))

    vim.api.nvim_win_call(win_id, function()
      if column_index == 0 then
        -- Anchor: only adjust topline
        vim.fn.winrestview({ topline = clamped_topline })
      else
        -- Non-anchor: set topline and re-center cursor to prevent viewport fighting
        local mid_line    = clamped_topline + math.floor(new_height / 2)
        local clamped_mid = math.max(1, math.min(mid_line, total_lines))
        vim.fn.winrestview({ topline = clamped_topline, lnum = clamped_mid })
      end
    end)
  end

  return new_height
end

return M
