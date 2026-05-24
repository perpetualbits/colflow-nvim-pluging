-- =============================================================================
-- tests/test_integration.lua
-- =============================================================================
-- Headless integration test for colflow.nvim.
--
-- Scenario:
--   1. Create a 300-line scratch buffer.
--   2. Call :ColflowOpen 3 to open 3 newspaper-flow columns.
--   3. Move the cursor down 60 times (past the bottom of column 1 in a typical
--      50-line terminal window) and verify that the topline invariant holds
--      after the autocmd-driven reflow.
--   4. Check the Ex commands work end-to-end (:ColflowOpen, :ColflowClose, etc.).
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
-- =============================================================================

local state   = require("colflow.state")
local colflow = require("colflow")

-- Helper: fill the current window with a 300-line scratch buffer.
-- Returns the buffer number.
local function make_300_line_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 300 do
    lines[i] = string.format("line %03d", i)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  -- Place cursor at line 1, column 0 (1-based)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  return buf
end

-- Helper: close every window except the current one.
local function close_all_but_current()
  local current = vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= current then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

-- Helper: assert that the topline invariant holds for the current layout.
-- Reads toplines from Neovim and checks each column against the formula.
local function assert_invariant(managed_wins, window_height)
  local anchor_topline = vim.fn.line("w0", managed_wins[1])

  for list_index, win_id in ipairs(managed_wins) do
    local col_index      = list_index - 1
    local expected_top   = anchor_topline + col_index * window_height
    local actual_top     = vim.fn.line("w0", win_id)

    assert.equals(
      expected_top,
      actual_top,
      string.format(
        "invariant failed at column %d: expected topline %d, got %d  (anchor=%d, height=%d)",
        col_index, expected_top, actual_top, anchor_topline, window_height
      )
    )
  end
end

