-- =============================================================================
-- colflow/sync.lua
-- =============================================================================
-- Autocmd-driven viewport synchronization for colflow.nvim.
--
-- When the user scrolls or moves their cursor in any managed window, this
-- module recomputes the anchor topline and pushes the correct topline to every
-- managed window, maintaining the invariant:
--
--   topline(window[i]) == topline(window[0]) + i * window_height
--
-- The core hazard this module must neutralize is re-entrancy: setting a topline
-- on a non-focused window fires WinScrolled again, which would trigger another
-- sync, which would fire WinScrolled again — an infinite feedback loop.
-- The syncing_in_progress flag breaks that cycle.
-- =============================================================================

local M = {}

-- Lazy-load state to avoid circular imports at module load time
local state = require("colflow.state")

-- -----------------------------------------------------------------------------
-- Re-entrancy guard
-- -----------------------------------------------------------------------------

-- Set to true while a sync pass is running. Any WinScrolled or CursorMoved
-- event that fires while this flag is true is a side-effect of our own topline
-- writes, not a genuine user action — we skip it immediately.
local syncing_in_progress = false

-- -----------------------------------------------------------------------------
-- Core sync handler
-- -----------------------------------------------------------------------------

-- Synchronizes all managed window toplines based on whichever managed window
-- is currently focused.
--
-- Algorithm:
--   1. Bail out if syncing is already in progress (re-entrancy guard).
--   2. Bail out if colflow is not active.
--   3. Identify which managed window is focused and its 0-based column index.
--   4. Read that window's current topline (first visible buffer line).
--   5. Derive the anchor topline that would place the focused window's topline
--      at exactly column_index * window_height below the anchor.
--   6. Call state.apply_anchor_topline() to push the corrected toplines to all
--      managed windows in one pass.
function M.on_scroll_or_cursor()
  -- Guard: we are already inside a sync triggered by our own topline writes
  if syncing_in_progress then
    return
  end

  -- Guard: colflow has been closed or was never opened
  if not state.is_active() then
    return
  end

  -- Determine which window triggered this event
  local focused_window_id = vim.api.nvim_get_current_win()

  -- Check if the focused window is one of ours; ignore events from unmanaged windows
  -- (e.g. floating windows, quickfix, NvimTree, etc.)
  local column_index_of_focused_window = state.column_index_of(focused_window_id)
  if column_index_of_focused_window == nil then
    return
  end

  -- Raise the re-entrancy guard BEFORE any API calls that could fire autocmds
  syncing_in_progress = true

  -- Wrap in pcall so an unexpected runtime error always clears the guard.
  -- Without pcall, an error would leave syncing_in_progress = true permanently,
  -- silently disabling all future synchronization.
  local ok, err = pcall(function()
    -- Read the first visible buffer line of the focused window.
    -- vim.fn.line("w0", win) returns the topline for the given window ID.
    local focused_topline = vim.fn.line("w0", focused_window_id)

    -- Use the focused window's height as the canonical column height.
    -- All managed windows should have equal heights after equalization.
    local window_height = vim.api.nvim_win_get_height(focused_window_id)

    -- Derive the topline that the anchor window must have so that the focused
    -- window's topline sits at exactly (column_index * window_height) below it:
    --   anchor + column_index * height == focused_topline
    --   anchor = focused_topline - column_index * height
    local desired_anchor_topline =
      focused_topline - column_index_of_focused_window * window_height

    -- Push the computed anchor topline to all managed windows.
    -- state.apply_anchor_topline() handles clamping, non-anchor cursor placement,
    -- and skipping the focused window's cursor.
    state.apply_anchor_topline(desired_anchor_topline, window_height)
  end)

  -- Always lower the guard, regardless of success or failure
  syncing_in_progress = false

  -- Surface errors to the user without crashing; a WARN-level notification
  -- is visible in :messages and most status-line plugins.
  if not ok then
    vim.notify(
      "colflow: sync error — " .. tostring(err),
      vim.log.levels.WARN
    )
  end
end

-- -----------------------------------------------------------------------------
-- Autocmd registration
-- -----------------------------------------------------------------------------

