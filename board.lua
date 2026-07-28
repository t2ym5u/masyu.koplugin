local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils    = lrequire_common("grid_utils")
local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local CELL_EMPTY = 0
local CELL_WHITE = 1   -- white circle clue
local CELL_BLACK = 2   -- black circle clue

local DEFAULT_N = 6
local SIZES     = { 6, 8 }

-- ---------------------------------------------------------------------------
-- Sparse chordless-loop generator
-- ---------------------------------------------------------------------------
-- _checkWin() (below) validates a solution purely from which grid cells are
-- marked: a marked cell is valid loop-membership only if it has *exactly*
-- two marked grid-neighbours (its loop-predecessor and loop-successor). That
-- degree check is only sound if the generated loop is an INDUCED (chordless)
-- cycle in the grid graph -- i.e. no two loop cells that are non-consecutive
-- in the loop are ever grid-adjacent. A full-coverage Hamiltonian loop can
-- never satisfy this (every interior cell's grid-neighbours are almost all
-- also on the loop), so the generator below grows a genuinely sparse loop
-- (roughly 40-75% of the grid, like classic Masyu) and enforces
-- chordlessness at every growth step, so any correctly-marked solution is
-- guaranteed winnable.

local DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1} }

local function manhattan(a, b)
    return math.abs(a[1] - b[1]) + math.abs(a[2] - b[2])
end

-- Count in_path grid-neighbours of (r,c), optionally ignoring up to two cells.
local function pathNeighborCount(in_path, n, r, c, ignore1, ignore2)
    local count = 0
    for _, d in ipairs(DIRS) do
        local nr, nc = r + d[1], c + d[2]
        if nr >= 1 and nr <= n and nc >= 1 and nc <= n and in_path[nr][nc] then
            local skip = (ignore1 and nr == ignore1[1] and nc == ignore1[2])
                       or (ignore2 and nr == ignore2[1] and nc == ignore2[2])
            if not skip then count = count + 1 end
        end
    end
    return count
end

