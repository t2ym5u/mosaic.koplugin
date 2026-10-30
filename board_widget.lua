local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local floor = math.floor

-- Player cell states (board.lua).
local SHADED = 1
local EMPTY  = 2

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

local C_BG         = Blitbuffer.COLOR_WHITE
local C_SHADED     = Blitbuffer.COLOR_BLACK
local C_EMPTY      = Blitbuffer.COLOR_GRAY_D   -- marked "not shaded"
local C_GRID       = Blitbuffer.COLOR_GRAY_9
local C_LINE       = Blitbuffer.COLOR_BLACK
local C_TEXT       = Blitbuffer.COLOR_BLACK
local C_TEXT_ON    = Blitbuffer.COLOR_WHITE    -- clue on a shaded cell
local C_DONE       = Blitbuffer.COLOR_GRAY_7   -- satisfied clue, on light
local C_DONE_ON    = Blitbuffer.COLOR_GRAY_9   -- satisfied clue, on black
local C_HINT       = Blitbuffer.COLOR_GRAY_B

-- ---------------------------------------------------------------------------
-- MosaicBoardWidget
-- ---------------------------------------------------------------------------

local MosaicBoardWidget = GridWidgetBase:extend{ board = nil, hint_cell = nil }

function MosaicBoardWidget:init()
    local n = self.board and self.board.n or 10
    self.cols, self.rows = n, n
    self.max_value = 9
    GridWidgetBase.init(self)
end

function MosaicBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function MosaicBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

function MosaicBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board = self.board
    local n     = board.n
    local cell  = self.dimen.w / n
    local thick = math.max(2, floor(cell * 0.08))
    local ring  = math.max(2, floor(cell * 0.07))
    local hint  = self.hint_cell and self.hint_cell()

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Cell backgrounds and dots.
    for r = 1, n do
        for c = 1, n do
            local cx = x + floor((c - 1) * cell)
            local cy = y + floor((r - 1) * cell)
            local cw = floor(c * cell) - floor((c - 1) * cell)
            local ch = floor(r * cell) - floor((r - 1) * cell)
            local v  = board.cells[r][c]
            if v == SHADED then
                bb:paintRect(cx, cy, cw, ch, C_SHADED)
            elseif v == EMPTY then
                bb:paintRect(cx, cy, cw, ch, C_EMPTY)
                if board.clues[r][c] < 0 then
                    local d = math.max(3, floor(cell * 0.14))
                    bb:paintRect(cx + floor((cw - d) / 2), cy + floor((ch - d) / 2), d, d, C_LINE)
                end
            elseif hint and hint.r == r and hint.c == c then
                bb:paintRect(cx, cy, cw, ch, C_HINT)
            end
        end
    end

    -- The cell a hint is talking about gets a frame too, so a wrong shaded
    -- or emptied cell (no fill to change) is still easy to spot.
    if hint and board.cells[hint.r] and board.cells[hint.r][hint.c] then
        local cx = x + floor((hint.c - 1) * cell)
        local cy = y + floor((hint.r - 1) * cell)
        local cw = floor(hint.c * cell) - floor((hint.c - 1) * cell)
        local on_black = board.cells[hint.r][hint.c] == SHADED
        local fc = on_black and C_TEXT_ON or C_LINE
        local m = math.max(2, floor(cell * 0.06))
        local t = ring
        drawLine(bb, cx + m, cy + m, cw - 2 * m, t, fc)
        drawLine(bb, cx + m, cy + cw - m - t, cw - 2 * m, t, fc)
        drawLine(bb, cx + m, cy + m, t, cw - 2 * m, fc)
        drawLine(bb, cx + cw - m - t, cy + m, t, cw - 2 * m, fc)
    end

    -- Grid: thin lines, a heavier one every five cells to help counting.
    local heavy = math.max(2, floor(thick / 2))
    for i = 1, n - 1 do
        local w = (i % 5 == 0) and heavy or 1
        local off = floor(i * cell) - floor(w / 2)
        local col = (i % 5 == 0) and C_LINE or C_GRID
        drawLine(bb, x + off, y, w, self.dimen.h, col)
        drawLine(bb, x, y + off, self.dimen.w, w, col)
    end
    drawLine(bb, x, y, self.dimen.w, thick, C_LINE)
    drawLine(bb, x, y + self.dimen.h - thick, self.dimen.w, thick, C_LINE)
    drawLine(bb, x, y, thick, self.dimen.h, C_LINE)
    drawLine(bb, x + self.dimen.w - thick, y, thick, self.dimen.h, C_LINE)

    -- Clues: dimmed once satisfied, ringed when they can no longer be.
    local pad  = self.number_padding or 2
    for r = 1, n do
        for c = 1, n do
            local v = board.clues[r][c]
            if v >= 0 then
                local cx = x + floor((c - 1) * cell)
                local cy = y + floor((r - 1) * cell)
                local cw = floor(c * cell) - floor((c - 1) * cell)
                local on_black = board.cells[r][c] == SHADED
                local state = board:clueState(r, c)
                local color
                if state == "done" then
                    color = on_black and C_DONE_ON or C_DONE
                else
                    color = on_black and C_TEXT_ON or C_TEXT
                end
                if state == "error" then
                    local rc = on_black and C_TEXT_ON or C_LINE
                    local m  = math.max(pad, floor(cell * 0.1))
                    local s  = cw - 2 * m
                    bb:paintRect(cx + m, cy + m, s, s, rc)
                    bb:paintRect(cx + m + ring, cy + m + ring, s - 2 * ring, s - 2 * ring,
                        on_black and C_SHADED or (board.cells[r][c] == EMPTY and C_EMPTY or C_BG))
                end
                local text = tostring(v)
                local inner = math.max(1, cw - 2 * pad)
                local mt   = RenderText:sizeUtf8Text(0, inner, self.number_face, text, true, false)
                local base = cy + pad + floor((inner + mt.y_top - mt.y_bottom) / 2)
                local tx   = cx + pad + floor((inner - mt.x) / 2)
                RenderText:renderUtf8Text(bb, tx, base, self.number_face, text, true, false, color)
            end
        end
    end
end

return MosaicBoardWidget
