local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack = require("undo_stack")
local Timer     = require("timer")
local Hint      = require("hint")
local Solver    = lrequire("solver")

local floor = math.floor

local DEFAULT_N          = 10
local DEFAULT_DIFFICULTY = "medium"

-- Player cell states.
local UNKNOWN = 0
local SHADED  = 1
local EMPTY   = 2   -- marked "not shaded" (a dot)

-- Clue digging runs in phases, each keeping the puzzle solvable by a given
-- level of logic (see solver.lua).
--   easy    digs with single-clue logic only, so that is all it needs.
--   medium  digs with single clues first, then with clue pairs: every clue
--           the second phase removes is one single-clue logic needed, so the
--           puzzle needs the pair rule -- typically in one or two places.
--   hard    digs with clue pairs from the start, and is kept only if the pair
--           rule is needed in at least MIN_PAIR_ROUNDS separate rounds (a
--           round = the solve stalls on single clues and a pair unblocks it).
-- The one-step trial (level 3) is not used to dig: measured, it removes a
-- clue from a pair-minimal puzzle in under 1 picture in 6 -- Mosaic's pair
-- rule is nearly complete -- so it would only slow generation down.
local DIG_PHASES = {
    easy   = { 1 },
    medium = { 1, 2 },
    hard   = { 2 },
}
local MIN_PAIR_ROUNDS  = { easy = 0, medium = 1, hard = 2 }
local DIFFICULTY_LEVEL = { easy = 1, medium = 2, hard = 2 }

-- ---------------------------------------------------------------------------
-- Generator helpers
-- ---------------------------------------------------------------------------

-- A random picture: noise smoothed once by a 3x3 majority vote, which turns
-- salt-and-pepper into blobs -- nicer to reveal, and blobs give clues near 0
-- and 9 that make the puzzle start somewhere.
local function randomPicture(n)
    local g = {}
    for r = 1, n do
        g[r] = {}
        for c = 1, n do g[r][c] = math.random() < 0.5 and 1 or 0 end
    end
    local h = {}
    for r = 1, n do
        h[r] = {}
        for c = 1, n do
            local s, t = 0, 0
            for dr = -1, 1 do
                for dc = -1, 1 do
                    local row = g[r + dr]
                    local v = row and row[c + dc]
                    if v then s, t = s + v, t + 1 end
                end
            end
            if 2 * s > t then h[r][c] = 1
            elseif 2 * s < t then h[r][c] = 0
            else h[r][c] = g[r][c] end
        end
    end
    return h
end

local function neighbourSum(grid, n, r, c)
    local s = 0
    for dr = -1, 1 do
        for dc = -1, 1 do
            local rr, cc = r + dr, c + dc
            if rr >= 1 and rr <= n and cc >= 1 and cc <= n then s = s + grid[rr][cc] end
        end
    end
    return s
end

-- ---------------------------------------------------------------------------
-- MosaicBoard
-- ---------------------------------------------------------------------------

local MosaicBoard = {
    UNKNOWN = UNKNOWN, SHADED = SHADED, EMPTY = EMPTY,
    Solver = Solver, DIFFICULTY_LEVEL = DIFFICULTY_LEVEL,
    MIN_PAIR_ROUNDS = MIN_PAIR_ROUNDS,
}
MosaicBoard.__index = MosaicBoard

function MosaicBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = setmetatable({
        n          = n,
        difficulty = opts.difficulty or DEFAULT_DIFFICULTY,
        clues      = {},   -- clues[r][c] = 0..9, or -1 for no clue
        solution   = {},   -- solution[r][c] = 1 shaded / 0 empty
        cells      = {},   -- player state, UNKNOWN / SHADED / EMPTY
        undo       = UndoStack:new{ max_size = 300 },
        timer      = Timer:new(),
        hints_used = 0,
    }, self)
    return obj
end

-- Generation progress for on_progress(fraction): `inner` (0..1) is how far
-- the current attempt is; each new attempt fills half of what is left of the
-- bar, so it only ever moves forward.
local function report(on_progress, attempt, inner)
    if on_progress then on_progress(1 - 0.5 ^ (attempt - 1) * (1 - inner / 2)) end
end