-- Grow one random chordless loop. Returns the ordered cell list, or nil if
-- this attempt dead-ended or ran past max_len before it could close.
local function tryGrowLoop(n, min_len, max_len)
    local in_path = {}
    for r = 1, n do in_path[r] = {} end

    local start = { math.random(1, n), math.random(1, n) }
    local path  = { start }
    in_path[start[1]][start[2]] = true

    while true do
        local cur = path[#path]
        if #path >= max_len then return nil end

        if #path == 1 then
            -- First step out of `start`: every neighbour is a plain move --
            -- "adjacent to start" is meaningless when cur IS start.
            local opts = {}
            for _, d in ipairs(DIRS) do
                local nr, nc = cur[1] + d[1], cur[2] + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                    opts[#opts+1] = { nr, nc }
                end
            end
            if #opts == 0 then return nil end
            local nb = opts[math.random(#opts)]
            path[2] = nb
            in_path[nb[1]][nb[2]] = true
        else
            -- Adjacency to `start` is reserved for the closing move only --
            -- a normal pass-through cell adjacent to start would be a chord.
            local extend, close = {}, {}
            for _, d in ipairs(DIRS) do
                local nr, nc = cur[1] + d[1], cur[2] + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not in_path[nr][nc] then
                    if manhattan({nr, nc}, start) == 1 then
                        if #path + 1 >= min_len
                            and pathNeighborCount(in_path, n, nr, nc, cur, start) == 0 then
                            close[#close+1] = { nr, nc }
                        end
                    elseif pathNeighborCount(in_path, n, nr, nc, cur) == 0 then
                        extend[#extend+1] = { nr, nc }
                    end
                end
            end

            if #close > 0 then
                path[#path+1] = close[math.random(#close)]
                return path
            end
            if #extend == 0 then return nil end
            local nb = extend[math.random(#extend)]
            path[#path+1] = nb
            in_path[nb[1]][nb[2]] = true
        end
    end
end

local function generateLoop(n, max_attempts)
    for _ = 1, max_attempts do
        local min_len = math.floor(n * n * (0.40 + math.random() * 0.25))
        local max_len = math.floor(n * n * 0.75)
        local loop = tryGrowLoop(n, min_len, max_len)
        if loop then return loop end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Circle placement
-- ---------------------------------------------------------------------------

-- Classify each loop cell as "turn" or "straight" based on its neighbors in the loop.
local function classifyLoop(loop)
    local total = #loop
    local types = {}
    for i = 1, total do
        local prev = loop[(i - 2) % total + 1]
        local curr = loop[i]
        local next = loop[i % total + 1]
        local dr1  = curr[1] - prev[1]
        local dc1  = curr[2] - prev[2]
        local dr2  = next[1] - curr[1]
        local dc2  = next[2] - curr[2]
        types[i]   = (dr1 == dr2 and dc1 == dc2) and "straight" or "turn"
    end
    return types
end

-- Place clues: black circles at turns (where prev/next are straight),
-- white circles at straight cells (where prev/next are turns).
local function placeCircles(loop, cell_types, n, target_count)
    local total = #loop
    local clues = emptyGrid(n, n, CELL_EMPTY)

    -- Build index: loop position to grid index
    local black_cands = {}
    local white_cands = {}

    for i = 1, total do
        local prev_i = (i - 2) % total + 1
        local next_i = i % total + 1
        local r, c   = loop[i][1], loop[i][2]

        if cell_types[i] == "turn" then
            -- Black circle candidate: segments before and after must be straight
            if cell_types[prev_i] == "straight" and cell_types[next_i] == "straight" then
                black_cands[#black_cands+1] = {r, c}
            end
        else
            -- White circle candidate: segments before and after must turn
            if cell_types[prev_i] == "turn" and cell_types[next_i] == "turn" then
                white_cands[#white_cands+1] = {r, c}
            end
        end
    end

    shuffle(black_cands)
    shuffle(white_cands)

    -- Clamp to available candidates first, then try to reach at least 1 of
    -- each type -- forcing a floor of 1 *before* clamping (the previous
    -- order) indexed past the end of an empty candidate list when a loop
    -- shape happened to produce zero turn-cells or zero straight-cells.
    local n_black = math.min(#black_cands, math.max(1, math.floor(target_count / 2)))
    local n_white = math.min(#white_cands, math.max(1, target_count - n_black))

    for i = 1, n_black do
        clues[black_cands[i][1]][black_cands[i][2]] = CELL_BLACK
    end
    for i = 1, n_white do
        local r, c = white_cands[i][1], white_cands[i][2]
        if clues[r][c] == CELL_EMPTY then
            clues[r][c] = CELL_WHITE
        end
    end

    return clues
end

-- ---------------------------------------------------------------------------
-- Uniqueness counter. The win-check (_checkWin above) is genuinely rule-
-- based, not a literal comparison to the stored loop -- and notably does
-- NOT require a single connected loop, only: every marked cell has
-- exactly 2 marked 4-neighbors; every black-clue cell is marked, is a
-- turn, and both arms extend straight for one more cell; every white-clue
-- cell is marked, is straight, and at least one arm leads to a turn cell.
-- Uniqueness means: is there only one marked-cell assignment satisfying
-- all of that, given the clue placement? Backtracking over cells (clue
-- cells forced marked from the start), with the degree-2 rule propagated
-- incrementally; full clue verification (turn/straight/arm-to-turn) is
-- only checked once every cell is decided, mirroring slitherlink's
-- final-only loop check.
-- ---------------------------------------------------------------------------

local function countSolutions(clues, n, limit, node_budget)
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

local function uniquenessNodeBudget(n)
    if n <= 6 then return 60000 end
    return 100000
end

-- Unlike lightup/tapa/slitherlink, sparser reveal ratios essentially never
-- prove unique here (measured: full reveal -- every valid black/white
-- candidate on the loop -- only succeeds ~10% of the time per loop shape,
-- and any ratio below that is strictly worse), so there's no useful
-- escalation ladder: always reveal every candidate and instead retry with
-- a fresh loop shape.
local REVEAL_LEVELS = { 100.0 }

-- ---------------------------------------------------------------------------
-- MasyuBoard
-- ---------------------------------------------------------------------------

local MasyuBoard = {}
MasyuBoard.__index = MasyuBoard

MasyuBoard.CELL_EMPTY = CELL_EMPTY
MasyuBoard.CELL_WHITE = CELL_WHITE
MasyuBoard.CELL_BLACK = CELL_BLACK
MasyuBoard.DEFAULT_N  = DEFAULT_N
MasyuBoard.SIZES      = SIZES

function MasyuBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    return setmetatable({
        n               = n,
        clues           = emptyGrid(n, n, CELL_EMPTY),
        solution_loop   = {},
        user_path       = emptyBoolGrid(n),
        reveal_solution = false,
        won             = false,
    }, self)
end

function MasyuBoard:generate()
    local n = self.n
    -- n=8 verification is inherently slow (proving a shape UNIQUE requires
    -- exhausting its whole remaining search space, and that only succeeds
    -- for a minority of generated loop shapes, regardless of node budget --
    -- measured no material quality gain from 20000 up through 400000, just
    -- longer waits) -- keep the per-attempt budget modest so several loop
    -- shapes fit in the wall-clock cap below rather than one deep search.
    local node_budget = n <= 6 and 300000 or 60000
    local time_budget = n <= 6 and nil or 2.0
    local start_clock = os.clock()

    local loop, clues
    local best_loop, best_clues

    for _ = 1, 40 do
        if loop then break end
        if time_budget and os.clock() - start_clock > time_budget then break end
        -- Empirically 0/500 failures at n=6 and n=8 with this cap (avg
        -- ~5-26 attempts needed); the trivial 2x2 loop below is only a
        -- last-resort safety net, never expected to trigger in practice.
        local cand_loop = generateLoop(n, 5000)
            or { {1,1}, {1,2}, {2,2}, {2,1} }
        local cell_types = classifyLoop(cand_loop)
        local target     = math.max(4, math.floor(#cand_loop * 0.35))

        for _, mult in ipairs(REVEAL_LEVELS) do
            if loop then break end
            local target_count = math.floor(target * mult)
            local candidate_clues = placeCircles(cand_loop, cell_types, n, target_count)
            if not best_loop then
                best_loop, best_clues = cand_loop, candidate_clues
            end
            local solutions, exhausted = countSolutions(candidate_clues, n, 2, node_budget)
            if solutions == 1 and not exhausted then
                loop, clues = cand_loop, candidate_clues
            end
        end
    end
    if not loop then loop, clues = best_loop, best_clues end

    self.solution_loop   = loop
    self.clues           = clues
    self.user_path       = emptyBoolGrid(n)
    self.reveal_solution = false
    self.won             = false
end

-- Toggle a cell in the user path.
function MasyuBoard:tapCell(r, c)
    if r < 1 or r > self.n or c < 1 or c > self.n then return end
    self.user_path[r][c] = not self.user_path[r][c]
    self:_checkWin()
end

function MasyuBoard:clearAll()
    self.user_path = emptyBoolGrid(self.n)
    self.won = false
end

function MasyuBoard:toggleReveal()
    self.reveal_solution = not self.reveal_solution
end

function MasyuBoard:isShowingSolution()
    return self.reveal_solution
end

function MasyuBoard:_checkWin()
    local n = self.n
    local up = self.user_path
    local dirs = {{-1,0},{1,0},{0,-1},{0,1}}

    -- Count marked cells and precompute marked-neighbor count per cell
    local marked = 0
    local nb = {}
    for r = 1, n do
        nb[r] = {}
        for c = 1, n do
            nb[r][c] = 0
            if up[r][c] then marked = marked + 1 end
        end
    end
    if marked < 4 then self.won = false; return end

    for r = 1, n do
        for c = 1, n do
            if up[r][c] then
                for _, d in ipairs(dirs) do
                    local nr, nc = r + d[1], c + d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n and up[nr][nc] then
                        nb[r][c] = nb[r][c] + 1
                    end
                end
                -- Valid closed loop: every marked cell has exactly 2 marked neighbours
                if nb[r][c] ~= 2 then self.won = false; return end
            end
        end
    end

    -- The above only guarantees a union of simple cycles. Masyu requires a
    -- SINGLE loop: trace from any marked cell, always stepping to the
    -- marked neighbour that isn't where we came from, and confirm every
    -- marked cell gets visited exactly once before returning to start.
    -- Without this, a disjoint, clue-unconstrained loop dropped anywhere
    -- else on the grid would also "win" -- which let almost every
    -- generated puzzle be satisfied by more than one path.
    do
        local start_r, start_c
        for r = 1, n do
            for c = 1, n do
                if up[r][c] then start_r, start_c = r, c; break end
            end
            if start_r then break end
        end
        local visited = 0
        local cur_r, cur_c = start_r, start_c
        local prev_r, prev_c = nil, nil
        repeat
            visited = visited + 1
            local next_r, next_c
            for _, d in ipairs(dirs) do
                local nr, nc = cur_r + d[1], cur_c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and up[nr][nc]
                    and not (nr == prev_r and nc == prev_c) then
                    next_r, next_c = nr, nc
                    break
                end
            end
            if not next_r then self.won = false; return end
            prev_r, prev_c = cur_r, cur_c
            cur_r, cur_c = next_r, next_c
        until cur_r == start_r and cur_c == start_c
        if visited ~= marked then self.won = false; return end
    end

    -- Returns the two direction vectors toward marked neighbours of (r,c)
    local function arms(r, c)
        local a = {}
        for _, d in ipairs(dirs) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and up[nr][nc] then
                a[#a+1] = d
            end
        end
        return a
    end

    -- true if cell makes a 90° turn (the two arm directions are not collinear)
    local function isTurn(r, c)
        local a = arms(r, c)
        return #a == 2 and not (a[1][1] == -a[2][1] and a[1][2] == -a[2][2])
    end

    local function isStraight(r, c)
        local a = arms(r, c)
        return #a == 2 and a[1][1] == -a[2][1] and a[1][2] == -a[2][2]
    end

    -- Check pearl constraints
    for r = 1, n do
        for c = 1, n do
            local clue = self.clues[r][c]
            if clue == CELL_BLACK then
                -- Black: path passes through, turns here, both arms extend straight ≥1 cell
                if not up[r][c] or not isTurn(r, c) then self.won = false; return end
                for _, d in ipairs(arms(r, c)) do
                    if not isStraight(r + d[1], c + d[2]) then self.won = false; return end
                end
            elseif clue == CELL_WHITE then
                -- White: path passes through straight, at least one adjacent cell turns
                if not up[r][c] or not isStraight(r, c) then self.won = false; return end
                local has_turn = false
                for _, d in ipairs(arms(r, c)) do
                    if isTurn(r + d[1], c + d[2]) then has_turn = true; break end
                end
                if not has_turn then self.won = false; return end
            end
        end
    end

    self.won = true
end

-- Returns satisfied, total circle counts.
function MasyuBoard:countCirclesSatisfied()
    local n = self.n
    local total, satisfied = 0, 0
    for r = 1, n do
        for c = 1, n do
            if self.clues[r][c] ~= CELL_EMPTY then
                total = total + 1
                if self.user_path[r][c] then satisfied = satisfied + 1 end
            end
        end
    end
    return satisfied, total
end

function MasyuBoard:countUserPath()
    local n = self.n
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if self.user_path[r][c] then count = count + 1 end
        end
    end
    return count
end

function MasyuBoard:serialize()
    local n = self.n
    local sol = {}
    for i, cell in ipairs(self.solution_loop) do
        sol[i] = {cell[1], cell[2]}
    end
    local up = {}
    for r = 1, n do
        up[r] = {}
        for c = 1, n do up[r][c] = self.user_path[r][c] and true or false end
    end
    return {
        n               = n,
        clues           = copyGrid(self.clues, n),
        solution_loop   = sol,
        user_path       = up,
        reveal_solution = self.reveal_solution,
        won             = self.won,
    }
end

function MasyuBoard:load(data)
    if type(data) ~= "table" or not data.clues then return false end
    local n = data.n or DEFAULT_N
    self.n     = n
    self.clues = copyGrid(data.clues or {}, n)

    self.solution_loop = {}
    if data.solution_loop then
        for i, cell in ipairs(data.solution_loop) do
            self.solution_loop[i] = {cell[1], cell[2]}
        end
    end

    self.user_path = emptyBoolGrid(n)
    if data.user_path then
        for r = 1, n do
            for c = 1, n do
                local v = data.user_path[r] and data.user_path[r][c]
                self.user_path[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal_solution = data.reveal_solution or false
    self.won             = data.won or false
    return true
end

return MasyuBoard
