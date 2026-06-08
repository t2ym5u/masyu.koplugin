local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Size       = require("ui/size")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local gwb            = lrequire_common("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local MasyuBoard = lrequire("board")

local C_BG        = Blitbuffer.COLOR_WHITE
local C_GRID      = Blitbuffer.COLOR_GRAY_6
local C_PATH_BG   = Blitbuffer.COLOR_GRAY_C   -- user-marked path cell
local C_SOL_PATH  = Blitbuffer.COLOR_GRAY_8   -- solution path line color
local C_CIRCLE_W  = Blitbuffer.COLOR_WHITE    -- white circle fill
local C_BORDER    = Blitbuffer.COLOR_BLACK    -- circle border / black circle fill

-- ---------------------------------------------------------------------------
-- MasyuBoardWidget
-- ---------------------------------------------------------------------------

local MasyuBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function MasyuBoardWidget:init()
    local n   = self.board and self.board.n or 6
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function MasyuBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col) end
end

function MasyuBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x=x, y=y, w=self.dimen.w, h=self.dimen.h }

    local n    = self.board.n
    local cell = self.dimen.w / n
    local show = self.board:isShowingSolution()

    -- Background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Draw user path backgrounds
    if not show then
        for r = 1, n do
            for c = 1, n do
                if self.board.user_path[r][c] then
                    local cx = x + math.floor((c-1) * cell)
                    local cy = y + math.floor((r-1) * cell)
                    bb:paintRect(cx, cy, math.ceil(cell), math.ceil(cell), C_PATH_BG)
                end
            end
        end
    end

    -- Draw solution path as connected lines (when revealed)
    if show then
        local loop   = self.board.solution_loop
        local lw_sol = math.max(2, math.floor(cell * 0.18))
        local half   = math.floor(lw_sol / 2)
        for i = 1, #loop do
            local curr = loop[i]
            local next = loop[i % #loop + 1]
            local x1   = x + math.floor((curr[2] - 0.5) * cell)
            local y1   = y + math.floor((curr[1] - 0.5) * cell)
            local x2   = x + math.floor((next[2] - 0.5) * cell)
            local y2   = y + math.floor((next[1] - 0.5) * cell)
            if x1 == x2 then
                -- Vertical segment
                local top = math.min(y1, y2)
                local bot = math.max(y1, y2)
                bb:paintRect(x1 - half, top, lw_sol, bot - top + 1, C_SOL_PATH)
            else
                -- Horizontal segment
                local left  = math.min(x1, x2)
                local right = math.max(x1, x2)
                bb:paintRect(left, y1 - half, right - left + 1, lw_sol, C_SOL_PATH)
            end
        end
    end

    -- Draw solution path connections between adjacent user-marked cells (when not revealed)
    if not show then
        local lw_path = math.max(1, math.floor(cell * 0.12))
        local half_p  = math.floor(lw_path / 2)
        for r = 1, n do
            for c = 1, n do
                if self.board.user_path[r][c] then
                    local cx = x + math.floor((c - 0.5) * cell)
                    local cy = y + math.floor((r - 0.5) * cell)
                    -- Connect to right neighbor
                    if c < n and self.board.user_path[r][c+1] then
                        local nx = x + math.floor((c + 0.5) * cell)
                        bb:paintRect(cx, cy - half_p, nx - cx + 1, lw_path, C_GRID)
                    end
                    -- Connect to bottom neighbor
                    if r < n and self.board.user_path[r+1][c] then
                        local ny = y + math.floor((r + 0.5) * cell)
                        bb:paintRect(cx - half_p, cy, lw_path, ny - cy + 1, C_GRID)
                    end
                end
            end
        end
    end

    -- Grid lines
    local thin  = Size.line.thin  or 1
    local thick = Size.line.thick or 2
    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_BORDER)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_BORDER)
    end

    -- Draw circles (clue cells)
    for r = 1, n do
        for c = 1, n do
            local clue = self.board.clues[r][c]
            if clue ~= MasyuBoard.CELL_EMPTY then
                local cx    = x + math.floor((c - 0.5) * cell)
                local cy    = y + math.floor((r - 0.5) * cell)
                local rad   = math.max(3, math.floor(cell * 0.30))
                local border = math.max(1, math.floor(rad * 0.20))

                if clue == MasyuBoard.CELL_BLACK then
                    -- Filled black circle
                    bb:paintCircle(cx, cy, rad, C_BORDER)
                else
                    -- White circle with black border
                    bb:paintCircle(cx, cy, rad, C_BORDER)
                    bb:paintCircle(cx, cy, rad - border, C_CIRCLE_W)
                end
            end
        end
    end
end

return MasyuBoardWidget
