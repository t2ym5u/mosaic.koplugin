local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.preload["gettext"] = package.preload["gettext"] or function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("Mosaic solver cache", function()
    it("builds shapes only when needed and release() drops them", function()
        local Solver = dofile(DIR .. "solver.lua")
        assert.are.same({}, Solver.cachedSizes())
        local function full(n)
            local cl = {}
            for r = 1, n do cl[r] = {} for c = 1, n do cl[r][c] = 1 end end
            return cl
        end
        local a = Solver.buildModel(full(8), 8)
        assert.are.same({ 8 }, Solver.cachedSizes())
        Solver.release()
        assert.are.same({}, Solver.cachedSizes())
        local b = Solver.buildModel(full(8), 8)
        assert.are.equal(#a.pairs, #b.pairs)
        assert.are.equal(#a.clues, #b.clues)
    end)

    it("generates the same puzzle after a release", function()
        local Board = dofile(DIR .. "board.lua")
        local function gen()
            math.randomseed(42)
            local b = Board:new{ n = 8 }
            b:generate("medium")
            return { b.clues, b.solution }
        end
        local first = gen()
        Board.release()
        assert.are.same(first, gen())
    end)
end)
