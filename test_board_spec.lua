local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("MosaicBoard", function()
    local Board, Solver

    setup(function()
        Board  = dofile(DIR .. "board.lua")
        Solver = Board.Solver
    end)

    local function newBoard(n, diff, seed)
        math.randomseed(seed or 42)
        local b = Board:new{ n = n or 8 }
        b:generate(diff or "medium")
        return b
    end

    local function solve(b)
        for r = 1, b.n do
            for c = 1, b.n do
                b:setCell(r, c, b.solution[r][c] == 1 and Board.SHADED or Board.EMPTY)
            end
        end
    end

    describe("solver", function()
        it("each level of logic is sound: it never completes an ambiguous grid", function()
            -- Two clues "1" in the corners of a 2x2 can't decide anything.
            local model = Solver.buildModel({ { 1, -1 }, { -1, -1 } }, 2)
            assert.is_nil(Solver.rate(model))
            assert.is_true(Solver.countSolutions(model, 2) >= 2)
        end)

        it("single clues decide full and empty blocks", function()
            local model = Solver.buildModel({ { 4, -1 }, { -1, -1 } }, 2)
            assert.are.equal(1, (Solver.rate(model)))
            model = Solver.buildModel({ { 0, -1 }, { -1, -1 } }, 2)
            assert.are.equal(1, (Solver.rate(model)))
        end)

        it("the pair rule cracks what single clues cannot", function()
            local b = newBoard(10, "medium", 2)
            local model = Solver.buildModel(b.clues, 10)
            assert.is_false(Solver.solvesAt(model, 1))
            assert.is_true(Solver.solvesAt(model, 2))
        end)
    end)

    describe("generate", function()
        it("clues match the stored picture", function()
            local b = newBoard(10, "medium")
            for r = 1, b.n do
                for c = 1, b.n do
                    local v = b.clues[r][c]
                    if v >= 0 then
                        local s = 0
                        for dr = -1, 1 do
                            for dc = -1, 1 do
                                local row = b.solution[r + dr]
                                s = s + (row and row[c + dc] or 0)
                            end
                        end
                        assert.are.equal(s, v)
                    end
                end
            end
        end)
    end)

    describe("moves", function()
        it("tap cycles unknown -> shaded -> empty -> unknown", function()
            local b = newBoard(8, "easy")
            b:tapCell(1, 1)
            assert.are.equal(Board.SHADED, b.cells[1][1])
            b:tapCell(1, 1)
            assert.are.equal(Board.EMPTY, b.cells[1][1])
            b:tapCell(1, 1)
            assert.are.equal(Board.UNKNOWN, b.cells[1][1])
        end)

        it("hold toggles the empty mark", function()
            local b = newBoard(8, "easy")
            b:holdCell(2, 2)
            assert.are.equal(Board.EMPTY, b.cells[2][2])
            b:holdCell(2, 2)
            assert.are.equal(Board.UNKNOWN, b.cells[2][2])
            b:tapCell(2, 2)
            b:holdCell(2, 2)
            assert.are.equal(Board.EMPTY, b.cells[2][2])
        end)

        it("undo reverts moves and clearAll in one step", function()
            local b = newBoard(8, "easy")
            b:tapCell(1, 1)
            b:tapCell(3, 3)
            b:clearAll()
            assert.are.equal(0, b:getShadedCount())
            assert.is_true(Board.undo(b))
            assert.are.equal(2, b:getShadedCount())
            assert.is_true(Board.undo(b))
            assert.is_true(Board.undo(b))
            assert.are.equal(0, b:getShadedCount())
            assert.is_false(Board.undo(b))
        end)

        it("clue states: open, done, error", function()
            local b = newBoard(8, "easy")
            local r, c
            for rr = 2, 7 do
                for cc = 2, 7 do
                    if not r and b.clues[rr][cc] >= 1 and b.clues[rr][cc] <= 8 then r, c = rr, cc end
                end
            end
            assert.are.equal("open", b:clueState(r, c))
            for dr = -1, 1 do
                for dc = -1, 1 do
                    local v = b.solution[r + dr][c + dc] == 1 and Board.SHADED or Board.EMPTY
                    b:setCell(r + dr, c + dc, v)
                end
            end
            assert.are.equal("done", b:clueState(r, c))
            -- Flip one shaded cell to empty: the count can no longer fit.
            for dr = -1, 1 do
                for dc = -1, 1 do
                    if b.cells[r + dr][c + dc] == Board.SHADED then
                        b:setCell(r + dr, c + dc, Board.EMPTY)
                        assert.are.equal("error", b:clueState(r, c))
                        return
                    end
                end
            end
        end)
    end)

    describe("win detection", function()
        it("the picture wins and stops the timer; one wrong cell does not", function()
            local b = newBoard(10, "medium")
            assert.is_false(b:checkWin())
            solve(b)
            assert.is_true(b:checkWin())
            assert.is_false(b.timer:isRunning())
            assert.are.equal(b:getSolutionShadedCount(), b:getShadedCount())
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.solution[r][c] == 1 then
                        b:setCell(r, c, Board.EMPTY)
                        assert.is_false(b:checkWin())
                        return
                    end
                end
            end
        end)

        it("unknown cells count as unshaded", function()
            local b = newBoard(8, "easy")
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.solution[r][c] == 1 then b:setCell(r, c, Board.SHADED) end
                end
            end
            assert.is_true(b:checkWin())
        end)
    end)

    describe("hints", function()
        it("a wrong cell is reported first, and cleared", function()
            local b = newBoard(8, "medium")
            b:setCell(4, 4, b.solution[4][4] == 1 and Board.EMPTY or Board.SHADED)
            local step = b:findHint()
            assert.are.equal("mistake", step.kind)
            assert.are.equal(4, step.r)
            assert.are.equal(4, step.c)
            assert.is_true(b:applyHint(step))
            assert.are.equal(Board.UNKNOWN, b.cells[4][4])
        end)

        it("fill hints are deductions, always right, and finish the puzzle", function()
            for _, diff in ipairs({ "easy", "medium", "hard" }) do
                local b = newBoard(10, diff, 9)
                local guard = 0
                while not b:checkWin() do
                    local step = b:findHint()
                    assert.are.equal("fill", step.kind)
                    local want = b.solution[step.r][step.c] == 1 and Board.SHADED or Board.EMPTY
                    assert.are.equal(want, step.value)
                    assert.is_true(b:applyHint(step))
                    guard = guard + 1
                    assert.is_true(guard <= 100)
                end
            end
        end)

        it("the first hint on a fresh easy board comes from a single clue", function()
            local b = newBoard(10, "easy", 3)
            local step = b:findHint()
            -- Deduced from scratch by level-1 logic: the clue cell's block
            -- must be all-or-nothing around some clue.
            local model = Solver.buildModel(b.clues, 10)
            local val, log = Solver.newValues(model), {}
            Solver.propagate(model, val, 1, { log = log })
            assert.are.equal((step.r - 1) * 10 + step.c, log[1])
        end)

        it("is deterministic", function()
            local b = newBoard(12, "hard", 4)
            assert.are.same(b:findHint(), b:findHint())
        end)
    end)

    describe("persistence", function()
        it("round-trips through serialize/load", function()
            local b = newBoard(12, "hard")
            b:tapCell(1, 1)
            b:holdCell(2, 2)
            b:noteHintUsed()
            local data = b:serialize()
            assert.is_true(b.timer:isRunning())   -- saving does not stop the clock
            local c = Board:new{}
            assert.is_true(c:load(data))
            assert.are.equal(12, c.n)
            assert.are.equal("hard", c.difficulty)
            assert.are.same(b.clues, c.clues)
            assert.are.same(b.solution, c.solution)
            assert.are.same(b.cells, c.cells)
            assert.are.equal(1, c:getHintsUsed())
            assert.is_true(Board.undo(c))
            assert.are.equal(Board.UNKNOWN, c.cells[2][2])
        end)

        it("rejects bad data", function()
            local c = Board:new{}
            assert.is_false(c:load(nil))
            assert.is_false(c:load({ n = 8 }))
            assert.is_false(c:load({ n = 8, clues = {}, solution = {}, cells = {} }))
        end)
    end)
end)
