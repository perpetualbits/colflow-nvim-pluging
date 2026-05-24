-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================================================
-- colflow/commands.lua
-- =============================================================================
-- Registers the user-facing Ex commands for colflow.nvim.
--
-- Commands registered here:
--   :ColflowOpen [N]   — open the current buffer in N newspaper-flow columns
--   :ColflowClose      — close columns, restore single-window view
--   :ColflowToggle [N] — open if closed, close if open
--   :ColflowInc        — add one column (up to the window-width limit)
--   :ColflowDec        — remove one column (minimum 1)
--
-- Each command delegates to the public API in init.lua. This module is kept
-- separate so plugin/colflow.lua can require() it before the user ever calls
-- setup(), and the commands work immediately after installation.
-- =============================================================================

local M = {}

-- Creates all colflow user commands. Called once from plugin/colflow.lua at
-- Neovim startup, before the user's config runs.
function M.register()

  -- :ColflowOpen [N]
  -- Opens the current buffer in N newspaper-flow columns.
  -- If N is omitted, the column count from setup() (default 3) is used.
  vim.api.nvim_create_user_command(
    "ColflowOpen",
    function(opts)
      -- opts.args is the raw argument string; tonumber returns nil for empty string
      local n = tonumber(opts.args) or nil
      require("colflow").open(n)
    end,
    {
      nargs = "?",    -- accept zero or one argument
      desc  = "Open the current buffer in N newspaper-flow columns (default from setup)",
    }
  )

  -- :ColflowClose
  -- Closes all extra column windows and returns to a single-window view.
  -- Safe to call even when colflow is not active.
  vim.api.nvim_create_user_command(
    "ColflowClose",
    function()
      require("colflow").close()
    end,
    {
      nargs = 0,
      desc  = "Close colflow columns and restore the single-window view",
    }
  )

  -- :ColflowToggle [N]
  -- Opens N columns if the layout is closed; closes it if already open.
  -- The N argument is only used when opening.
  vim.api.nvim_create_user_command(
    "ColflowToggle",
    function(opts)
      local n = tonumber(opts.args) or nil
      require("colflow").toggle(n)
    end,
    {
      nargs = "?",
      desc  = "Toggle colflow: open N columns if closed, close if already open",
    }
  )

  -- :ColflowInc
  -- Adds one column to the current layout.
  -- Has no visible effect if the window is already too narrow for another column.
  vim.api.nvim_create_user_command(
    "ColflowInc",
    function()
      require("colflow").inc()
    end,
    {
      nargs = 0,
      desc  = "Add one colflow column (up to window-width limit)",
    }
  )

  -- :ColflowDec
  -- Removes one column from the current layout (minimum 1 column).
  -- When the column count would drop below 2, close() is called instead.
  vim.api.nvim_create_user_command(
    "ColflowDec",
    function()
      require("colflow").dec()
    end,
    {
      nargs = 0,
      desc  = "Remove one colflow column (minimum 1; closes the layout at 1 column)",
    }
  )

end

return M
