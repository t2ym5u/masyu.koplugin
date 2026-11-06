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
-- Uniqueness counter (since 1.6.0 the generator relies on the no-trial
-- solver below instead; the specs keep this as the independent check that
-- what the solver finishes has exactly one solution). The win-check (_checkWin above) is genuinely rule-
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

-- ---------------------------------------------------------------------------
-- No-trial solver. Decides, cell by cell, whether the loop passes through,
-- using only the deductions a player makes without "assume X and look for a
-- contradiction". The generator only ships a puzzle this solver finishes,
-- which also proves its solution unique (every step is forced).
--
-- Tier 1 (direct rules):
--   * a loop cell has exactly two loop neighbours: once it has two, the
--     others are out; when only two can still be on, both are on;
--   * a cell next to three loop cells, or with fewer than two neighbours
--     left that could be on, is out;
--   * black circle: exactly one of up/down and one of left/right; an arm on
--     the loop runs straight one more cell (its sides out), an arm that
--     cannot do so is out;
--   * white circle: once its direction is known its two neighbours are on,
--     the two across are out, and both arms cannot run straight on.
-- Tier 2 (loop and circle patterns):
--   * no premature loop: a cell that would close a piece of the loop while
--     other loop cells lie outside it is out;
--   * one loop: cells that loop cells cannot reach are out, and a cell every
--     path between two loop cells must cross is on;
--   * circle patterns (edges, corners, circles side by side): each circle
--     has a few ways through it (4 for black, 2 for white); a way is ruled
--     out when it clashes with a decided cell, gives a cell three loop
--     neighbours or a loop cell fewer than two, or leaves a circle within
--     reach no way of its own. What every remaining way agrees on is
--     decided.
-- ---------------------------------------------------------------------------

