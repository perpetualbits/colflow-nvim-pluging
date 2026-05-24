-- =============================================================================
-- tests/minimal_init.lua
-- =============================================================================
-- Minimal Neovim init file used when running the colflow test suite headlessly.
--
-- Usage:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
--
-- This file does three things:
--   1. Adds the colflow plugin root to runtimepath so require("colflow.*") works.
--   2. Locates and adds plenary.nvim to runtimepath so the test runner is available.
--   3. Calls require("colflow").setup({}) with minimal options for testing.
-- =============================================================================

-- Derive the plugin root directory relative to this file's location.
-- debug.getinfo(1, "S").source is the file path of this script.
-- Sub-string from character 2 strips the leading "@" that Lua prepends.
local this_file   = debug.getinfo(1, "S").source:sub(2)
local test_dir    = vim.fn.fnamemodify(this_file, ":p:h")   -- absolute path to tests/
local plugin_root = vim.fn.fnamemodify(test_dir .. "/..", ":p")  -- absolute path to repo root

-- Add the plugin root to runtimepath so Lua module resolution finds lua/colflow/
vim.opt.runtimepath:prepend(plugin_root)

-- ---------------------------------------------------------------------------
-- Locate plenary.nvim
-- ---------------------------------------------------------------------------
-- We try several common installation locations used by different plugin managers.

-- Candidate paths in preference order
local plenary_candidates = {
  -- lazy.nvim default data directory
  vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  -- vim-plug default
  vim.fn.expand("~/.vim/plugged/plenary.nvim"),
  -- packer.nvim default
  vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
  -- manual / development checkout next to this repo
  vim.fn.fnamemodify(plugin_root .. "../plenary.nvim", ":p"),
  -- another common lazy path variant
  vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim",
}

local plenary_found = false
for _, candidate in ipairs(plenary_candidates) do
  if vim.fn.isdirectory(candidate) == 1 then
    -- Add plenary to runtimepath so require("plenary.*") resolves correctly
    vim.opt.runtimepath:prepend(candidate)
    plenary_found = true
    break
  end
end

if not plenary_found then
  -- Emit a clear error so the user knows what is missing, then continue.
  -- The test runner itself will fail with a clearer message if plenary is absent.
  vim.notify(
    "colflow tests: plenary.nvim not found — tests will fail to load.\n"
    .. "Install plenary.nvim and ensure it is on runtimepath.",
    vim.log.levels.ERROR
  )
end

-- ---------------------------------------------------------------------------
-- Minimal colflow setup for tests
-- ---------------------------------------------------------------------------
-- Use min_col_width=1 so width-based column-count reduction never fires during
-- tests (headless Neovim windows are very narrow by default).
require("colflow").setup({
  columns         = 3,
  min_col_width   = 1,
  hide_signcolumn = true,
  hide_numbers    = "none",   -- "none" avoids option-setting errors in headless env
  keymaps         = {},       -- no keymaps in tests
})

-- Register the :ColflowOpen / Close / Toggle / Inc / Dec commands.
-- plugin/colflow.lua is the normal entry point for this, but it is not
-- auto-sourced when Neovim starts with -u <minimal_init>. We register
-- commands explicitly so integration tests that call vim.cmd("ColflowOpen 3")
-- work correctly.
require("colflow.commands").register()
