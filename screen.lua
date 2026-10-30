local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase        = require("screen_base")
local MenuHelper        = require("menu_helper")
local MosaicBoard       = lrequire("board")
local MosaicBoardWidget = lrequire("board_widget")
local GenProgress       = lrequire("gen_progress")

local GRID_SIZES = { 8, 10, 12, 15 }

local GAME_RULES_EN = _([[
Mosaic — Rules

Shade cells so that every number is right. A hidden picture appears as you go.

Rules:
• A number tells how many cells are shaded in its 3×3 block: the cell itself and its (up to) eight neighbours.
• Cells without a number can be shaded or not, as the numbers require.
• There is exactly one solution, and it can be found by reasoning alone.

Controls:
• Tap a cell to shade it, again to mark it empty (grey, with a dot), and again to clear it.
• Hold a cell to mark it empty directly.

A number turns grey once its block is complete and correct, and is framed when its block can no longer be right.
]])

local GAME_RULES_FR = [[
Mosaic — Règles

Noircissez des cases pour que chaque nombre soit juste. Une image cachée apparaît au fil de la partie.

Règles :
• Un nombre indique combien de cases sont noircies dans son bloc 3×3 : la case elle-même et ses huit voisines (ou moins au bord).
• Les cases sans nombre sont noircies ou non, selon ce qu'exigent les nombres.
• Il y a exactement une solution, et elle se trouve par le seul raisonnement.

Commandes :
• Touchez une case pour la noircir, une deuxième fois pour la marquer vide (grise, avec un point), une troisième fois pour l'effacer.
• Maintenez le doigt sur une case pour la marquer vide directement.

Un nombre devient gris quand son bloc est complet et juste, et s'encadre quand son bloc ne peut plus être juste.
]]

local MosaicScreen = ScreenBase:extend{}

function MosaicScreen:describeHintStep(step, level)
    if level == 1 then return ScreenBase.describeHintStep(self, step, level) end
    if step.kind == "mistake" then return T(_("Cleared R%1C%2."), step.r, step.c) end
    return step.value == MosaicBoard.SHADED
        and T(_("Shaded R%1C%2."), step.r, step.c)
        or  T(_("Marked R%1C%2 as empty."), step.r, step.c)
end

function MosaicScreen:init()
    local state = self.plugin:loadState()
    self.board  = MosaicBoard:new{ n = self.plugin:getSetting("grid_n", 10) }
    if not self.board:load(state) then
        local diff = self.plugin:getSetting("difficulty", "medium")
        GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    end
    ScreenBase.init(self)
end

function MosaicScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function MosaicScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Mosaic"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Check"),     callback = function() self:onCheck() end },
        { text = _("Hint"),      callback = function() self:onHint() end },
        { text = _("Clear All"), callback = function() self:onClearAll() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad = Size.padding.large
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = MosaicBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - 2 * frame_pad,
        hint_cell    = function() return self.hint_cell end,
        onCellAction = function(r, c, is_hold) self:onCellAction(r, c, is_hold) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoButton()

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

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

function MosaicScreen:onCellAction(r, c, is_hold)
    if self.board:checkWin() then return end
    local changed
    if is_hold then
        changed = self.board:holdCell(r, c)
    else
        changed = self.board:tapCell(r, c)
    end
    if changed then self:afterMove() end
end

function MosaicScreen:afterMove()
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    self:updateStatus()
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function MosaicScreen:onNewGame()
    self.board = MosaicBoard:new{ n = self.plugin:getSetting("grid_n", 10) }
    local diff = self.plugin:getSetting("difficulty", "medium")
    GenProgress.run(function(on_progress) self.board:generate(diff, on_progress) end)
    self.hint_cell = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function MosaicScreen:onClearAll()
    if self.board:clearAll() then self:afterMove() end
end

function MosaicScreen:onUndo()
    -- The board's `undo` field (its UndoStack) shadows the :undo() method.
    local ok, msg = MosaicBoard.undo(self.board)
    if ok then
        self:afterMove()
    else
        self:updateStatus(msg)
    end
end

function MosaicScreen:isRoundOver()
    return self.board:checkWin()
end

function MosaicScreen:onHint()
    ScreenBase.onHint(self)
    self:_updateUndoButton()
end

function MosaicScreen:onCheck()
    local b = self.board
    if b:checkWin() then
        self:updateStatus()
        return
    end
    local wrong = b:countMistakes()
    if wrong == 0 then
        self:updateStatus(_("No mistakes so far."))
    else
        self:updateStatus(T(_("Wrong cells: %1"), wrong))
    end
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function MosaicScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 10),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function MosaicScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function MosaicScreen:updateStatus(msg)
    local b = self.board
    local status
    if msg then
        status = msg
    elseif b:checkWin() then
        status = self:joinStatus(_("Congratulations! Puzzle solved!"),
            T(_("Time: %1"), b.timer:format()))
    else
        local label = MenuHelper.DIFFICULTY_LABELS[b.difficulty] or b.difficulty
        status = self:joinStatus(T("%1×%1", b.n), label,
            T(_("Shaded: %1"), b:getShadedCount()), b.timer:format())
    end
    ScreenBase.updateStatus(self, status)
end

function MosaicScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function MosaicScreen:getDiffButtonText()
    local diff = self.plugin:getSetting("difficulty", "medium")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function MosaicScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return MosaicScreen
