-- SPDX-License-Identifier: GPL-3.0-or-later
-- =============================================================================
-- plugin/colflow.lua
-- =============================================================================
-- Neovim plugin entry point for colflow.nvim.
--
-- Neovim loads all files in the plugin/ directory automatically at startup.
-- This file's responsibilities are intentionally minimal:
--   1. Guard against being sourced twice (standard Neovim plugin idiom).
--   2. Reject Neovim versions older than 0.9 with an informative message.
--   3. Register the user-facing Ex commands (:ColflowOpen, :ColflowClose, etc.).
--   4. Apply the default configuration so the plugin works out of the box even
--      if the user never calls require("colflow").setup() explicitly.
--
-- Users who want to customise colflow call require("colflow").setup({...}) in
-- their own init.lua.  That call supersedes the default setup done here.
-- =============================================================================

-- Guard: skip the rest of this file if it has already been loaded.
-- vim.g.loaded_colflow is the conventional sentinel used by Neovim plugins.
if vim.g.loaded_colflow then
  return
end
vim.g.loaded_colflow = true

-- Minimum version check: colflow uses APIs introduced in Neovim 0.9
-- (nvim_set_option_value, reliable WinScrolled, vim.health, nvim_win_call).
if vim.fn.has("nvim-0.9") == 0 then
  vim.notify(
    "colflow.nvim requires Neovim 0.9 or newer — plugin not loaded",
    vim.log.levels.WARN
  )
  -- Return early without registering commands or config so nothing is half-set-up
  return
end

-- Register the five user-facing Ex commands.  These are available immediately
-- after Neovim starts, before the user's own init.lua runs.
require("colflow.commands").register()

-- Apply the built-in defaults so the plugin is fully functional with zero
-- user configuration.  A subsequent require("colflow").setup({...}) call in
-- the user's init.lua will merge their preferences on top of these defaults.
require("colflow").setup({})