-- Grid geometry and each circle's ways, per size (built once).
local GEOM = {}
local function geometry(n)
    local g = GEOM[n]
    if g then return g end
    local function idx(r, c)
        if r < 1 or r > n or c < 1 or c > n then return 0 end
        return (r - 1) * n + c
    end
    local up, down, left, right, nbrs = { [0] = 0 }, { [0] = 0 }, { [0] = 0 }, { [0] = 0 }, {}
    local black_ways, white_ways = {}, {}
    for r = 1, n do
        for c = 1, n do
            local i = idx(r, c)
            up[i], down[i], left[i], right[i] = idx(r-1, c), idx(r+1, c), idx(r, c-1), idx(r, c+1)
            nbrs[i] = { up[i], down[i], left[i], right[i] }
            local bw = {}
            for _, dv in ipairs({ -1, 1 }) do
                for _, dh in ipairs({ -1, 1 }) do
                    local a1, a2 = idx(r + dv, c), idx(r + 2*dv, c)
                    local b1, b2 = idx(r, c + dh), idx(r, c + 2*dh)
                    if a2 ~= 0 and b2 ~= 0 then
                        bw[#bw+1] = {
                            on  = { a1, a2, b1, b2 },
                            off = { idx(r - dv, c), idx(r, c - dh), idx(r + dv, c + dh),
                                    idx(r + dv, c - dh), idx(r - dv, c + dh) },
                        }
                    end
                end
            end
            black_ways[i] = bw
            local ww = {}
            local u, d, l, rr = idx(r-1, c), idx(r+1, c), idx(r, c-1), idx(r, c+1)
            if u ~= 0 and d ~= 0 then
                ww[#ww+1] = { on = { u, d }, off = { l, rr }, ends = { idx(r-2, c), idx(r+2, c) } }
            end
            if l ~= 0 and rr ~= 0 then
                ww[#ww+1] = { on = { l, rr }, off = { u, d }, ends = { idx(r, c-2), idx(r, c+2) } }
            end
            white_ways[i] = ww
        end
    end
    -- Each way's cells (on, off, ends) and its zone: those cells plus every
    -- cell within two steps of its loop cells. Two ways whose cells stay out
    -- of each other's zone cannot clash (see wayFits).
    local function prep(w)
        local cells, zone = {}, {}
        for _, list in ipairs({ w.on, w.off, w.ends or {} }) do
            for _, i in ipairs(list) do
                if i ~= 0 then cells[#cells+1] = i; zone[i] = true end
            end
        end
        for _, i in ipairs(w.on) do
            local r, c = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
            for dr = -2, 2 do
                for dc = -2, 2 do
                    if math.abs(dr) + math.abs(dc) <= 2 then
                        local j = idx(r + dr, c + dc)
                        if j ~= 0 then zone[j] = true end
                    end
                end
            end
        end
        w.cells, w.zone = cells, zone
    end
    for i = 1, n * n do
        for _, w in ipairs(black_ways[i]) do prep(w) end
        for _, w in ipairs(white_ways[i]) do prep(w) end
    end
    g = { up = up, down = down, left = left, right = right, nbrs = nbrs,
          black_ways = black_ways, white_ways = white_ways }
    GEOM[n] = g
    return g
end

-- One solver per size, built once: its rules are closures over per-call
-- state reset by each solve, so LuaJIT keeps their traces (new closures on
-- every call made it re-trace them all, about 3x slower).
local function makeSolver(n)
    local N = n * n
    local G = geometry(n)
    local up, down, left, right, nbrs = G.up, G.down, G.left, G.right, G.nbrs

    local val, stats, circles
    local bad = false
    local changed = false
    local function force(i, v)
        local cur = val[i]
        if cur == nil then
            if i == 0 then return v == false end
            val[i] = v
            changed = true
            stats.t1 = stats.t1 + 1
            return true
        end
        if cur ~= v then bad = true; return false end
        return true
    end

    local function setup(clues)
        val = { [0] = false }
        stats = { t1 = 0, t2 = 0, undecided = 0 }
        bad, changed = false, false
        circles = {}
        for r = 1, n do
            for c = 1, n do
                local k = clues[r][c]
                if k == CELL_BLACK or k == CELL_WHITE then
                    local i = (r - 1) * n + c
                    val[i] = true
                    local src = k == CELL_BLACK and G.black_ways[i] or G.white_ways[i]
                    local ways = {}
                    for t = 1, #src do ways[t] = src[t] end
                    circles[#circles+1] = { i = i, r = r, c = c, black = (k == CELL_BLACK), ways = ways }
                end
            end
        end
        for _, a in ipairs(circles) do
            a.near = {}
            for _, b in ipairs(circles) do
                if a ~= b and math.abs(a.r - b.r) <= 4 and math.abs(a.c - b.c) <= 4 then
                    a.near[#a.near+1] = b
                end
            end
        end
    end

    -- Tier 1 ----------------------------------------------------------------
    local function blackArm(x, y, p1, p2)
        if x == 0 then return true end
        if val[x] == true then
            if y == 0 then bad = true; return false end
            return force(y, true) and force(p1, false) and force(p2, false)
        elseif val[x] == nil then
            if val[y] == false or val[p1] == true or val[p2] == true then
                return force(x, false)
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

    local function tier1()
        changed = true
        while changed do
            changed = false
            for i = 1, N do
                local vi = val[i]
                if vi ~= false then
                    local nb = nbrs[i]
                    local m, u = 0, 0
                    for t = 1, 4 do
                        local v = val[nb[t]]
                        if v == true then m = m + 1 elseif v == nil then u = u + 1 end
                    end
                    if vi == true then
                        if m > 2 or m + u < 2 then bad = true; return false end
                        if u > 0 and (m == 2 or m + u == 2) then
                            local to = m < 2
                            for t = 1, 4 do
                                if val[nb[t]] == nil and not force(nb[t], to) then return false end
                            end
                        end
                    elseif m >= 3 or m + u < 2 then
                        force(i, false)
                    end
                end
            end
            for _, cc in ipairs(circles) do
                local b = cc.i
                local u, d, l, r = up[b], down[b], left[b], right[b]
                if cc.black then
                    if not (exactlyOne(u, d) and exactlyOne(l, r)
                            and blackArm(u, up[u], left[u], right[u])
                            and blackArm(d, down[d], left[d], right[d])
                            and blackArm(l, left[l], up[l], down[l])
                            and blackArm(r, right[r], up[r], down[r])) then
                        return false
                    end
                else
                    local vert
                    if val[u] == true or val[d] == true or val[l] == false or val[r] == false then vert = true
                    elseif val[l] == true or val[r] == true or val[u] == false or val[d] == false then vert = false end
                    if vert ~= nil then
                        local a1, a2, o1, o2 = u, d, l, r
                        if not vert then a1, a2, o1, o2 = l, r, u, d end
                        if not (force(a1, true) and force(a2, true) and force(o1, false) and force(o2, false)) then
                            return false
                        end
                        local b1 = vert and up[a1] or left[a1]
                        local b2 = vert and down[a2] or right[a2]
                        if val[b1] == true and not force(b2, false) then return false end
                        if val[b2] == true and not force(b1, false) then return false end
                    end
                end
            end
            if bad then return false end
        end
        return true
    end

    -- Tier 2: loop rules ------------------------------------------------------
    local comp = {}
    local function prematureLoop()
        for i = 1, N do comp[i] = nil end
        local ncomp = 0
        for s = 1, N do
            if val[s] == true and not comp[s] then
                ncomp = ncomp + 1
                local q, h = { s }, 1
                comp[s] = ncomp
                while h <= #q do
                    local x = q[h]; h = h + 1
                    local nb = nbrs[x]
                    for t = 1, 4 do
                        local y = nb[t]
                        if y ~= 0 and val[y] == true and not comp[y] then comp[y] = ncomp; q[#q+1] = y end
                    end
                end
            end
        end
        if ncomp < 2 then return false end
        local progress = false
        for i = 1, N do
            if val[i] == nil then
                local nb = nbrs[i]
                local c1 = nil
                for t = 1, 4 do
                    local y = nb[t]
                    if y ~= 0 and val[y] == true then
                        local c = comp[y]
                        if c == c1 then force(i, false); progress = true; break end
                        c1 = c1 or c
                        -- (a cell has at most 2 loop neighbours here: tier 1
                        -- already put out any with three)
                    end
                end
            end
        end
        return progress
    end

    local seen, queue = {}, {}
    local stamp = 0
    -- Marked cells reachable from `first` through cells that are not out,
    -- never entering `skip`. Leaves seen[x] == stamp for every cell reached.
    local function reach(first, skip)
        stamp = stamp + 1
        seen[first] = stamp
        queue[1] = first
        local h, tail, got = 1, 1, 1
        while h <= tail do
            local x = queue[h]; h = h + 1
            local nb = nbrs[x]
            for t = 1, 4 do
                local y = nb[t]
                if y ~= 0 and y ~= skip and seen[y] ~= stamp and val[y] ~= false then
                    seen[y] = stamp
                    tail = tail + 1
                    queue[tail] = y
                    if val[y] == true then got = got + 1 end
                end
            end
        end
        return got
    end
    local function unreachable()
        local first, total = nil, 0
        for i = 1, N do if val[i] == true then first = first or i; total = total + 1 end end
        if not first then return false end
        if reach(first, nil) < total then bad = true; return false end
        local progress = false
        for i = 1, N do
            if val[i] == nil and seen[i] ~= stamp then force(i, false); progress = true end
        end
        return progress
    end
    local function bottleneck()
        local first, total = nil, 0
        for i = 1, N do if val[i] == true then first = first or i; total = total + 1 end end
        if not first then return false end
        for i = 1, N do
            if val[i] == nil and reach(first, i) < total then
                force(i, true)
                return true
            end
        end
        return false
    end

    -- Tier 2: circle patterns -------------------------------------------------
    -- tmp holds what the ways being tried put on top of val; undo stack below.
    local tmp, ustack, utop = {}, {}, 0
    local function get(i)
        local t = tmp[i]
        if t ~= nil then return t end
        return val[i]
    end
    local function put(i, v)
        local cur = get(i)
        if cur == nil then
            if i == 0 then return v == false end
            tmp[i] = v
            utop = utop + 1
            ustack[utop] = i
            return true
        end
        return cur == v
    end
    local function rollback(mark)
        while utop > mark do
            tmp[ustack[utop]] = nil
            utop = utop - 1
        end
    end
    local function cellOk(i)
        if i == 0 or get(i) ~= true then return true end
        local nb = nbrs[i]
        local m, p = 0, 0
        for t = 1, 4 do
            local v = get(nb[t])
            if v == true then m = m + 1; p = p + 1 elseif v == nil then p = p + 1 end
        end
        return m <= 2 and p >= 2
    end
    -- Put a way on top of tmp; false if it clashes.
    local function apply(w)
        local on, off = w.on, w.off
        for t = 1, #on do if not put(on[t], true) then return false end end
        for t = 1, #off do if not put(off[t], false) then return false end end
        local e = w.ends
        if e and get(e[1]) == true and get(e[2]) == true then return false end
        for t = 1, #on do
            local i = on[t]
            if not cellOk(i) then return false end
            local nb = nbrs[i]
            for s = 1, 4 do if not cellOk(nb[s]) then return false end end
        end
        return true
    end
    local function touches(w, w2)
        local zone = w.zone
        for _, i in ipairs(w2.cells) do if zone[i] then return true end end
        zone = w2.zone
        for _, i in ipairs(w.cells) do if zone[i] then return true end end
        return false
    end
    -- alone[w]: the way fits the decided cells on its own.
    local alone = {}
    local function wayFits(cc, w)
        if not alone[w] then return false end
        for _, o in ipairs(cc.near) do
            if not o.done then
                local any = false
                for _, w2 in ipairs(o.ways) do
                    if alone[w2] then
                        if not touches(w, w2) then any = true; break end
                        local ok2 = apply(w) and apply(w2) and apply(w)  -- re-check w with w2 on top
                        rollback(0)
                        if ok2 then any = true; break end
                    end
                end
                if not any then return false end
            end
        end
        return true
    end
    local function patterns()
        local progress = false
        for _, cc in ipairs(circles) do
            if not cc.done then
                for _, w in ipairs(cc.ways) do
                    alone[w] = apply(w)
                    rollback(0)
                end
            end
        end
        for _, cc in ipairs(circles) do
          if not cc.done then
            local keep = {}
            for _, w in ipairs(cc.ways) do
                if wayFits(cc, w) then keep[#keep+1] = w end
            end
            if #keep == 0 then bad = true; return false end
            if #keep < #cc.ways then cc.ways = keep; progress = true end
            -- what every remaining way agrees on
            local first = keep[1]
            for _, list in ipairs({ first.on, first.off }) do
                local to = list == first.on
                for _, i in ipairs(list) do
                    if i ~= 0 and val[i] == nil then
                        local all = true
                        for t = 2, #keep do
                            local found = false
                            for _, j in ipairs(to and keep[t].on or keep[t].off) do
                                if j == i then found = true; break end
                            end
                            if not found then all = false; break end
                        end
                        if all then force(i, to); progress = true end
                    end
                end
            end
            if bad then return false end
            if #keep == 1 then
                -- settled once all its cells are decided
                local all = true
                for _, i in ipairs(first.on) do if val[i] == nil then all = false end end
                for _, i in ipairs(first.off) do if i ~= 0 and val[i] == nil then all = false end end
                cc.done = all
            end
          end
        end
        return progress
    end

    local rules = { prematureLoop, unreachable, patterns, bottleneck }
    return function(clues)
        setup(clues)
        while true do
            if not tier1() then return false, val, stats end
            local more = false
            for _, rule in ipairs(rules) do
                more = rule()
                if bad then rollback(0); return false, val, stats end
                if more then break end
            end
            if not more then break end
            stats.t2 = stats.t2 + 1
        end
        for i = 1, N do if val[i] == nil then stats.undecided = stats.undecided + 1 end end
        return stats.undecided == 0, val, stats
    end
end

local SOLVERS = {}
-- Interpreted, this solver is faster than compiled: its many short branchy
-- loops make LuaJIT record and throw away traces on every new puzzle
-- (measured 1.5x slower over a whole generation with the JIT on).
if jit then jit.off(makeSolver, true) end
-- Returns solved (bool), val (cell index -> bool, i = (r-1)*n + c), stats
-- { t1 = cells decided by tier-1 rules, t2 = tier-2 deductions needed,
--   undecided = cells left }.
local function logicSolve(clues, n)
    local solve = SOLVERS[n]
    if not solve then
        solve = makeSolver(n)
        SOLVERS[n] = solve
    end
    return solve(clues)
end

-- Does the no-trial solver finish these clues, on exactly this loop?
local function solvesTo(clues, n, on_loop)
    local ok, val = logicSolve(clues, n)
    if not ok then return false end
    for i = 1, n * n do
        if val[i] ~= (on_loop[i] or false) then return false end
    end
    return true
end

-- Loop shapes tried before falling back to a stored puzzle. With every
-- circle the full placement allows, about 3 shapes in 4 are solved without
-- guessing at 8x8 (nearly all at 6x6), so this is never reached in practice.
local MAX_SHAPES = 60

-- Take circles away (random order) while the no-trial solver still finishes
-- the puzzle, until down to `target` (the old, sparser placement's count).
local function digClues(clues, n, target, on_loop, on_progress)
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
        if solvesTo(clues, n, on_loop) then
            count = count - 1
        else
            clues[r][c] = saved
        end
    end
    return clues
end

-- Last-resort puzzles, one per size, checked by the specs (solved by the
-- no-trial solver, unique). Only used if MAX_SHAPES shapes all fail.
-- Rows: '.' empty, 'W' white, 'B' black; loop as {r, c} in order.
local FALLBACK = {
    [6] = {
        n = 6,
        rows = { "..B...", "..W..W", ".....W", "......", "......", "..BW.." },
        loop = { {6,4}, {6,3}, {5,3}, {4,3}, {3,3}, {2,3}, {1,3}, {1,4}, {1,5}, {1,6},
                 {2,6}, {3,6}, {4,6}, {4,5}, {5,5}, {6,5} },
    },
    [8] = {
        n = 8,
        rows = { "BWB.....", "W.W.....", "..W.....", "..B.B...", "....W...", "B.B..W..",
                 "..W.....", "..BW..W." },
        loop = { {2,1}, {3,1}, {4,1}, {5,1}, {6,1}, {6,2}, {6,3}, {7,3}, {8,3}, {8,4},
                 {8,5}, {8,6}, {8,7}, {8,8}, {7,8}, {6,8}, {6,7}, {6,6}, {6,5}, {5,5},
                 {4,5}, {4,4}, {4,3}, {3,3}, {2,3}, {1,3}, {1,2}, {1,1} },
    },
}

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

    for shape = 1, MAX_SHAPES do
        if on_progress then on_progress(shape / (shape + 3) * 0.5) end
        local cand_loop = generateLoop(n, 5000)
        if cand_loop then
            local on_loop = {}
            for _, cell in ipairs(cand_loop) do on_loop[(cell[1] - 1) * n + cell[2]] = true end
            local cell_types = classifyLoop(cand_loop)
            local candidate_clues, strict = placeCircles(cand_loop, cell_types, n)
            if solvesTo(candidate_clues, n, on_loop) then
                loop  = cand_loop
                clues = digClues(candidate_clues, n, math.max(4, strict), on_loop,
                    on_progress and function(f) on_progress(0.5 + 0.5 * f) end)
                break
            end
        end
    end
    if not loop then
        local fb = FALLBACK[n] or FALLBACK[DEFAULT_N]
        n = fb.n
        self.n = n
        loop = {}
        for i, cell in ipairs(fb.loop) do loop[i] = { cell[1], cell[2] } end
        clues = emptyGrid(n, n, CELL_EMPTY)
        for r = 1, n do
            for c = 1, n do
                local ch = fb.rows[r]:sub(c, c)
                clues[r][c] = ch == "W" and CELL_WHITE or ch == "B" and CELL_BLACK or CELL_EMPTY
            end
        end
    end

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
MasyuBoard._logicSolve     = logicSolve
MasyuBoard._FALLBACK       = FALLBACK

return MasyuBoard
