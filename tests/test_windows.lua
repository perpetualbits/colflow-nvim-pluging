-- =============================================================================
-- tests/test_windows.lua
-- =============================================================================
-- Tests for lua/colflow/windows.lua: window creation, option configuration,
-- and the close_extra_windows() teardown path.
--
-- These tests create real Neovim windows and require a running Neovim instance.
-- They are designed for the headless plenary test runner.
-- =============================================================================

local state   = require("colflow.state")
local windows = require("colflow.windows")
local colflow = require("colflow")

-- Helper: create a fresh scratch buffer filled with 300 numbered lines and
-- load it in the current (only) window.  Returns the buffer number.
local function make_test_buffer()
  local buf = vim.api.nvim_create_buf(false, true)  -- unlisted, scratch
  local lines = {}
  for i = 1, 300 do
    lines[i] = string.format("line %03d", i)
  end
  -- Set all 300 lines in one call; more efficient than line-by-line
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

-- Helper: close every window except the current one.  Used to guarantee a clean
-- single-window starting state regardless of previous test residue.
local function close_extra_windows()
  local current_win = vim.api.nvim_get_current_win()
  for _, win_id in ipairs(vim.api.nvim_list_wins()) do
    if win_id ~= current_win then
      -- force = true to skip the "unsaved changes" guard during teardown
      pcall(vim.api.nvim_win_close, win_id, true)
    end
  end
end

describe("colflow.windows", function()

  before_each(function()
    -- Ensure clean state before each test
    if state.is_active() then
      colflow.close()
    end
    state.clear()

    -- Minimal config: min_col_width=1 to prevent width-based column reduction
    -- in the narrow headless test environment
    state.set_config({
      columns         = 3,
      min_col_width   = 1,
      hide_signcolumn = true,
      hide_numbers    = "rightmost-only",
      keymaps         = {},
    })

    -- Start with exactly one window showing a fresh scratch buffer
    close_extra_windows()
    make_test_buffer()
  end)

  after_each(function()
    -- Clean up after each test to avoid leaked windows affecting subsequent tests
    if state.is_active() then
      colflow.close()
    end
    state.clear()
    close_extra_windows()
  end)

  -- ===========================================================================
  -- open() creates N windows showing the same buffer
  -- ===========================================================================

  it("open(3) returns a list of 3 window IDs", function()
    local ordered_wins, effective_n = windows.open(3)

    assert.is_not_nil(ordered_wins)
    assert.equals(3, #ordered_wins)
    assert.equals(3, effective_n)
  end)

  it("open(3) creates 3 windows all showing the anchor buffer", function()
    local anchor_bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local ordered_wins = windows.open(3)

    assert.is_not_nil(ordered_wins)

    -- Every managed window must show the anchor buffer
    for i, win_id in ipairs(ordered_wins) do
      assert.is_true(
        vim.api.nvim_win_is_valid(win_id),
        string.format("window at index %d (%d) should be valid", i, win_id)
      )
      assert.equals(
        anchor_bufnr,
        vim.api.nvim_win_get_buf(win_id),
        string.format("window %d should show the anchor buffer #%d", win_id, anchor_bufnr)
      )
    end
  end)

  it("open(1) returns a single-element list (just the anchor)", function()
    local ordered_wins, effective_n = windows.open(1)

    assert.is_not_nil(ordered_wins)
    assert.equals(1, #ordered_wins)
    assert.equals(1, effective_n)
  end)

  it("open(2) creates exactly 2 windows", function()
    local ordered_wins = windows.open(2)

    assert.is_not_nil(ordered_wins)
    assert.equals(2, #ordered_wins)
  end)

  -- ===========================================================================
  -- wrap and foldenable are disabled in all managed windows
  -- ===========================================================================

  it("open(3) disables wrap in every managed window", function()
    local ordered_wins = windows.open(3)

    for _, win_id in ipairs(ordered_wins) do
      assert.is_false(
        vim.api.nvim_get_option_value("wrap", { win = win_id }),
        "wrap must be off in window " .. win_id
      )
    end
  end)

  it("open(3) disables foldenable in every managed window", function()
    local ordered_wins = windows.open(3)

    for _, win_id in ipairs(ordered_wins) do
      assert.is_false(
        vim.api.nvim_get_option_value("foldenable", { win = win_id }),
        "foldenable must be off in window " .. win_id
      )
    end
  end)

  -- ===========================================================================
  -- close_extra_windows() teardown
  -- ===========================================================================

  it("close_extra_windows() leaves the anchor window valid", function()
    local ordered_wins = windows.open(3)

    -- Activate state so close_extra_windows reads the right window list
    local bufnr = vim.api.nvim_win_get_buf(ordered_wins[1])
    state.set_active(ordered_wins, bufnr, nil)

    windows.close_extra_windows()

    -- Anchor (index 1) must still be open
    assert.is_true(
      vim.api.nvim_win_is_valid(ordered_wins[1]),
      "anchor window should still be valid after close_extra_windows()"
    )
  end)

  it("close_extra_windows() closes all non-anchor windows", function()
    local ordered_wins = windows.open(3)

    local bufnr = vim.api.nvim_win_get_buf(ordered_wins[1])
    state.set_active(ordered_wins, bufnr, nil)

    windows.close_extra_windows()

    -- Windows at indices 2 and 3 must now be invalid (closed)
    for i = 2, #ordered_wins do
      assert.is_false(
        vim.api.nvim_win_is_valid(ordered_wins[i]),
        "extra window " .. ordered_wins[i] .. " should be closed"
      )
    end
  end)

  it("close_extra_windows() does not crash if an extra window was already closed", function()
    local ordered_wins = windows.open(3)

    local bufnr = vim.api.nvim_win_get_buf(ordered_wins[1])
    state.set_active(ordered_wins, bufnr, nil)

    -- Manually close the second window before calling close_extra_windows()
    vim.api.nvim_win_close(ordered_wins[2], true)

    -- Should handle the already-closed window gracefully (no error)
    assert.has_no_error(function()
      windows.close_extra_windows()
    end)
  end)

  -- ===========================================================================
  -- Initial toplines after open()
  -- ===========================================================================

  it("open(3) sets column 1 topline to anchor_topline + window_height", function()
    local ordered_wins = windows.open(3)

    local window_height  = vim.api.nvim_win_get_height(ordered_wins[1])
    local anchor_topline = vim.fn.line("w0", ordered_wins[1])
    local col1_topline   = vim.fn.line("w0", ordered_wins[2])

    -- The invariant: topline(col[1]) == topline(col[0]) + window_height
    assert.equals(
      anchor_topline + window_height,
      col1_topline,
      string.format(
        "col1 topline should be %d + %d = %d, got %d",
        anchor_topline, window_height,
        anchor_topline + window_height,
        col1_topline
      )
    )
  end)

  it("open(3) sets column 2 topline to anchor_topline + 2 * window_height", function()
    local ordered_wins = windows.open(3)

    local window_height  = vim.api.nvim_win_get_height(ordered_wins[1])
    local anchor_topline = vim.fn.line("w0", ordered_wins[1])
    local col2_topline   = vim.fn.line("w0", ordered_wins[3])

    assert.equals(
      anchor_topline + 2 * window_height,
      col2_topline,
      string.format(
        "col2 topline should be %d + 2*%d = %d, got %d",
        anchor_topline, window_height,
        anchor_topline + 2 * window_height,
        col2_topline
      )
    )
  end)

end)
