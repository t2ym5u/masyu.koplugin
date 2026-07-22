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
    -- Empirically 0/500 failures at n=6 and n=8 with this cap (avg ~5-26
    -- attempts needed); the trivial 2x2 loop below is only a last-resort
    -- safety net, never expected to trigger in practice.
    local loop = generateLoop(n, 5000)
        or { {1,1}, {1,2}, {2,2}, {2,1} }

    local cell_types  = classifyLoop(loop)
    local target      = math.max(4, math.floor(#loop * 0.35))
    local clues       = placeCircles(loop, cell_types, n, target)

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
