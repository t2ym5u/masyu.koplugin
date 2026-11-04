local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local grid_utils    = lrequire_common("grid_utils")
local Hint       = lrequire_common("hint")
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

-- Every cell of the loop where a circle fits: black at a turn whose two
-- neighbours along the loop are straight (both arms run straight on), white
-- at a straight cell with at least one turning neighbour -- the rule
-- _checkWin() applies. Up to 1.4 white circles went only where BOTH
-- neighbours turn, which left so few clues that barely 1 loop shape in 150
-- had a unique solution at 8x8; with the full rule about 1 in 4 does.
-- Returns the clue grid and how many circles the old, stricter placement
-- would have used (the level digClues() brings it back down to).
local function placeCircles(loop, cell_types, n)
    local total = #loop
    local clues = emptyGrid(n, n, CELL_EMPTY)
    local strict = 0

    for i = 1, total do
        local prev_i = (i - 2) % total + 1
        local next_i = i % total + 1
        local r, c   = loop[i][1], loop[i][2]

        if cell_types[i] == "turn" then
            if cell_types[prev_i] == "straight" and cell_types[next_i] == "straight" then
                clues[r][c] = CELL_BLACK
                strict = strict + 1
            end
        else
            local pt, nt = cell_types[prev_i] == "turn", cell_types[next_i] == "turn"
            if pt or nt then
                clues[r][c] = CELL_WHITE
                if pt and nt then strict = strict + 1 end
            end
        end
    end

    return clues, strict
end

-- ---------------------------------------------------------------------------
-- Uniqueness counter. The win-check (_checkWin above) is genuinely rule-
-- based, not a literal comparison to the stored loop: every marked cell has
-- exactly 2 marked 4-neighbors; the marked cells form a single loop; every
-- black-clue cell is marked, is a turn, and both arms extend straight for
-- one more cell; every white-clue cell is marked, is straight, and at least
-- one arm leads to a turn cell. Uniqueness means: is there only one marked-
-- cell assignment satisfying all of that, given the clue placement?
--
-- 1.5.0: the circles' rules are propagated as cells get decided (a black
-- circle's arm on the loop forces the cell beyond it on and its sides off,
-- a white circle's orientation fixes all four neighbours, and so on), a
-- finished loop that leaves marked cells out is cut at once, and the
-- search grows the loop from a marked cell still missing a neighbour. The
-- old counter only checked the circles once every cell was decided: an 8x8
-- shape took ~0.1-1 s, so generation ran into its 2 s CPU-time cap and
-- shipped an unproven puzzle 9 times in 10 on a desktop -- and on a slower
-- device a different one. Same counts, checked against it on random clue
-- sets.
-- ---------------------------------------------------------------------------

