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
-- Hamiltonian cycle generator (for even n)
-- ---------------------------------------------------------------------------
-- Construction: row 1 left-to-right, then each column n..1 alternating
-- down (rows 2..n) and up (rows n..2).
-- For even n, the last column (c=1) goes up, ending at (2,1).
-- Close: (2,1) -> (1,1). All adjacent. Visits all n*n cells exactly once.
--
-- Example n=6:
--   Row 1:  (1,1)..(1,6)
--   Col 6:  (2,6)..(6,6)  down
--   Col 5:  (6,5)..(2,5)  up
--   Col 4:  (2,4)..(6,4)  down
--   Col 3:  (6,3)..(2,3)  up
--   Col 2:  (2,2)..(6,2)  down
--   Col 1:  (6,1)..(2,1)  up
--   Close:  (2,1) -> (1,1) adjacent ✓

local function buildLoop(n)
    local loop = {}
    -- Row 1 left to right
    for c = 1, n do loop[#loop+1] = {1, c} end
    -- Columns n down to 1, alternating direction
    for c = n, 1, -1 do
        local parity = n - c   -- 0 for c=n (even), 1 for c=n-1 (odd), ...
        if parity % 2 == 0 then
            for r = 2, n do loop[#loop+1] = {r, c} end
        else
            for r = n, 2, -1 do loop[#loop+1] = {r, c} end
        end
    end
    return loop
end

-- Check if positions i and j are consecutive in a cycle of length total.
local function isConsecutive(i, j, total)
    return (i % total + 1 == j) or (j % total + 1 == i)
end

-- Randomly perturb the loop with 2x2 square swaps to add variety.
local function perturbLoop(loop, n, passes)
    passes = passes or 10
    -- Build a fast lookup: loop_pos[r][c] = index in loop
    local loop_pos = {}
    for r = 1, n do loop_pos[r] = {} end
    for i, cell in ipairs(loop) do loop_pos[cell[1]][cell[2]] = i end

    local total = #loop

    for _ = 1, passes * total do
        -- Pick a random 2x2 block top-left corner (r,c) where r<n, c<n
        local r  = math.random(1, n-1)
        local c  = math.random(1, n-1)
        local ia = loop_pos[r][c]
        local ib = loop_pos[r][c+1]
        local ic = loop_pos[r+1][c]
        local id = loop_pos[r+1][c+1]

        -- Require all four indices and two pairs of consecutive positions
        if ia and ib and ic and id
            and isConsecutive(ia, ib, total)
            and isConsecutive(ic, id, total)
        then
            -- Reverse the segment between the two pairs to rewire the loop.
            local i2 = (ia % total + 1 == ib) and ib or ia
            local j1 = (ic % total + 1 == id) and ic or id
            local seg_start = i2 % total + 1
            local seg_end   = j1
            if seg_start <= seg_end then
                local left, right = seg_start, seg_end
                while left < right do
                    loop[left], loop[right] = loop[right], loop[left]
                    loop_pos[loop[left][1]][loop[left][2]]   = left
                    loop_pos[loop[right][1]][loop[right][2]] = right
                    left  = left  + 1
                    right = right - 1
                end
            end
        end
    end
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

    local n_black = math.max(1, math.min(#black_cands, math.floor(target_count / 2)))
    local n_white = math.max(1, math.min(#white_cands, target_count - n_black))

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
    local loop = buildLoop(n)
    perturbLoop(loop, n, 8)

    local cell_types  = classifyLoop(loop)
    local target      = math.max(4, math.floor(n * n * 0.30))
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