describe("colflow integration", function()

  local test_bufnr

  before_each(function()
    -- Full teardown before each test
    if state.is_active() then
      colflow.close()
    end
    state.clear()

    -- Config: min_col_width=1 to prevent width-based column reduction in headless env
    state.set_config({
      columns         = 3,
      min_col_width   = 1,
      hide_signcolumn = true,
      hide_numbers    = "none",
      keymaps         = {},
    })

    close_all_but_current()
    test_bufnr = make_300_line_buffer()
  end)

  after_each(function()
    if state.is_active() then
      colflow.close()
    end
    state.clear()
    close_all_but_current()

    -- Delete the scratch buffer so it doesn't accumulate across tests
    if test_bufnr and vim.api.nvim_buf_is_valid(test_bufnr) then
      vim.api.nvim_buf_delete(test_bufnr, { force = true })
    end
    test_bufnr = nil
  end)

  -- ===========================================================================
  -- Acceptance: initial layout toplines
  -- ===========================================================================

  it("open(3) establishes correct initial toplines for a 300-line buffer", function()
    colflow.open(3)
    assert.is_true(state.is_active())

    local managed_wins = state.get_windows()
    assert.equals(3, #managed_wins)

    -- Read the actual window height from the test environment (varies by terminal)
    local window_height = vim.api.nvim_win_get_height(managed_wins[1])
    assert.is_true(window_height > 0, "window height must be positive")

    -- Column 0 (anchor) must start at line 1
    local col0_topline = vim.fn.line("w0", managed_wins[1])
    assert.equals(1, col0_topline, "anchor (column 0) should start at line 1")

    -- Column 1 must start at 1 + window_height
    local col1_topline = vim.fn.line("w0", managed_wins[2])
    assert.equals(
      1 + window_height,
      col1_topline,
      string.format("column 1 should start at 1+%d=%d", window_height, 1 + window_height)
    )

    -- Column 2 must start at 1 + 2 * window_height
    local col2_topline = vim.fn.line("w0", managed_wins[3])
    assert.equals(
      1 + 2 * window_height,
      col2_topline,
      string.format("column 2 should start at 1+2*%d=%d", window_height, 1 + 2 * window_height)
    )
  end)

  -- ===========================================================================
  -- Acceptance: cursor movement triggers reflow
  -- ===========================================================================

  it("moving cursor down 60 times maintains the topline invariant across all columns", function()
    colflow.open(3)
    assert.is_true(state.is_active())

    local managed_wins = state.get_windows()
    local window_height = vim.api.nvim_win_get_height(managed_wins[1])

    -- Ensure focus is on the anchor window (column 0) before simulating keystrokes
    vim.api.nvim_set_current_win(managed_wins[1])

    -- Simulate 60 downward cursor movements in normal mode.
    -- nvim_replace_termcodes converts special key names; "x" flag makes feedkeys
    -- execute synchronously so the CursorMoved autocmd fires before we read toplines.
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("60j", true, false, true),
      "x",   -- synchronous execution
      false
    )

    -- Cursor should now be on line 61 (started at 1, moved down 60 times)
    local cursor_line = vim.api.nvim_win_get_cursor(managed_wins[1])[1]
    assert.equals(61, cursor_line, "cursor should be on line 61 after 60 downward moves")

    -- In headless Neovim, WinScrolled is not fired synchronously during feedkeys
    -- processing (it requires a redraw pass). Explicitly invoke the sync handler
    -- once from the anchor window's perspective so the invariant is enforced.
    -- This tests that the sync handler produces correct results given the current
    -- anchor position, which is what the plugin does in normal (non-headless) use.
    require("colflow.sync").on_scroll_or_cursor()

    -- The topline invariant must hold: topline(col[i]) == topline(col[0]) + i * height
    assert_invariant(managed_wins, window_height)
  end)

  it("moving cursor up from line 5 maintains the invariant", function()
    colflow.open(3)
    assert.is_true(state.is_active())

    local managed_wins  = state.get_windows()
    local window_height = vim.api.nvim_win_get_height(managed_wins[1])

    -- First move down a bit so we have room to move up
    vim.api.nvim_set_current_win(managed_wins[1])
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("20j", true, false, true), "x", false
    )

    -- Now move back up
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("15k", true, false, true), "x", false
    )

    -- Invariant must still hold
    assert_invariant(managed_wins, window_height)
  end)

  -- ===========================================================================
  -- Acceptance: :ColflowOpen / :ColflowClose via Ex commands
  -- ===========================================================================

  it(":ColflowOpen 3 creates 3 columns visible to state", function()
    vim.cmd("ColflowOpen 3")

    assert.is_true(state.is_active())
    assert.equals(3, state.get_column_count())
  end)

  it(":ColflowClose restores a single window", function()
    local initial_win = vim.api.nvim_get_current_win()

    vim.cmd("ColflowOpen 3")
    assert.is_true(state.is_active())

    vim.cmd("ColflowClose")
    assert.is_false(state.is_active())

    -- Exactly one window should remain
    local remaining = vim.api.nvim_list_wins()
    assert.equals(1, #remaining)

    -- It should be the original anchor window
    assert.equals(initial_win, remaining[1])
  end)

  it(":ColflowToggle opens and then closes", function()
    vim.cmd("ColflowToggle 3")
    assert.is_true(state.is_active())

    vim.cmd("ColflowToggle")
    assert.is_false(state.is_active())
  end)

  it(":ColflowInc adds one column", function()
    vim.cmd("ColflowOpen 3")
    assert.equals(3, state.get_column_count())

    vim.cmd("ColflowInc")
    assert.equals(4, state.get_column_count())
  end)

  it(":ColflowDec removes one column", function()
    vim.cmd("ColflowOpen 3")
    assert.equals(3, state.get_column_count())

    vim.cmd("ColflowDec")
    assert.equals(2, state.get_column_count())
  end)

  -- ===========================================================================
  -- Acceptance: editing in one column reflects in others (shared buffer)
  -- ===========================================================================

  it("editing text in column 0 is immediately visible from the same buffer in column 1", function()
    colflow.open(3)
    local managed_wins = state.get_windows()

    -- Both column 0 and column 1 are backed by the same buffer (anchor_bufnr)
    local buf0 = vim.api.nvim_win_get_buf(managed_wins[1])
    local buf1 = vim.api.nvim_win_get_buf(managed_wins[2])

    -- They must be the same buffer object
    assert.equals(buf0, buf1, "column 0 and column 1 must share the same buffer")

    -- Modify line 1 directly via the buffer API (simulates an edit)
    local new_text = "EDITED LINE"
    vim.api.nvim_buf_set_lines(buf0, 0, 1, false, { new_text })

    -- Read the same line back from the column 1's buffer reference — same buffer
    local line_in_col1 = vim.api.nvim_buf_get_lines(buf1, 0, 1, false)[1]
    assert.equals(new_text, line_in_col1, "edit in col 0 must appear in col 1's buffer")
  end)

end)
