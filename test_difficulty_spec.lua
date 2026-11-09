-- Difficulty guarantees for Masyu (see docs/dev/TESTING.md, "Difficulty
-- specs"). Masyu has no levels, only sizes: every size gives a unique
-- puzzle that the game's own no-trial solver finishes on its own loop, the
-- stored fallbacks too, 8x8 asks for at least as much reasoning as 6x6 on
-- average, a seed gives the same puzzle, generation is quick and never
-- reads the clock (it once had an os.clock cap).
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

describe("Masyu difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local function loopSet(b)
        local on = {}
        for _, cell in ipairs(b.solution_loop) do on[(cell[1] - 1) * b.n + cell[2]] = true end
        return on
    end
    local function countClues(b)
        local k = 0
        for r = 1, b.n do for c = 1, b.n do
            if b.clues[r][c] ~= Board.CELL_EMPTY then k = k + 1 end
        end end
        return k
    end

    -- moved from test_board_spec.lua
    it("builds the same uniquely solvable puzzle for a seed, quickly", function()
        for _, n in ipairs(Board.SIZES) do
            local worst = 0
            for seed = 1, 10 do
                math.randomseed(seed * 7919 + n)
                local b = Board:new{ n = n }
                local t0 = os.clock()
                b:generate()
                worst = math.max(worst, os.clock() - t0)
                local count, exhausted = Board._countSolutions(b.clues, n, 2, 10000000)
                assert.is_false(exhausted)
                assert.are.equal(1, count, ("n=%d seed %d not unique"):format(n, seed))
                math.randomseed(seed * 7919 + n)
                local b2 = Board:new{ n = n }
                b2:generate()
                assert.are.same(b.clues, b2.clues)
            end
            -- generous: ~0.03 s on a desktop
            assert.is_true(worst < 2.0, ("n=%d took %.2f s"):format(n, worst))
        end
    end)

    -- moved from test_board_spec.lua
    it("every generated puzzle is finished without guessing, on its own loop (40 seeds per size)", function()
        for _, n in ipairs(Board.SIZES) do
            for seed = 1, 40 do
                math.randomseed(seed * 31 + n)
                local b = Board:new{ n = n }
                b:generate()
                local ok, val, stats = Board._logicSolve(b.clues, n)
                assert.is_true(ok, ("n=%d seed %d needs guessing"):format(n, seed))
                assert.are.equal(0, stats.undecided)
                local on = loopSet(b)
                for i = 1, n * n do
                    assert.are.equal(on[i] or false, val[i], ("n=%d seed %d cell %d"):format(n, seed, i))
                end
                local k = countClues(b)
                assert.is_true(k >= 4 and k <= math.floor(n * n / 2))
            end
        end
    end)

    -- moved from test_board_spec.lua
    it("the stored fallback puzzles are valid, unique and need no guessing", function()
        for n, fb in pairs(Board._FALLBACK) do
            local clues = {}
            for r = 1, n do
                clues[r] = {}
                for c = 1, n do
                    local ch = fb.rows[r]:sub(c, c)
                    clues[r][c] = ch == "W" and Board.CELL_WHITE or ch == "B" and Board.CELL_BLACK or Board.CELL_EMPTY
                end
            end
            assert.is_true((Board._logicSolve(clues, n)))
            local count, exhausted = Board._countSolutions(clues, n, 2, 10000000)
            assert.is_false(exhausted)
            assert.are.equal(1, count)
            local b = Board:new{ n = n }
            b.clues, b.solution_loop = clues, fb.loop
            for _, cell in ipairs(fb.loop) do b:setPathCell(cell[1], cell[2], true) end
            assert.is_true(b.won, "fallback " .. n)
        end
    end)

    it("8x8 needs at least as much reasoning as 6x6, on average", function()
        local t2, clues = {}, {}
        for _, n in ipairs(Board.SIZES) do
            t2[n], clues[n] = 0, 0
            for seed = 1, 10 do
                math.randomseed(seed * 31 + n)
                local b = Board:new{ n = n }
                b:generate()
                local ok, _, stats = Board._logicSolve(b.clues, n)
                assert.is_true(ok)
                t2[n], clues[n] = t2[n] + stats.t2, clues[n] + countClues(b)
            end
        end
        assert.is_true(t2[8] >= t2[6], ("tier-2 steps 6x6 %d, 8x8 %d"):format(t2[6], t2[8]))
        assert.is_true(clues[8] > clues[6])
    end)

    it("generation never reads the clock", function()
        for _, n in ipairs(Board.SIZES) do
            local reads = clockReads(function()
                math.randomseed(17 + n)
                Board:new{ n = n }:generate()
            end)
            assert.are.equal(0, reads, ("n=%d read the clock"):format(n))
        end
    end)
end)
