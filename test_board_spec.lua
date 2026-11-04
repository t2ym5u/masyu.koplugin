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

    -- 1.5.0: a propagating counter replaced the one that only checked the
    -- circles at the end (an 8x8 shape took up to a second, so generation
    -- hit its 2 s CPU-time cap and shipped unproven puzzles, different per
    -- device). Keep the old counter here and check the two agree, and that
    -- generation is deterministic, unique and quick at both sizes.
    describe("counter and generator", function()
        local CELL_EMPTY, CELL_WHITE, CELL_BLACK = 0, 1, 2
        local DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1} }

        -- The pre-1.5.0 counter, verbatim.
        local function oldCountSolutions(clues, n, limit, node_budget)
            local marked = {}
            for r = 1, n do marked[r] = {} end

            local order, seen = {}, {}
            for r = 1, n do
                for c = 1, n do
                    if clues[r][c] ~= CELL_EMPTY then
                        marked[r][c] = true
                        seen[r * 1000 + c] = true
                    end
                end
            end
            for r = 1, n do
                for c = 1, n do
                    if clues[r][c] ~= CELL_EMPTY then
                        for _, d in ipairs(DIRS) do
                            local nr, nc = r + d[1], c + d[2]
                            if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                                local k = nr * 1000 + nc
                                if not seen[k] then seen[k] = true; order[#order + 1] = { r = nr, c = nc } end
                                for _, d2 in ipairs(DIRS) do
                                    local nr2, nc2 = nr + d2[1], nc + d2[2]
                                    if nr2 >= 1 and nr2 <= n and nc2 >= 1 and nc2 <= n then
                                        local k2 = nr2 * 1000 + nc2
                                        if not seen[k2] then seen[k2] = true; order[#order + 1] = { r = nr2, c = nc2 } end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            for r = 1, n do
                for c = 1, n do
                    local k = r * 1000 + c
                    if not seen[k] then seen[k] = true; order[#order + 1] = { r = r, c = c } end
                end
            end

            local solutions, nodes, exhausted = 0, 0, false

            local function markedNeighborInfo(r, c)
                local have, undecided = 0, {}
                for _, d in ipairs(DIRS) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                        local v = marked[nr][nc]
                        if v == true then have = have + 1
                        elseif v == nil then undecided[#undecided + 1] = { nr, nc } end
                    end
                end
                return have, undecided
            end

            local function arms(r, c)
                local a = {}
                for _, d in ipairs(DIRS) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and marked[nr][nc] then a[#a + 1] = d end
                end
                return a
            end
            local function isTurnFinal(r, c)
                local a = arms(r, c)
                return #a == 2 and not (a[1][1] == -a[2][1] and a[1][2] == -a[2][2])
            end
            local function isStraightFinal(r, c)
                local a = arms(r, c)
                return #a == 2 and a[1][1] == -a[2][1] and a[1][2] == -a[2][2]
            end

            local function isSingleLoopFinal()
                local total, start_r, start_c = 0, nil, nil
                for r = 1, n do
                    for c = 1, n do
                        if marked[r][c] then
                            total = total + 1
                            if not start_r then start_r, start_c = r, c end
                        end
                    end
                end
                if total == 0 then return false end
                local visited = 0
                local cur_r, cur_c = start_r, start_c
                local prev_r, prev_c = nil, nil
                repeat
                    visited = visited + 1
                    local next_r, next_c
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cur_r + d[1], cur_c + d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n and marked[nr][nc]
                            and not (nr == prev_r and nc == prev_c) then
                            next_r, next_c = nr, nc
                            break
                        end
                    end
                    if not next_r then return false end
                    prev_r, prev_c = cur_r, cur_c
                    cur_r, cur_c = next_r, next_c
                until cur_r == start_r and cur_c == start_c
                return visited == total
            end

            local function allCluesOKFinal()
                for r = 1, n do
                    for c = 1, n do
                        local clue = clues[r][c]
                        if clue == CELL_BLACK then
                            if not marked[r][c] or not isTurnFinal(r, c) then return false end
                            for _, d in ipairs(arms(r, c)) do
                                if not isStraightFinal(r + d[1], c + d[2]) then return false end
                            end
                        elseif clue == CELL_WHITE then
                            if not marked[r][c] or not isStraightFinal(r, c) then return false end
                            local has_turn = false
                            for _, d in ipairs(arms(r, c)) do
                                if isTurnFinal(r + d[1], c + d[2]) then has_turn = true; break end
                            end
                            if not has_turn then return false end
                        end
                    end
                end
                return true
            end

            local function setDecided(r, c, val, changes)
                if marked[r][c] ~= nil then return marked[r][c] == val end
                marked[r][c] = val
                changes[#changes + 1] = { r, c }
                return true
            end

            local function undo(changes)
                for _, cell in ipairs(changes) do marked[cell[1]][cell[2]] = nil end
            end

            local function propagate(changes)
                local progressed = true
                while progressed do
                    progressed = false
                    for r = 1, n do
                        for c = 1, n do
                            if marked[r][c] == true then
                                local have, undecided = markedNeighborInfo(r, c)
                                if have > 2 then return false end
                                if have == 2 and #undecided > 0 then
                                    for _, cell in ipairs(undecided) do
                                        if not setDecided(cell[1], cell[2], false, changes) then return false end
                                    end
                                    progressed = true
                                elseif have + #undecided < 2 then
                                    return false
                                elseif #undecided == 1 and have == 1 then
                                    if not setDecided(undecided[1][1], undecided[1][2], true, changes) then return false end
                                    progressed = true
                                end
                            end
                        end
                    end
                end
                return true
            end

            local function allDecided()
                for r = 1, n do for c = 1, n do if marked[r][c] == nil then return false end end end
                return true
            end

            local function search(idx)
                if solutions >= limit or exhausted then return end
                nodes = nodes + 1
                if nodes > node_budget then exhausted = true; return end

                local changes = {}
                if not propagate(changes) then
                    undo(changes)
                    return
                end

                if allDecided() then
                    if isSingleLoopFinal() and allCluesOKFinal() then solutions = solutions + 1 end
                    undo(changes)
                    return
                end

                local pick_idx
                for i = idx, #order do
                    local cell = order[i]
                    if marked[cell.r][cell.c] == nil then pick_idx = i; break end
                end
                if not pick_idx then
                    undo(changes)
                    return
                end
                local pick = order[pick_idx]

                for _, val in ipairs({ true, false }) do
                    local branch_changes = {}
                    if setDecided(pick.r, pick.c, val, branch_changes) then
                        search(pick_idx + 1)
                    end
                    undo(branch_changes)
                    if solutions >= limit or exhausted then break end
                end
                undo(changes)
            end

            search(1)
            return solutions, exhausted
        end
        local function randomClues(n, seed)
            math.randomseed(seed)
            local b = Board:new{ n = n }
            b:generate()
            -- the generated loop's circles plus random extra/missing ones
            local clues = {}
            for r = 1, n do
                clues[r] = {}
                for c = 1, n do
                    local v = b.clues[r][c]
                    if math.random() < 0.25 then v = CELL_EMPTY end
                    clues[r][c] = v
                end
            end
            for _, cell in ipairs(b.solution_loop) do
                if clues[cell[1]][cell[2]] == CELL_EMPTY and math.random() < 0.15 then
                    clues[cell[1]][cell[2]] = math.random() < 0.5 and CELL_WHITE or CELL_BLACK
                end
            end
            return clues
        end

        it("counts the same solutions as the old counter on random clue sets", function()
            for _, n in ipairs({ 5, 6 }) do
                for seed = 1, 30 do
                    local clues = randomClues(n, seed * 9973 + n)
                    local so, eo = oldCountSolutions(clues, n, 3, 400000)
                    local sn, en = Board._countSolutions(clues, n, 3, 3000000)
                    if not eo then
                        assert.is_false(en)
                        assert.are.equal(so, sn, ("n=%d seed %d"):format(n, seed))
                    end
                end
            end
        end)

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
