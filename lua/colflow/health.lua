-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================================================
-- colflow/health.lua
-- =============================================================================
-- Health check for colflow.nvim.  Run with :checkhealth colflow
--
-- Reports:
--   * Neovim version compatibility (requires 0.9+)
--   * Whether plenary.nvim is available (needed only for running the test suite)
--   * Current colflow state: active / column count / per-window validity
-- =============================================================================

local M = {}

-- Performs all colflow health checks.  Called automatically by :checkhealth colflow.
-- No parameters; no return value.  All output goes through vim.health.ok/warn/error.
function M.check()
  -- Start a named health check section visible in the :checkhealth output
  vim.health.start("colflow.nvim")

  -- ---------------------------------------------------------------------------
  -- 1. Neovim version
  -- colflow requires 0.9+ for:
  --   * WinScrolled events with per-window data
  --   * vim.api.nvim_set_option_value()  (preferred over the deprecated win_set_option)
  --   * vim.health module (this file)
  --   * nvim_win_call() reliable behaviour
  -- ---------------------------------------------------------------------------
  local ver = vim.version()
  local ver_str = string.format("%d.%d.%d", ver.major, ver.minor, ver.patch)

  if ver.major > 0 or ver.minor >= 9 then
    -- Version is acceptable
    vim.health.ok("Neovim " .. ver_str .. " (0.9+ required — ok)")
  else
    -- Version is too old; the plugin will not work correctly
    vim.health.error(
      "Neovim " .. ver_str .. " is too old; colflow.nvim requires Neovim 0.9 or newer"
    )
  end

  -- ---------------------------------------------------------------------------
  -- 2. plenary.nvim (test dependency only, not required for normal plugin use)
  -- ---------------------------------------------------------------------------
  local plenary_ok = pcall(require, "plenary")
  if plenary_ok then
    vim.health.ok("plenary.nvim is installed (test suite can run)")
  else
    vim.health.warn(
      "plenary.nvim not found — colflow works normally but the test suite cannot run.\n"
      .. "Install plenary.nvim and run: :PlenaryBustedDirectory tests/"
    )
  end

  -- ---------------------------------------------------------------------------
  -- 3. Current colflow state
  -- ---------------------------------------------------------------------------
  local state = require("colflow.state")

  if state.is_active() then
    local windows      = state.get_windows()
    local column_count = #windows
    local bufnr        = state.get_anchor_bufnr()

    -- Report active status and high-level summary
    vim.health.ok(string.format(
      "colflow is active: %d columns, buffer #%d",
      column_count,
      bufnr
    ))

    -- Report the validity of each managed window individually
    for list_index, win_id in ipairs(windows) do
      local col_index = list_index - 1
      local is_valid  = vim.api.nvim_win_is_valid(win_id)

      if is_valid then
        -- Retrieve topline for extra context in the health report
        local topline = vim.fn.line("w0", win_id)
        vim.health.ok(string.format(
          "  column %d: window #%d  topline=%d  (valid)",
          col_index, win_id, topline
        ))
      else
        -- A stale window ID indicates an internal inconsistency
        vim.health.error(string.format(
          "  column %d: window #%d is no longer valid — state is stale; run :ColflowClose",
          col_index, win_id
        ))
      end
    end
  else
    -- Not active: perfectly normal, just report it
    vim.health.ok("colflow is not currently active")
  end
end

return M
