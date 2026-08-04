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

local ButtonTable     = require("ui/widget/buttontable")
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
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = MasyuBoardWidget:new{
        board        = self.board,
        onCellAction = function(r, c)
            self:onCellAction(r, c)
        end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    self.status_text:setMaxWidth(is_landscape and button_width or board_frame_size)

    local title_bar = self:buildTitleBar(_("Masyu"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:onToggleReveal() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("Clear"), callback = function() self:onClear() end },
            },
        },
    }

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        local content = HorizontalGroup:new{
            align  = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        local content = VerticalGroup:new{
            align = "center",
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self:buildPortraitLayout(title_bar, content, bottom_buttons)
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
        title     = _("Select grid size"),
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
        status = T(_("Circles on path: %1/%2  \xC2\xB7  Path cells: %3"),
            sat, total, path_count)
    end
    ScreenBase.updateStatus(self, status)
end

function MasyuScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function MasyuScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide") or _("Show")
end

return MasyuScreen
