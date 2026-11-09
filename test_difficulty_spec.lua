-- Difficulty guarantees for Mosaic (see docs/dev/TESTING.md, "Difficulty
-- specs"): every size x level is unique and rated by the game's own solver
-- at exactly its level (single clues for Easy, the pair rule for Medium and
-- Hard, never the one-step trial), Hard needs more pair-rule rounds than
-- Medium on average, a seed gives the same puzzle without reading the
-- clock, and generation stays within a generous time bound.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

local SIZES  = { 8, 10, 12, 15 }
local LEVELS = { "easy", "medium", "hard" }

describe("Mosaic difficulty", function()
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

    local function clueCount(b)
        local k = 0
        for r = 1, b.n do
            for c = 1, b.n do
                if b.clues[r][c] >= 0 then k = k + 1 end
            end
        end
        return k
    end

    -- Everything that defines the puzzle, as a string.
    local function fingerprint(b)
        local t = { b.n }
        for r = 1, b.n do
            for c = 1, b.n do t[#t + 1] = b.clues[r][c] .. "/" .. b.solution[r][c] end
        end
        return table.concat(t, ",")
    end

    -- Generates under clockReads: the generator must not read the clock.
    local function generate(n, diff, seed, on_progress)
        math.randomseed(seed)
        local b = Board:new{ n = n }
        local reads = clockReads(function() b:generate(diff, on_progress) end)
        assert.are.equal(0, reads, ("%dx%d %s read the clock"):format(n, n, diff))
        return b
    end

    it("the level table is ordered", function()
        local L, P = Board.DIFFICULTY_LEVEL, Board.MIN_PAIR_ROUNDS
        assert.is_true(L.easy < L.medium and L.medium <= L.hard)
        assert.is_true(P.easy < P.medium and P.medium < P.hard)
        -- level 3 (the one-step trial) is never asked for
        assert.is_true(L.hard <= 2)
    end)

    -- moved from test_board_spec.lua
    it("is unique and needs exactly its difficulty's logic, over many seeds", function()
        for _, diff in ipairs({ "easy", "medium", "hard" }) do
            for _, n in ipairs({ 8, 10, 12, 15 }) do
                for seed = 1, 4 do
                    local b = newBoard(n, diff, seed * 17 + n)
                    local model = Solver.buildModel(b.clues, n)
                    local level, val = Solver.rate(model)
                    assert.are.equal(Board.DIFFICULTY_LEVEL[diff], level,
                        ("wrong level: %d %s seed %d"):format(n, diff, seed))
                    -- The logic's answer is the stored picture.
                    for r = 1, n do
                        for c = 1, n do
                            assert.are.equal(b.solution[r][c], val[(r - 1) * n + c])
                        end
                    end
                    local stats = {}
                    Solver.solvesAt(model, 2, stats)
                    assert.is_true((stats.pairs or 0) >= Board.MIN_PAIR_ROUNDS[diff],
                        ("too easy: %d %s seed %d"):format(n, diff, seed))
                end
            end
        end
    end)

    -- moved from test_board_spec.lua
    it("backtracking confirms uniqueness", function()
        for seed = 1, 5 do
            local b = newBoard(10, "hard", seed)
            assert.are.equal(1, Solver.countSolutions(Solver.buildModel(b.clues, 10), 2))
        end
    end)

    -- moved from test_board_spec.lua
    it("digs a good share of the clues away", function()
        local b = newBoard(12, "hard")
        assert.is_true(clueCount(b) < 0.5 * 144)
    end)

    -- moved from test_generator_spec.lua
    it("builds the same puzzle from the same seed, without reading the clock", function()
        for _, case in ipairs({ { 8, "easy" }, { 12, "medium" }, { 15, "hard" } }) do
            local a = fingerprint(generate(case[1], case[2], 2024))
            local b = fingerprint(generate(case[1], case[2], 2024, function() end))
            assert.are.equal(a, b)
            assert.are_not.equal(a, fingerprint(generate(case[1], case[2], 2025)))
        end
    end)

    it("levels are ordered on pair-rule rounds, on average, at every size", function()
        for _, n in ipairs(SIZES) do
            local avg = {}
            for _, diff in ipairs(LEVELS) do
                local sum = 0
                for seed = 1, 4 do
                    local b = newBoard(n, diff, seed * 101 + n)
                    local stats = {}
                    assert.is_true(Solver.solvesAt(Solver.buildModel(b.clues, n), 2, stats))
                    sum = sum + (stats.pairs or 0)
                end
                avg[diff] = sum / 4
            end
            assert.are.equal(0, avg.easy)
            assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                ("%d: pair rounds %.2f/%.2f/%.2f"):format(n, avg.easy, avg.medium, avg.hard))
        end
    end)

    it("generates within a generous time bound", function()
        for _, n in ipairs(SIZES) do
            for _, diff in ipairs(LEVELS) do
                local worst = 0
                for seed = 1, 3 do
                    math.randomseed(seed * 7 + n)
                    local b = Board:new{ n = n }
                    local t = os.clock()
                    b:generate(diff)
                    worst = math.max(worst, os.clock() - t)
                end
                -- ~0.17 s worst on a desktop (15x15 hard)
                assert.is_true(worst < 3, ("%dx%d %s took %.2f s"):format(n, n, diff, worst))
            end
        end
    end)
end)