local function countSolutions(clues, n, limit, node_budget)
    local N = n * n
    -- Cell i = (r - 1) * n + c; 0 stands for "off the board" (never marked).
    local up, down, left, right = {}, {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            up[i]    = r > 1 and i - n or 0
            down[i]  = r < n and i + n or 0
            left[i]  = c > 1 and i - 1 or 0
            right[i] = c < n and i + 1 or 0
        end
    end
    up[0], down[0], left[0], right[0] = 0, 0, 0, 0
    local nbrs = {}
    for i = 1, N do nbrs[i] = { up[i], down[i], left[i], right[i] } end

    local val = { [0] = false }
    local blacks, whites = {}, {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            if clues[r][c] == CELL_BLACK then blacks[#blacks + 1] = i
            elseif clues[r][c] == CELL_WHITE then whites[#whites + 1] = i end
        end
    end
    local trail, top = {}, 0
    local function set(i, v)
        local cur = val[i]
        if cur ~= nil then return cur == v end
        val[i] = v
        top = top + 1
        trail[top] = i
        return true
    end
    local function undoTo(mark)
        while top > mark do
            val[trail[top]] = nil
            trail[top] = nil
            top = top - 1
        end
    end
    for _, i in ipairs(blacks) do set(i, true) end
    for _, i in ipairs(whites) do set(i, true) end
    local base = top

    local changed
    local function force(i, v)
        if val[i] == nil then
            if i == 0 then return v == false end
            changed = true
            return set(i, v)
        end
        return val[i] == v
    end

    -- arm of a black circle: x = b + d, y = b + 2d, p1/p2 = x's sides
    local function blackArm(x, y, p1, p2)
        if x == 0 then return true end
        if val[x] == true then
            if y == 0 then return false end
            if not force(y, true) or not force(p1, false) or not force(p2, false) then return false end
        elseif val[x] == nil then
            if val[y] == false or val[p1] == true or val[p2] == true then
                if not force(x, false) then return false end
            end
        end
        return true
    end
    local function exactlyOne(a, b)
        local va, vb = val[a], val[b]
        if va == true then return force(b, false) end
        if va == false then return force(b, true) end
        if vb == true then return force(a, false) end
        if vb == false then return force(a, true) end
        return true
    end

    local function propagate()
        changed = true
        while changed do
            changed = false
            for i = 1, N do
                if val[i] == true then
                    local m, u = 0, 0
                    local nb = nbrs[i]
                    for t = 1, 4 do
                        local v = val[nb[t]]
                        if v == true then m = m + 1 elseif v == nil then u = u + 1 end
                    end
                    if m > 2 or m + u < 2 then return false end
                    if u > 0 and (m == 2 or m + u == 2) then
                        local to = m < 2
                        for t = 1, 4 do
                            local j = nb[t]
                            if val[j] == nil then
                                if not force(j, to) then return false end
                            end
                        end
                    end
                end
            end
            for _, b in ipairs(blacks) do
                if not exactlyOne(up[b], down[b]) or not exactlyOne(left[b], right[b]) then return false end
                local u, d, l, r = up[b], down[b], left[b], right[b]
                if not blackArm(u, up[u], left[u], right[u]) then return false end
                if not blackArm(d, down[d], left[d], right[d]) then return false end
                if not blackArm(l, left[l], up[l], down[l]) then return false end
                if not blackArm(r, right[r], up[r], down[r]) then return false end
            end
            for _, w in ipairs(whites) do
                local u, d, l, r = up[w], down[w], left[w], right[w]
                local vert
                if val[u] == true or val[d] == true or val[l] == false or val[r] == false then vert = true
                elseif val[l] == true or val[r] == true or val[u] == false or val[d] == false then vert = false end
                if vert ~= nil then
                    local a1, a2, o1, o2 = u, d, l, r
                    if not vert then a1, a2, o1, o2 = l, r, u, d end
                    if not force(a1, true) or not force(a2, true)
                            or not force(o1, false) or not force(o2, false) then
                        return false
                    end
                    -- one arm must turn: its cell beyond can't be on the loop
                    local b1 = vert and up[a1] or left[a1]
                    local b2 = vert and down[a2] or right[a2]
                    if val[b1] == true then
                        if not force(b2, false) then return false end
                    elseif val[b2] == true then
                        if not force(b1, false) then return false end
                    end
                end
            end
        end
        return true
    end

    -- A run of marked cells each with exactly two marked neighbours and no
    -- undecided ones that closes on itself is a finished loop: fine only if
    -- it holds every marked cell (the rest must then stay unmarked).
    local seen, stamp = {}, 0
    local function closesEarly()
        local marked = 0
        for i = 1, N do
            if val[i] == true then marked = marked + 1 end
        end
        stamp = stamp + 1
        for s = 1, N do
            if val[s] == true and seen[s] ~= stamp then
                local len, prev, cur, closed = 0, 0, s, false
                while true do
                    seen[cur] = stamp
                    len = len + 1
                    local nb, nxt, m = nbrs[cur], nil, 0
                    local open = false
                    for t = 1, 4 do
                        local v = val[nb[t]]
                        if v == nil then open = true
                        elseif v == true then
                            m = m + 1
                            if nb[t] ~= prev and not nxt then nxt = nb[t] end
                        end
                    end
                    if open or m ~= 2 then break end
                    if nxt == s and len > 2 then closed = true; break end
                    if not nxt or seen[nxt] == stamp then break end
                    prev, cur = cur, nxt
                end
                if closed and len < marked then return true end
            end
        end
        return false
    end

    local solutions, nodes, exhausted = 0, 0, false
    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        local mark = top
        if not propagate() or closesEarly() then undoTo(mark); return end
        -- Branch next to a marked cell still short of its two neighbours
        -- (fewest undecided first); else on any undecided cell.
        local pick, best = nil, 5
        for i = 1, N do
            if val[i] == true then
                local u, first = 0, nil
                local nb = nbrs[i]
                for t = 1, 4 do
                    if val[nb[t]] == nil then u = u + 1; first = first or nb[t] end
                end
                if u > 0 and u < best then best, pick = u, first end
            end
        end
        if not pick then
            for i = 1, N do
                if val[i] == nil then pick = i; break end
            end
        end
        if not pick then
            -- All decided: propagation has checked degrees and circles;
            -- one loop through every marked cell is what is left.
            local marked, s = 0, nil
            for i = 1, N do
                if val[i] then marked = marked + 1; s = s or i end
            end
            if s then
                local len, prev, cur = 0, 0, s
                repeat
                    len = len + 1
                    local nxt
                    local nb = nbrs[cur]
                    for t = 1, 4 do
                        if val[nb[t]] and nb[t] ~= prev then nxt = nb[t]; break end
                    end
                    prev, cur = cur, nxt
                until cur == s or len > marked
                if len == marked then solutions = solutions + 1 end
            end
            undoTo(mark)
            return
        end
        for _, v in ipairs({ true, false }) do
            local m2 = top
            if set(pick, v) then search() end
            undoTo(m2)
            if solutions >= limit or exhausted then break end
        end
        undoTo(mark)
    end
    search()
    undoTo(base)
    return solutions, exhausted
end

-- Node counts, not time, so a seed gives the same puzzle on any device.
-- Measured well under this on every 8x8 shape tried.
local NODE_BUDGET = 200000

-- Loop shapes tried before giving up; ~1 in 4 is unique at 8x8 (~1 in 2
-- at 6x6), so this is never reached in practice.
local MAX_SHAPES = 200

-- A unique clue set from placeCircles() has more circles than the old
-- placement used; take circles away (random order) while the solution stays
-- unique, until back at that level.
local function digClues(clues, n, target, node_budget, on_progress)
    local cells = {}
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if clues[r][c] ~= CELL_EMPTY then
                cells[#cells + 1] = { r, c }
                count = count + 1
            end
        end
    end
    shuffle(cells)
    for i, cell in ipairs(cells) do
        if count <= target then break end
        if on_progress then on_progress(i / #cells) end
        local r, c = cell[1], cell[2]
        local saved = clues[r][c]
        clues[r][c] = CELL_EMPTY
        local solutions, exhausted = countSolutions(clues, n, 2, node_budget)
        if solutions == 1 and not exhausted then
            count = count - 1
        else
            clues[r][c] = saved
        end
    end
    return clues
end

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

-- on_progress (optional): called with a 0..1 fraction as it goes.
function MasyuBoard:generate(on_progress)
    local n = self.n
    local loop, clues
    local best_loop, best_clues

    for shape = 1, MAX_SHAPES do
        if on_progress then on_progress(shape / (shape + 3) * 0.5) end
        -- Empirically 0/500 failures at n=6 and n=8 with this cap (avg
        -- ~5-26 attempts needed); the trivial 2x2 loop below is only a
        -- last-resort safety net, never expected to trigger in practice.
        local cand_loop = generateLoop(n, 5000)
            or { {1,1}, {1,2}, {2,2}, {2,1} }
        local cell_types = classifyLoop(cand_loop)
        local candidate_clues, strict = placeCircles(cand_loop, cell_types, n)
        if not best_loop then
            best_loop, best_clues = cand_loop, candidate_clues
        end
        local solutions, exhausted = countSolutions(candidate_clues, n, 2, NODE_BUDGET)
        if solutions == 1 and not exhausted then
            loop  = cand_loop
            clues = digClues(candidate_clues, n, math.max(4, strict), NODE_BUDGET,
                on_progress and function(f) on_progress(0.5 + 0.5 * f) end)
            break
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

-- The loop is stored as an ordered list of cells, but what the player toggles
-- is a plain boolean per cell, so the hint only needs to know which cells the
-- loop passes through. Rebuilt on demand rather than cached: generate()
-- replaces solution_loop wholesale and a stale cache would quietly hint at the
-- previous puzzle.
function MasyuBoard:_loopGrid()
    local g = {}
    for r = 1, self.n do
        g[r] = {}
        for c = 1, self.n do g[r][c] = false end
    end
    for _, cell in ipairs(self.solution_loop or {}) do
        g[cell[1]][cell[2]] = true
    end
    return g
end

-- tapCell only toggles, so the hint needs a way to set a cell outright.
function MasyuBoard:setPathCell(r, c, on)
    if r < 1 or r > self.n or c < 1 or c > self.n then return false end
    self.user_path[r][c] = on and true or false
    self:_checkWin()
    return true
end

Hint.install(MasyuBoard, {
    getUser     = function(b, r, c) return b.user_path[r][c] end,
    getSolution = function(b, r, c) return b:_loopGrid()[r][c] end,
    setCell     = function(b, r, c, v) return b:setPathCell(r, c, v) end,
    blank       = false,
})

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

-- for the specs
MasyuBoard._countSolutions = countSolutions

return MasyuBoard
