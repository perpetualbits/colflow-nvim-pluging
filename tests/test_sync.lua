-- =============================================================================
-- tests/test_sync.lua
-- =============================================================================
-- Unit tests for the topline offset arithmetic at the heart of sync.lua.
--
-- The synchronization algorithm is a pair of inverse formulas:
--
--   Forward  (apply invariant):
--     topline(window[i]) = anchor_topline + i * window_height
--
--   Reverse  (derive anchor from focused window):
--     anchor_topline = focused_topline - column_index * window_height
--
-- These tests verify the arithmetic directly as pure Lua functions, without
-- going through the autocmd machinery or requiring real Neovim windows.
-- =============================================================================

describe("colflow sync: topline offset arithmetic", function()

  -- ==========================================================================
  -- Local helpers that mirror the formulas used in sync.on_scroll_or_cursor
  -- and state.apply_anchor_topline.
  -- ==========================================================================

  -- Derives the anchor topline given the focused window's parameters.
  -- Mirrors sync.on_scroll_or_cursor's anchor derivation.
  local function derive_anchor(focused_topline, column_index, window_height)
    return focused_topline - column_index * window_height
  end

  -- Computes the topline for a given column given the anchor topline.
  -- Mirrors state.apply_anchor_topline's per-window topline computation.
  local function column_topline(anchor_topline, column_index, window_height)
    return anchor_topline + column_index * window_height
  end

  -- ==========================================================================
  -- Baseline case from the prompt spec
  -- ==========================================================================

  it("focused window at column 2, topline 101, height 50 → anchor topline 1", function()
    -- Given: column 2 shows line 101 at the top; height = 50
    -- Expected: anchor (column 0) should show line 1 at the top
    --   anchor = 101 - 2*50 = 101 - 100 = 1
    assert.equals(1, derive_anchor(101, 2, 50))
  end)

  it("anchor topline 1, height 50 → column 2 topline 101", function()
    -- Direct application of the forward formula
    --   topline = 1 + 2*50 = 101
    assert.equals(101, column_topline(1, 2, 50))
  end)

  -- ==========================================================================
  -- Round-trip identity: for any column i, derive_anchor(column_topline(a,i,h), i, h) == a
  -- ==========================================================================

  it("round-trip: anchor → column → anchor gives back the original anchor", function()
    local window_height = 50

    -- Test with a variety of anchor toplines and column counts
    local test_cases = {
      { anchor = 1,   columns = 3 },
      { anchor = 51,  columns = 3 },
      { anchor = 100, columns = 4 },
      { anchor = 1,   columns = 1 },
    }

    for _, tc in ipairs(test_cases) do
      for col_index = 0, tc.columns - 1 do
        -- Step 1: compute the topline that column col_index should show
        local col_top = column_topline(tc.anchor, col_index, window_height)

        -- Step 2: reverse the formula to get back the anchor
        local recovered_anchor = derive_anchor(col_top, col_index, window_height)

        assert.equals(
          tc.anchor,
          recovered_anchor,
          string.format(
            "round-trip failed: anchor=%d col=%d → col_top=%d → recovered=%d",
            tc.anchor, col_index, col_top, recovered_anchor
          )
        )
      end
    end
  end)

  -- ==========================================================================
  -- Scrolling: shifting the anchor by 1 shifts every column by 1
  -- ==========================================================================

  it("incrementing anchor_topline by 1 increments every column topline by 1", function()
    local window_height = 50

    -- Initial state: anchor at 1 → columns at 1, 51, 101
    local initial_anchor = 1
    local initial_tops = {
      column_topline(initial_anchor, 0, window_height),   -- 1
      column_topline(initial_anchor, 1, window_height),   -- 51
      column_topline(initial_anchor, 2, window_height),   -- 101
    }

    -- User scrolls down 1 line: anchor moves to 2
    local new_anchor = initial_anchor + 1
    local new_tops = {
      column_topline(new_anchor, 0, window_height),   -- 2
      column_topline(new_anchor, 1, window_height),   -- 52
      column_topline(new_anchor, 2, window_height),   -- 102
    }

    for i = 1, 3 do
      assert.equals(
        initial_tops[i] + 1,
        new_tops[i],
        string.format("column %d: expected %d+1=%d, got %d",
          i - 1, initial_tops[i], initial_tops[i] + 1, new_tops[i])
      )
    end
  end)

  -- ==========================================================================
  -- Focused window is column 1 (not the anchor and not the last)
  -- ==========================================================================

  it("focused column 1 with topline 52 gives anchor 2 and correct column toplines", function()
    local focused_topline = 52
    local column_index    = 1
    local window_height   = 50

    -- Derive anchor from column 1's topline
    local anchor = derive_anchor(focused_topline, column_index, window_height)
    -- anchor = 52 - 1*50 = 2
    assert.equals(2, anchor)

    -- All three column toplines should be consistent
    assert.equals(2,   column_topline(anchor, 0, window_height))  -- col 0
    assert.equals(52,  column_topline(anchor, 1, window_height))  -- col 1 (focused)
    assert.equals(102, column_topline(anchor, 2, window_height))  -- col 2
  end)

  -- ==========================================================================
  -- Anchor stays at 1 when window_height == 50 and cursor is in column 0
  -- ==========================================================================

  it("anchor window focused with topline 1 leaves anchor_topline as 1", function()
    -- When the anchor window itself is focused (column_index = 0),
    -- derive_anchor should return the anchor's own topline unchanged.
    assert.equals(1, derive_anchor(1, 0, 50))
    assert.equals(25, derive_anchor(25, 0, 50))
  end)

  -- ==========================================================================
  -- Different window heights
  -- ==========================================================================

  it("works correctly with a window height of 30 (not just 50)", function()
    local h = 30  -- height

    -- With anchor at 1: col0=1, col1=31, col2=61
    assert.equals(1,  column_topline(1, 0, h))
    assert.equals(31, column_topline(1, 1, h))
    assert.equals(61, column_topline(1, 2, h))

    -- Reverse: col2 topline 61, height 30 → anchor 1
    assert.equals(1, derive_anchor(61, 2, h))
  end)

  -- ==========================================================================
  -- Clamping: negative or zero anchor toplines are illegal; callers clamp to >=1
  -- ==========================================================================

  it("derive_anchor can produce values < 1 when focused window is near line 1", function()
    -- This is intentional: the caller (state.apply_anchor_topline) clamps to 1.
    -- The formula itself should still return the raw (unclamped) value.
    -- Column 1, topline 10, height 50: anchor = 10 - 50 = -40
    local raw_anchor = derive_anchor(10, 1, 50)
    assert.equals(-40, raw_anchor)

    -- Simulate what apply_anchor_topline does: clamp to 1
    local clamped = math.max(1, raw_anchor)
    assert.equals(1, clamped)
  end)

end)
