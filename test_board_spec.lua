local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("MasyuBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n)
        math.randomseed(42)
        local b = Board:new{ n = n or 6 }
        b:generate()
        return b
    end

    describe("construction", function()
        it("creates a 6×6 board by default", function()
            local b = Board:new()
            assert.are.equal(6, b.n)
        end)

        it("exposes cell-state constants and SIZES", function()
            assert.are.equal(0, Board.CELL_EMPTY)
            assert.are.equal(1, Board.CELL_WHITE)
            assert.are.equal(2, Board.CELL_BLACK)
            assert.are.same({6, 8}, Board.SIZES)
        end)
    end)

    describe("generate", function()
        -- Regression guard for the 2026-07-22 redesign: _checkWin() can only
        -- validate a solution by grid-adjacency ("a marked cell is on the
        -- loop iff it has exactly 2 marked neighbours"), which is only sound
        -- for a CHORDLESS (induced) cycle -- no two loop cells that are
        -- non-consecutive in the loop may be grid-adjacent. The previous
        -- generator produced a full Hamiltonian cycle (100% coverage), which
        -- always violates this. The generator now grows a sparse loop and
        -- must never produce a chord.
        it("solution_loop has no duplicate cells and no chords (non-consecutive cells are never grid-adjacent)", function()
            for _, n in ipairs(Board.SIZES) do
                for trial = 1, 20 do
                    math.randomseed(n * 1000 + trial)
                    local b     = Board:new{ n = n }
                    b:generate()
                    local total = #b.solution_loop
                    local pos   = {}
                    for i, cell in ipairs(b.solution_loop) do
                        local key = cell[1] * 100 + cell[2]
                        assert.is_nil(pos[key], "cell visited twice by the loop")
                        pos[key] = i
                    end
                    for i, cell in ipairs(b.solution_loop) do
                        for _, d in ipairs{ {-1,0}, {1,0}, {0,-1}, {0,1} } do
                            local nr, nc = cell[1] + d[1], cell[2] + d[2]
                            local j = pos[nr * 100 + nc]
                            if j then
                                local dist     = math.abs(i - j)
                                local cyc_dist = math.min(dist, total - dist)
                                assert.are.equal(1, cyc_dist,
                                    ("n=%d trial=%d: chord between loop positions %d and %d"):format(n, trial, i, j))
                            end
                        end
                    end
                end
            end
        end)

        it("every consecutive pair of loop cells is orthogonally adjacent", function()
            for _, n in ipairs(Board.SIZES) do
                for trial = 1, 20 do
                    math.randomseed(n * 1000 + trial)
                    local b = Board:new{ n = n }
                    b:generate()
                    local total = #b.solution_loop
                    for i = 1, total do
                        local a   = b.solution_loop[i]
                        local nxt = b.solution_loop[(i % total) + 1]
                        local d   = math.abs(a[1] - nxt[1]) + math.abs(a[2] - nxt[2])
                        assert.are.equal(1, d,
                            ("n=%d trial=%d: loop pos %d->%d not adjacent"):format(n, trial, i, (i % total) + 1))
                    end
                end
            end
        end)

        it("produces a sparse loop (not full-grid coverage) for both sizes", function()
            for _, n in ipairs(Board.SIZES) do
                local b = newBoard(n)
                assert.is_true(#b.solution_loop < n * n,
                    ("n=%d: loop covers the entire grid (%d cells) -- checkWin can never validate a full-coverage loop"):format(n, #b.solution_loop))
                assert.is_true(#b.solution_loop >= 4)
            end
        end)

        it("places at least one clue", function()
            local b = newBoard(6)
            local count = 0
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.clues[r][c] ~= Board.CELL_EMPTY then count = count + 1 end
                end
            end
            assert.is_true(count >= 1)
        end)
    end)

    describe("tapCell", function()
        it("toggles a cell in the user path", function()
            local b = newBoard(6)
            local r, c = b.solution_loop[1][1], b.solution_loop[1][2]
            assert.is_false(b.user_path[r][c])
            b:tapCell(r, c)
            assert.is_true(b.user_path[r][c])
        end)

        it("out-of-bounds taps are no-ops", function()
            local b = newBoard(6)
            b:tapCell(0, 0)
            b:tapCell(b.n + 1, 1)
            -- No error raised; nothing to assert beyond survival
        end)
    end)

    describe("win detection", function()
        it("marking the full solution loop as the user path satisfies every circle", function()
            local b = newBoard(6)
            for _, cell in ipairs(b.solution_loop) do
                b.user_path[cell[1]][cell[2]] = true
            end
            local satisfied, total = b:countCirclesSatisfied()
            assert.are.equal(total, satisfied)
        end)

        -- Regression guard for the 2026-07-22 fix: this used to be
        -- unreachable (pending()) because the generator produced a
        -- full-coverage loop -- see the chordless-loop comment above
        -- generate(). Tracing the exact generated solution must now win.
        it("marking the exact generated solution wins, for both sizes", function()
            for _, n in ipairs(Board.SIZES) do
                for trial = 1, 20 do
                    math.randomseed(n * 2000 + trial)
                    local b = Board:new{ n = n }
                    b:generate()
                    for _, cell in ipairs(b.solution_loop) do
                        b.user_path[cell[1]][cell[2]] = true
                    end
                    b:_checkWin()
                    assert.is_true(b.won,
                        ("n=%d trial=%d: exact solution did not satisfy _checkWin()"):format(n, trial))
                end
            end
        end)

        it("won is false on a fresh board", function()
            local b = newBoard(6)
            assert.is_false(b.won)
        end)
    end)

    describe("clearAll / toggleReveal", function()
        it("clearAll resets the user path and won", function()
            local b = newBoard(6)
            for _, cell in ipairs(b.solution_loop) do
                b.user_path[cell[1]][cell[2]] = true
            end
            b:clearAll()
            assert.are.equal(0, b:countUserPath())
            assert.is_false(b.won)
        end)

        it("toggleReveal flips isShowingSolution", function()
            local b = newBoard(6)
            assert.is_false(b:isShowingSolution())
            b:toggleReveal()
            assert.is_true(b:isShowingSolution())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips clues, solution loop and user path", function()
            local b = newBoard(6)
            local r, c = b.solution_loop[1][1], b.solution_loop[1][2]
            b:tapCell(r, c)

            local data = b:serialize()
            local b2 = Board:new{ n = 6 }
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(#b.solution_loop, #b2.solution_loop)
            assert.are.equal(b.user_path[r][c], b2.user_path[r][c])
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