-- Generates a picture and digs its clues down. Returns the clue grid, the
-- solution and the number of pair-rule rounds the solve needs, or nil when
-- the last of several dig phases removed nothing (the puzzle would then be
-- easier than asked). progress(inner), optional, is told how far the dig is.
function MosaicBoard:_attempt(phases, progress)
    local n = self.n
    local sol = randomPicture(n)
    local clues = {}
    for r = 1, n do
        clues[r] = {}
        for c = 1, n do clues[r][c] = neighbourSum(sol, n, r, c) end
    end
    local model = Solver.buildModel(clues, n)
    if not Solver.solvesAt(model, phases[1]) then return nil end

    local order = {}
    for i = 1, n * n do order[i] = i end
    local removed_last = 0
    for pi, level in ipairs(phases) do
        for i = #order, 2, -1 do
            local j = math.random(i)
            order[i], order[j] = order[j], order[i]
        end
        for k, x in ipairs(order) do
            if progress and k % n == 0 then
                progress(((pi - 1) * #order + k) / (#phases * #order))
            end
            local r, c = floor((x - 1) / n) + 1, (x - 1) % n + 1
            if clues[r][c] >= 0 then
                Solver.setActive(model, x, false)
                if Solver.solvesAt(model, level) then
                    clues[r][c] = -1
                    if pi == #phases then removed_last = removed_last + 1 end
                else
                    Solver.setActive(model, x, true)
                end
            end
        end
    end
    if #phases > 1 and removed_last == 0 then return nil end
    -- The model's active clues are exactly the ones left.
    local stats = {}
    Solver.solvesAt(model, 2, stats)
    return clues, sol, stats.pairs or 0
end

-- on_progress(fraction), optional, is called as generation advances (the
-- screen drives a progress bar with it). Generation only draws on
-- math.random and counts its work, never the clock, so a seed always gives
-- the same puzzle (the Daily Challenge relies on it).
function MosaicBoard:generate(difficulty, on_progress)
    self.difficulty = difficulty or self.difficulty
    local phases = DIG_PHASES[self.difficulty] or DIG_PHASES.medium
    local want = MIN_PAIR_ROUNDS[self.difficulty] or 1
    local clues, sol, best = nil, nil, -1
    -- Measured at 8x8 hard (the worst case: a small grid has few clue
    -- pairs), a bit under half the pictures meet the bar; 40 tries leave a
    -- negligible miss rate, and a miss still yields a valid, unique puzzle.
    for attempt = 1, 40 do
        report(on_progress, attempt, 0)
        local c, s, rounds = self:_attempt(phases, on_progress and function(inner)
            report(on_progress, attempt, inner)
        end)
        if c and rounds > best then clues, sol, best = c, s, rounds end
        if best >= want then break end
    end
    -- Never seen to happen; a gentler puzzle beats no puzzle.
    while not clues do
        clues, sol, best = self:_attempt({ phases[1] })
    end
    if on_progress then on_progress(1) end
    self.clues, self.solution = clues, sol
    self:_resetPlay()
end

function MosaicBoard:_resetPlay()
    local n = self.n
    self.cells = {}
    for r = 1, n do
        self.cells[r] = {}
        for c = 1, n do self.cells[r][c] = UNKNOWN end
    end
    self.hints_used = 0
    self.undo:clear()
    self.timer:reset()
    self.timer:start()
end

-- ---------------------------------------------------------------------------
-- Moves
-- ---------------------------------------------------------------------------

-- changes: list of { r, c, from, to }.
function MosaicBoard:_commit(changes)
    if #changes == 0 then return false end
    for _, ch in ipairs(changes) do self.cells[ch[1]][ch[2]] = ch[4] end
    self.undo:push{ changes = changes }
    if self:checkWin() then self.timer:stop() end
    return true
end

function MosaicBoard:setCell(r, c, v)
    if not (self.cells[r] and self.cells[r][c]) then return false end
    local old = self.cells[r][c]
    if old == v then return false end
    return self:_commit({ { r, c, old, v } })
end

-- Tap cycles unknown -> shaded -> empty -> unknown.
local NEXT = { [UNKNOWN] = SHADED, [SHADED] = EMPTY, [EMPTY] = UNKNOWN }
function MosaicBoard:tapCell(r, c)
    return self:setCell(r, c, NEXT[self.cells[r][c]])
end

-- Hold marks a cell empty, or clears an empty mark.
function MosaicBoard:holdCell(r, c)
    return self:setCell(r, c, self.cells[r][c] == EMPTY and UNKNOWN or EMPTY)
end

function MosaicBoard:clearAll()
    local changes = {}
    for r = 1, self.n do
        for c = 1, self.n do
            if self.cells[r][c] ~= UNKNOWN then
                changes[#changes + 1] = { r, c, self.cells[r][c], UNKNOWN }
            end
        end
    end
    return self:_commit(changes)
end

function MosaicBoard:canUndo() return self.undo:canUndo() end

-- Called as MosaicBoard.undo(board): the `undo` field (the stack) shadows
-- this method on instances.
function MosaicBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    for i = #entry.changes, 1, -1 do
        local ch = entry.changes[i]
        self.cells[ch[1]][ch[2]] = ch[3]
    end
    if not self:checkWin() then self.timer:start() end
    return true
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- For the clue at r,c: shaded and undecided counts in its 3x3 block.
function MosaicBoard:clueCounts(r, c)
    local n, s, u = self.n, 0, 0
    for dr = -1, 1 do
        for dc = -1, 1 do
            local rr, cc = r + dr, c + dc
            if rr >= 1 and rr <= n and cc >= 1 and cc <= n then
                local v = self.cells[rr][cc]
                if v == SHADED then s = s + 1 elseif v == UNKNOWN then u = u + 1 end
            end
        end
    end
    return s, u
end

-- "done" when every cell around is decided and the count fits, "error" when
-- the count can no longer fit, else "open".
function MosaicBoard:clueState(r, c)
    local v = self.clues[r][c]
    if v < 0 then return nil end
    local s, u = self:clueCounts(r, c)
    if s > v or s + u < v then return "error" end
    if u == 0 then return "done" end
    return "open"
end

-- Solved = every clue sees exactly its count of shaded cells. The generator
-- guarantees a unique solution, so that is the stored picture.
function MosaicBoard:checkWin()
    for r = 1, self.n do
        for c = 1, self.n do
            local v = self.clues[r][c]
            if v >= 0 then
                local shaded = self:clueCounts(r, c)
                if shaded ~= v then return false end
            end
        end
    end
    return true
end

function MosaicBoard:getShadedCount()
    local k = 0
    for r = 1, self.n do
        for c = 1, self.n do
            if self.cells[r][c] == SHADED then k = k + 1 end
        end
    end
    return k
end

function MosaicBoard:getSolutionShadedCount()
    local k = 0
    for r = 1, self.n do
        for c = 1, self.n do k = k + self.solution[r][c] end
    end
    return k
end

local function solutionState(self, r, c)
    return self.solution[r][c] == 1 and SHADED or EMPTY
end

-- Decided cells that contradict the solution.
function MosaicBoard:countMistakes()
    local k = 0
    for r = 1, self.n do
        for c = 1, self.n do
            local v = self.cells[r][c]
            if v ~= UNKNOWN and v ~= solutionState(self, r, c) then k = k + 1 end
        end
    end
    return k
end

-- ---------------------------------------------------------------------------
-- Hints. Mistakes come first (the generic grid hint finds them). Otherwise
-- the logic is run from the player's own marks and the first cell it
-- decides is offered -- the simplest deduction available, tried level by
-- level, rather than an arbitrary reveal.
-- ---------------------------------------------------------------------------

Hint.install(MosaicBoard, {
    isEmpty     = function(v) return v == nil or v == UNKNOWN end,
    getUser     = function(b, r, c) return b.cells[r][c] end,
    getSolution = function(b, r, c) return solutionState(b, r, c) end,
    setCell     = function(b, r, c, v) return b:setCell(r, c, v) end,
    blank       = UNKNOWN,
})

local gridHint = MosaicBoard.findHint

function MosaicBoard:findHint()
    local step, reason = gridHint(self)
    if not step or step.kind == "mistake" then return step, reason end
    local n = self.n
    local model = Solver.buildModel(self.clues, n)
    for level = 1, 3 do
        local val = Solver.newValues(model)
        for r = 1, n do
            for c = 1, n do
                local v = self.cells[r][c]
                if v == SHADED then val[(r - 1) * n + c] = 1
                elseif v == EMPTY then val[(r - 1) * n + c] = 0 end
            end
        end
        local log = {}
        if Solver.propagate(model, val, level, { log = log }) and log[1] then
            local x = log[1]
            local r, c = floor((x - 1) / n) + 1, (x - 1) % n + 1
            return { kind = "fill", r = r, c = c, value = solutionState(self, r, c) }
        end
    end
    return step
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function copyGrid(g, n)
    local o = {}
    for r = 1, n do
        o[r] = {}
        for c = 1, n do o[r][c] = g[r][c] end
    end
    return o
end

function MosaicBoard:serialize()
    local n = self.n
    -- Timer:serialize() stops the clock; a save in mid-game must not.
    local running = self.timer:isRunning()
    local timer = self.timer:serialize()
    if running then self.timer:start() end
    return {
        version    = 1,
        n          = n,
        difficulty = self.difficulty,
        clues      = copyGrid(self.clues, n),
        solution   = copyGrid(self.solution, n),
        cells      = copyGrid(self.cells, n),
        hints_used = self.hints_used,
        undo       = self.undo:serialize(),
        timer      = timer,
    }
end

function MosaicBoard:load(data)
    if type(data) ~= "table" or type(data.n) ~= "number" then return false end
    local n = data.n
    for _, key in ipairs({ "clues", "solution", "cells" }) do
        local g = data[key]
        if type(g) ~= "table" or #g ~= n or type(g[1]) ~= "table" or #g[1] ~= n then
            return false
        end
    end
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.clues      = copyGrid(data.clues, n)
    self.solution   = copyGrid(data.solution, n)
    self.cells      = copyGrid(data.cells, n)
    self.hints_used = data.hints_used or 0
    self.undo = UndoStack:new{ max_size = 300 }
    if data.undo then self.undo:load(data.undo) end
    self.timer = Timer:new()
    if data.timer then self.timer:load(data.timer) end
    return true
end

-- Frees the solver's per-size caches (see Solver.release).
function MosaicBoard.release()
    Solver.release()
end

return MosaicBoard
