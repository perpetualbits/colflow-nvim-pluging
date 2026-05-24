-- =============================================================================
-- tests/test_close.lua
-- =============================================================================
-- Tests for the close() and toggle() public API calls in colflow/init.lua.
--
-- Covers:
--   * close() removes extra windows and clears all state fields
--   * close() is idempotent (safe to call when not active)
--   * close() preserves the anchor window and its buffer content
--   * toggle() opens when closed, closes when open
--   * inc() / dec() adjust the column count correctly
-- =============================================================================

local state  = require("colflow.state")
local colflow = require("colflow")

-- Helper: create a 300-line scratch buffer and load it in the current window.
local function make_test_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, 300 do lines[i] = string.format("line %03d", i) end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(0, buf)
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

describe("colflow.close and lifecycle", function()

  before_each(function()
    -- Full state reset before each test
    if state.is_active() then
      colflow.close()
    end
    state.clear()

    -- Minimal config; min_col_width=1 to prevent width-based reduction
    state.set_config({
      columns         = 3,
      min_col_width   = 1,
      hide_signcolumn = true,
      hide_numbers    = "none",
      keymaps         = {},
    })

    close_all_but_current()
    make_test_buffer()
  end)

  after_each(function()
    if state.is_active() then
      colflow.close()
    end
    state.clear()
    close_all_but_current()
  end)

  -- ===========================================================================
  -- close() core behaviour
  -- ===========================================================================

  it("close() after open(3) marks colflow as inactive", function()
    colflow.open(3)
    assert.is_true(state.is_active())

    colflow.close()
    assert.is_false(state.is_active())
  end)

  it("close() clears the window list to empty", function()
    colflow.open(3)
    colflow.close()

    assert.equals(0, state.get_column_count())
    assert.equals(0, #state.get_windows())
  end)

  it("close() clears anchor_bufnr to nil", function()
    colflow.open(3)
    colflow.close()

    assert.is_nil(state.get_anchor_bufnr())
  end)

  it("close() closes the extra windows (columns 1 and 2) but not the anchor", function()
    local anchor_win_id = vim.api.nvim_get_current_win()
    colflow.open(3)

    -- Capture the extra window IDs before close() clears state
    local all_wins    = vim.deepcopy(state.get_windows())
    local extra_wins  = { all_wins[2], all_wins[3] }

    colflow.close()

    -- Anchor window must still be valid
    assert.is_true(
      vim.api.nvim_win_is_valid(anchor_win_id),
      "anchor window should still be open after close()"
    )

    -- Extra windows must be closed (invalid)
    for _, win_id in ipairs(extra_wins) do
      assert.is_false(
        vim.api.nvim_win_is_valid(win_id),
        "extra window " .. win_id .. " should be closed after close()"
      )
    end
  end)

  -- ===========================================================================
  -- close() idempotency
  -- ===========================================================================

  it("close() is safe to call when colflow is not active (no error)", function()
    assert.is_false(state.is_active())

    -- Should not raise an error
    assert.has_no_error(function()
      colflow.close()
    end)

    assert.is_false(state.is_active())
  end)

  it("calling close() twice does not raise an error", function()
    colflow.open(3)
    colflow.close()

    -- Second close() should silently do nothing
    assert.has_no_error(function()
      colflow.close()
    end)
  end)

  -- ===========================================================================
  -- close() preserves buffer content
  -- ===========================================================================

  it("close() leaves the anchor buffer's content intact", function()
    local anchor_bufnr = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())

    -- Snapshot the first line before the open/close cycle
    local first_line_before = vim.api.nvim_buf_get_lines(anchor_bufnr, 0, 1, false)[1]

    colflow.open(3)
    colflow.close()

    -- Content must be unchanged after the cycle
    local first_line_after = vim.api.nvim_buf_get_lines(anchor_bufnr, 0, 1, false)[1]
    assert.equals(first_line_before, first_line_after)
  end)

  -- ===========================================================================
  -- toggle()
  -- ===========================================================================

  it("toggle() opens the layout when colflow is inactive", function()
    assert.is_false(state.is_active())

    colflow.toggle(3)
    assert.is_true(state.is_active())
    assert.equals(3, state.get_column_count())
  end)

  it("toggle() closes the layout when colflow is active", function()
    colflow.open(3)
    assert.is_true(state.is_active())

    colflow.toggle()
    assert.is_false(state.is_active())
  end)

  it("toggle() open-close-open cycle works correctly", function()
    colflow.toggle(3)    -- open
    assert.is_true(state.is_active())

    colflow.toggle()     -- close
    assert.is_false(state.is_active())

    colflow.toggle(3)    -- open again
    assert.is_true(state.is_active())
    assert.equals(3, state.get_column_count())
  end)

  -- ===========================================================================
  -- inc() / dec()
  -- ===========================================================================

  it("inc() increases the column count by 1", function()
    colflow.open(3)
    assert.equals(3, state.get_column_count())

    colflow.inc()
    -- After inc(), layout should be re-opened with 4 columns
    assert.is_true(state.is_active())
    assert.equals(4, state.get_column_count())
  end)

  it("dec() decreases the column count by 1", function()
    colflow.open(3)
    assert.equals(3, state.get_column_count())

    colflow.dec()
    -- After dec(), layout should be re-opened with 2 columns
    assert.is_true(state.is_active())
    assert.equals(2, state.get_column_count())
  end)

  it("dec() closes the layout when the count would drop below 2", function()
    colflow.open(2)
    assert.equals(2, state.get_column_count())

    -- dec() from 2 → 1 columns should call close() instead of open(1)
    colflow.dec()
    assert.is_false(state.is_active())
  end)

  -- ===========================================================================
  -- open() re-opens if already active
  -- ===========================================================================

  it("open(4) while 3-column layout is active replaces it with a 4-column layout", function()
    colflow.open(3)
    assert.equals(3, state.get_column_count())

    colflow.open(4)
    assert.is_true(state.is_active())
    assert.equals(4, state.get_column_count())
  end)

end)