-- Registers all autocmds needed to drive scroll synchronization and handle
-- edge cases (window closed manually, buffer changed, terminal resize).
--
-- Creates (or re-creates) the augroup "ColflowSync" — clearing it first removes
-- any stale handlers if open() is called more than once without an intervening
-- close().
--
-- Must be called AFTER state.set_active() so that the handlers can query state.
--
-- Returns the augroup ID (an integer) for storage in state.
function M.setup_autocmds()
  -- nvim_create_augroup with clear=true removes all autocmds in the group first,
  -- ensuring a clean slate whether this is the first open or a subsequent one.
  local augroup_id = vim.api.nvim_create_augroup("ColflowSync", { clear = true })

  -- ---------------------------------------------------------------------------
  -- WinScrolled: fires whenever any window's viewport scrolls.
  -- This covers j/k cursor movement that scrolls the viewport, Ctrl-E/Y, mouse
  -- wheel, and any other scroll-inducing action.
  -- Neovim 0.9+ fires this for each affected window, but we re-derive the
  -- focused window inside the handler rather than trusting vim.v.event for
  -- broader compatibility.
  -- ---------------------------------------------------------------------------
  vim.api.nvim_create_autocmd("WinScrolled", {
    group    = augroup_id,
    callback = M.on_scroll_or_cursor,
    desc     = "colflow: synchronize column toplines when any window scrolls",
  })

  -- ---------------------------------------------------------------------------
  -- CursorMoved: fires after every cursor movement in normal mode.
  -- Needed in addition to WinScrolled for movements that don't scroll the
  -- viewport (e.g. the cursor is still visible but moved to a different column's
  -- logical position).
  -- ---------------------------------------------------------------------------
  vim.api.nvim_create_autocmd("CursorMoved", {
    group    = augroup_id,
    callback = M.on_scroll_or_cursor,
    desc     = "colflow: synchronize toplines on cursor movement (normal mode)",
  })

  -- CursorMovedI: same trigger as CursorMoved but fires while in insert mode,
  -- so that typing and moving around while inserting stays in sync.
  vim.api.nvim_create_autocmd("CursorMovedI", {
    group    = augroup_id,
    callback = M.on_scroll_or_cursor,
    desc     = "colflow: synchronize toplines on cursor movement (insert mode)",
  })

  -- ---------------------------------------------------------------------------
  -- WinClosed: fires AFTER a window has been closed.
  -- event.match contains the closed window's ID as a string.
  -- If the user closes one of our managed windows (e.g. :q or ZZ), we tear
  -- down the entire layout cleanly rather than leaving half-open columns.
  -- ---------------------------------------------------------------------------
  vim.api.nvim_create_autocmd("WinClosed", {
    group    = augroup_id,
    callback = function(event)
      -- Convert the string window ID from event.match to an integer
      local closed_win_id = tonumber(event.match)

      -- Check if the closed window was one of ours
      if state.column_index_of(closed_win_id) ~= nil then
        -- Defer the close() so it runs after the current autocmd chain completes.
        -- Calling close() synchronously inside WinClosed can confuse Neovim's
        -- window management and produce errors or partial cleanup.
        vim.schedule(function()
          -- Re-check activity in case close() was already called by another handler
          if state.is_active() then
            require("colflow").close()
          end
        end)
      end
    end,
    desc = "colflow: tear down layout cleanly when a managed window is closed",
  })

  -- ---------------------------------------------------------------------------
  -- BufWinEnter: fires after a buffer has been loaded into a window.
  -- If the user opens a different buffer in one of our managed windows (e.g.
  -- via :bnext, :edit foo.txt, or a plugin that hijacks the window), we close
  -- the colflow layout. The plugin assumes all columns always show the same buffer.
  -- ---------------------------------------------------------------------------
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group    = augroup_id,
    callback = function()
      local current_win_id = vim.api.nvim_get_current_win()

      -- Ignore events from windows outside our layout
      if state.column_index_of(current_win_id) == nil then
        return
      end

      -- Check whether the buffer now in this window is still the anchor buffer
      local current_bufnr = vim.api.nvim_win_get_buf(current_win_id)
      if current_bufnr ~= state.get_anchor_bufnr() then
        -- A different buffer entered a managed window; tear down
        vim.schedule(function()
          if state.is_active() then
            require("colflow").close()
          end
        end)
      end
    end,
    desc = "colflow: tear down layout when a managed window switches to a different buffer",
  })

  -- ---------------------------------------------------------------------------
  -- VimResized: fires when the outer terminal (or GUI) is resized.
  -- We re-equalize column widths and reapply topline offsets so the view
  -- remains correct at the new dimensions.
  -- ---------------------------------------------------------------------------
  vim.api.nvim_create_autocmd("VimResized", {
    group    = augroup_id,
    callback = function()
      if state.is_active() then
        require("colflow.windows").on_resize()
      end
    end,
    desc = "colflow: reflow columns after the terminal is resized",
  })

  -- WinResized: fires when individual split windows are resized (e.g. the user
  -- drags a separator or uses Ctrl-W + / Ctrl-W -).
  vim.api.nvim_create_autocmd("WinResized", {
    group    = augroup_id,
    callback = function()
      if state.is_active() then
        require("colflow.windows").on_resize()
      end
    end,
    desc = "colflow: reflow columns after a split is manually resized",
  })

  -- Return the augroup ID so init.lua can store it in state
  return augroup_id
end

-- Deletes the ColflowSync augroup and all autocmds it contains.
-- Called at the start of close() so that the WinClosed events fired by
-- closing extra windows do not recursively call close() again.
function M.teardown()
  -- pcall because the augroup may not exist if teardown() is called before
  -- setup_autocmds(), e.g. if the user calls close() before ever calling open()
  pcall(vim.api.nvim_del_augroup_by_name, "ColflowSync")
end

return M
