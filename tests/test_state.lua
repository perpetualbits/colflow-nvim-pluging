-- =============================================================================
-- tests/test_state.lua
-- =============================================================================
-- Unit tests for lua/colflow/state.lua
--
-- All tests use fake (integer) window IDs to avoid requiring real Neovim windows.
-- The only function that requires real windows is apply_anchor_topline(), which
-- is tested via the integration test in test_integration.lua.
--
-- Run with:
--   nvim --headless -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/ {minimal_init='tests/minimal_init.lua'}"
-- =============================================================================

local state = require("colflow.state")

describe("colflow.state", function()

  -- Reset module state before every test to ensure full isolation.
  -- We do not reset config because setup() persists it across clear() calls
  -- (intentional behaviour: config survives close).
  before_each(function()
    state.clear()
    -- Install a minimal test config so get_config() always returns a table
    state.set_config({
      columns         = 3,
      min_col_width   = 1,
      hide_signcolumn = true,
      hide_numbers    = "rightmost-only",
      keymaps         = {},
    })
  end)

  -- ===========================================================================
  -- column_index_of: unmanaged window IDs
  -- ===========================================================================

  it("column_index_of returns nil when no windows are managed (not active)", function()
    -- Before any set_active() call the managed list is empty
    assert.is_nil(state.column_index_of(9999))
    assert.is_nil(state.column_index_of(1))
  end)

  it("column_index_of returns nil for a window ID not in the managed list", function()
    -- Activate with windows [100, 101, 102]
    state.set_active({ 100, 101, 102 }, 5, nil)

    -- 999 is not in the list
    assert.is_nil(state.column_index_of(999))
  end)

  -- ===========================================================================
  -- column_index_of: managed windows return correct 0-based indices
  -- ===========================================================================

  it("column_index_of returns 0 for the anchor (first) window", function()
    state.set_active({ 100, 101, 102 }, 5, nil)
    assert.equals(0, state.column_index_of(100))
  end)

  it("column_index_of returns 1 for the second window", function()
    state.set_active({ 100, 101, 102 }, 5, nil)
    assert.equals(1, state.column_index_of(101))
  end)

  it("column_index_of returns 2 for the third window", function()
    state.set_active({ 100, 101, 102 }, 5, nil)
    assert.equals(2, state.column_index_of(102))
  end)

  it("column_index_of works correctly for a 5-column layout", function()
    -- Test with more columns to confirm the loop handles arbitrary lengths
    local wins = { 10, 20, 30, 40, 50 }
    state.set_active(wins, 1, nil)

    for expected_index, win_id in ipairs(wins) do
      -- ipairs is 1-based; column indices are 0-based
      assert.equals(expected_index - 1, state.column_index_of(win_id))
    end
  end)

  -- ===========================================================================
  -- is_active lifecycle
  -- ===========================================================================

  it("is_active is false before any set_active() call", function()
    -- clear() was called in before_each; state should be inactive
    assert.is_false(state.is_active())
  end)

  it("is_active becomes true after set_active()", function()
    state.set_active({ 1, 2, 3 }, 7, nil)
    assert.is_true(state.is_active())
  end)

  it("is_active becomes false again after clear()", function()
    state.set_active({ 1, 2, 3 }, 7, nil)
    assert.is_true(state.is_active())

    state.clear()
    assert.is_false(state.is_active())
  end)

  -- ===========================================================================
  -- clear() resets all fields
  -- ===========================================================================

  it("clear() empties the window list", function()
    state.set_active({ 10, 20, 30 }, 5, 42)
    state.clear()

    -- get_windows() should return an empty table
    assert.equals(0, #state.get_windows())
  end)

  it("clear() resets anchor_bufnr to nil", function()
    state.set_active({ 10, 20 }, 5, nil)
    state.clear()

    assert.is_nil(state.get_anchor_bufnr())
  end)

  it("clear() resets augroup_id to nil", function()
    state.set_active({ 10, 20 }, 5, 42)
    state.clear()

    assert.is_nil(state.get_augroup_id())
  end)

  it("clear() preserves the config (intentional: setup does not need to be re-called)", function()
    -- Config was set in before_each; clear() must not erase it
    state.clear()

    local cfg = state.get_config()
    assert.is_not_nil(cfg)
    assert.equals(3, cfg.columns)
  end)

  -- ===========================================================================
  -- get_column_count
  -- ===========================================================================

  it("get_column_count returns 0 when inactive", function()
    assert.equals(0, state.get_column_count())
  end)

  it("get_column_count returns the number of managed windows", function()
    state.set_active({ 1, 2, 3, 4 }, 1, nil)
    assert.equals(4, state.get_column_count())
  end)

  -- ===========================================================================
  -- set_augroup_id
  -- ===========================================================================

  it("set_augroup_id can be called after set_active() to attach the augroup separately", function()
    -- set_active() with nil augroup (how init.lua works before autocmds are set up)
    state.set_active({ 1 }, 1, nil)
    assert.is_nil(state.get_augroup_id())

    -- Now attach the augroup ID
    state.set_augroup_id(77)
    assert.equals(77, state.get_augroup_id())
  end)

  -- ===========================================================================
  -- get_anchor_bufnr / get_windows
  -- ===========================================================================

  it("get_anchor_bufnr returns the bufnr passed to set_active()", function()
    state.set_active({ 1, 2 }, 99, nil)
    assert.equals(99, state.get_anchor_bufnr())
  end)

  it("get_windows returns the same table passed to set_active()", function()
    local wins = { 11, 22, 33 }
    state.set_active(wins, 1, nil)

    local returned = state.get_windows()
    -- Check length and each element
    assert.equals(3, #returned)
    assert.equals(11, returned[1])
    assert.equals(22, returned[2])
    assert.equals(33, returned[3])
  end)

end)
