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

local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase        = lrequire_common("screen_base")
local MenuHelper        = lrequire_common("menu_helper")
local MasyuBoard        = lrequire("board")
local MasyuBoardWidget  = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES = MasyuBoard.SIZES

local GAME_RULES_EN = _([[
Masyu — Rules

Draw a single closed loop that passes through every pearl circle.

White pearl: the loop must go straight through the cell, and it must turn in at least one of the two cells immediately adjacent on either side.
Black pearl: the loop must turn 90° in the cell, and it must go straight through both cells immediately adjacent on either side of the turn.

Additional rules:
• The loop cannot branch or cross itself.
• Every pearl must be visited exactly once.

Tap a cell to toggle it as part of the loop. The status bar shows which circles are touched by your path.
]])

local GAME_RULES_FR = [[
Masyu — Règles

Tracez une boucle fermée unique passant par tous les cercles-perles.

Perle blanche : la boucle doit passer en ligne droite à travers la case, et doit tourner dans au moins l'une des deux cases immédiatement adjacentes de part et d'autre.
Perle noire : la boucle doit tourner à 90° dans la case, et doit passer en ligne droite dans les deux cases immédiatement adjacentes de part et d'autre du virage.

Règles supplémentaires :
• La boucle ne peut pas se ramifier ni se croiser.
• Chaque perle doit être visitée exactement une fois.

Appuyez sur une case pour l'ajouter ou la retirer de la boucle. La barre de statut montre les cercles touchés par votre tracé.
]]

local MasyuScreen = ScreenBase:extend{}

function MasyuScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", MasyuBoard.DEFAULT_N)
    self.board  = MasyuBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate()
    end
    ScreenBase.init(self)
end

function MasyuScreen:serializeState()
    return self.board:serialize()
end

function MasyuScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Masyu"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:onToggleReveal() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Clear"), callback = function() self:onClear() end },
            { text = _("Hint"),  callback = function() self:onHint() end },
        }),
    }

    -- The widget draws its own thick outer grid line, so the frame stays
    -- borderless: one visible edge around the board, not two.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = MasyuBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c)
            self:onCellAction(r, c)
        end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function MasyuScreen:onCellAction(r, c)
    if self.board:isShowingSolution() then return end
    self.board:tapCell(r, c)
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    if self.board.won then
        self:updateStatus(_("Congratulations! Puzzle solved!"))
    else
        self:updateStatus()
    end
end

function MasyuScreen:onNewGame()
    local n = self.plugin:getSetting("grid_n", MasyuBoard.DEFAULT_N)
    self.board = MasyuBoard:new{ n = n }
    self.board:generate()
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function MasyuScreen:onClear()
    if self.board:isShowingSolution() then return end
    self.board:clearAll()
    self.plugin:saveState(self.board:serialize())
    self.board_widget:refresh()
    self:updateStatus()
end

function MasyuScreen:onToggleReveal()
    self.board:toggleReveal()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

function MasyuScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", MasyuBoard.DEFAULT_N),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function MasyuScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution shown.")
    elseif self.board.won then
        status = _("Congratulations! Puzzle solved!")
    else
        local sat, total = self.board:countCirclesSatisfied()
        local path_count = self.board:countUserPath()
        status = self:joinStatus(
            T("%1×%1", self.board.n),
            T(_("Pearls: %1/%2"), sat, total),
            T(_("Path: %1"), path_count))
    end
    ScreenBase.updateStatus(self, status)
    -- Every move, hint, undo and reveal ends here, so the bar follows the board.
    self:refreshActionBar()
end

-- Showing the solution can be hidden again, so only solving it ends the round.
function MasyuScreen:isRoundOver()
    return self.board.won
end

function MasyuScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function MasyuScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

return MasyuScreen
