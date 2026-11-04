-- ---------------------------------------------------------------------------
-- solver.lua — Mosaic (Fill-a-Pix) model, graded logical solver and
-- solution counter.
--
-- A clue in cell X counts the shaded cells among X and its (up to) eight
-- neighbours. Cells are numbered (r-1)*n + c; a cell's value is -1 while
-- unknown, 1 shaded, 0 empty.
--
-- The logic is graded, so the generator can make a puzzle need exactly a
-- given amount of reasoning:
--   level 1  single clue -- a clue that needs all of its unknown cells shaded,
--            or none of them, decides them all.
--   level 2  + clue pairs -- two overlapping clues bound how many shaded
--            cells their shared part holds, which can decide the cells only
--            one of them sees (or the shared part itself).
--   level 3  + one-step trial -- a cell whose shading (or emptiness) leads to
--            a contradiction under level 2 takes the other value.
-- Every deduction is sound, so a puzzle the logic completes has exactly one
-- solution; countSolutions() (plain backtracking) cross-checks that in tests.
-- ---------------------------------------------------------------------------

local Solver = {}

-- The shape of a model with a clue in every cell (neighbourhoods, pairs)
-- depends on n only, and every generation attempt starts from one: built
-- once per size, then shared read-only by the models made from it.
local full_shapes = {}

-- Sizes whose full shape is built (for tests).
function Solver.cachedSizes()
    local list = {}
    for n in pairs(full_shapes) do list[#list + 1] = n end
    table.sort(list)
    return list
end

-- Drops the cached shapes (~0.5-1.5 MB per size; rebuilt in a few ms).
function Solver.release()
    full_shapes = {}
end

local function isFull(clues, n)
    for r = 1, n do
        local row = clues[r]
        if not row then return false end
        for c = 1, n do
            local v = row[c]
            if not v or v < 0 then return false end
        end
    end
    return true
end

-- clues[r][c] = number, or a negative value / nil for no clue.
function Solver.buildModel(clues, n)
    local full = isFull(clues, n)
    local shape = full and full_shapes[n]
    if shape then
        local model = { n = n, ncells = n * n, clues = {}, cellClues = shape.cellClues,
                        pairs = shape.pairs, active = {}, clueAt = shape.clueAt,
                        cluePairs = shape.cluePairs, pairSeen = {}, pairStamp = 0 }
        for ci, sc in ipairs(shape.clues) do
            model.clues[ci] = { r = sc.r, c = sc.c, value = clues[sc.r][sc.c], nb = sc.nb }
            model.active[ci] = true
        end
        return model
    end
    -- active[ci]: a clue can be switched off without rebuilding the model,
    -- which is what makes the generator's clue-by-clue digging affordable.
    local model = { n = n, ncells = n * n, clues = {}, cellClues = {}, pairs = {},
                    active = {}, clueAt = {}, cluePairs = {} }
    for i = 1, n * n do model.cellClues[i] = {} end
    local at = {}
    for r = 1, n do
        for c = 1, n do
            local v = clues[r] and clues[r][c]
            if v and v >= 0 then
                local nb = {}
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        local rr, cc = r + dr, c + dc
                        if rr >= 1 and rr <= n and cc >= 1 and cc <= n then
                            nb[#nb + 1] = (rr - 1) * n + cc
                        end
                    end
                end
                local ci = #model.clues + 1
                model.clues[ci] = { r = r, c = c, value = v, nb = nb }
                at[(r - 1) * n + c] = ci
                model.active[ci] = true
                model.cluePairs[ci] = {}
                for _, x in ipairs(nb) do
                    local list = model.cellClues[x]
                    list[#list + 1] = ci
                end
            end
        end
    end
    -- Overlapping clue pairs (centres at most two apart), with the three
    -- parts of their union precomputed.
    for ci, a in ipairs(model.clues) do
        for dr = -2, 2 do
            for dc = -2, 2 do
                local rr, cc = a.r + dr, a.c + dc
                if rr >= 1 and rr <= n and cc >= 1 and cc <= n then
                    local cj = at[(rr - 1) * n + cc]
                    if cj and cj > ci then
                        local b = model.clues[cj]
                        local inB = {}
                        for _, x in ipairs(b.nb) do inB[x] = true end
                        local shared, onlyA, onlyB, inA = {}, {}, {}, {}
                        for _, x in ipairs(a.nb) do
                            inA[x] = true
                            if inB[x] then shared[#shared + 1] = x else onlyA[#onlyA + 1] = x end
                        end
                        for _, x in ipairs(b.nb) do
                            if not inA[x] then onlyB[#onlyB + 1] = x end
                        end
                        local pi = #model.pairs + 1
                        model.pairs[pi] = {
                            a = ci, b = cj, shared = shared, onlyA = onlyA, onlyB = onlyB,
                        }
                        local la, lb = model.cluePairs[ci], model.cluePairs[cj]
                        la[#la + 1] = pi
                        lb[#lb + 1] = pi
                    end
                end
            end
        end
    end
    model.clueAt = at
    model.pairSeen, model.pairStamp = {}, 0
    if full then
        local sc = {}
        for ci, clue in ipairs(model.clues) do sc[ci] = { r = clue.r, c = clue.c, nb = clue.nb } end
        full_shapes[n] = { clues = sc, cellClues = model.cellClues, pairs = model.pairs,
                           clueAt = at, cluePairs = model.cluePairs }
    end
    return model
end

-- Switches the clue in cell x (index (r-1)*n+c) on or off.
function Solver.setActive(model, x, on)
    local ci = model.clueAt[x]
    if ci then model.active[ci] = on and true or false end
end

function Solver.newValues(model)
    local val = {}
    for i = 1, model.ncells do val[i] = -1 end
    return val
end

local function copy(t)
    local o = {}
    for i = 1, #t do o[i] = t[i] end
    return o
end

-- Counts shaded and unknown cells of a list.
local function tally(val, list)
    local s, u = 0, 0
    for k = 1, #list do
        local v = val[list[k]]
        if v == 1 then s = s + 1 elseif v == -1 then u = u + 1 end
    end
    return s, u
end

-- Propagation context: the value array; per clue, the shaded (`cs`) and
-- unknown (`cu`) cells it sees, kept up to date as cells are decided so no
-- rule has to recount a whole block; a queue of clues for the single-clue
-- rule; the clues whose cells changed since the pair rule last looked
-- (`dirty`: a pair can only say something new once one of its cells has
-- changed, and every cell of a pair is seen by one of its two clues); and an
-- optional log of the cells decided, in order (the hint reads it).
local function touch(model, ctx, x)
    local active, list = model.active, model.cellClues[x]
    for k = 1, #list do
        local ci = list[k]
        if active[ci] then
            if not ctx.inq[ci] then
                ctx.inq[ci] = true
                ctx.queue[#ctx.queue + 1] = ci
            end
            if not ctx.dirty[ci] then
                ctx.dirty[ci] = true
                ctx.dirtyList[#ctx.dirtyList + 1] = ci
            end
        end
    end
end

local function setCells(model, ctx, list, v)
    local val, cs, cu = ctx.val, ctx.cs, ctx.cu
    for k = 1, #list do
        local x = list[k]
        if val[x] == -1 then
            val[x] = v
            ctx.unknown = ctx.unknown - 1
            local seen_by = model.cellClues[x]
            for m = 1, #seen_by do
                local ci = seen_by[m]
                cu[ci] = cu[ci] - 1
                if v == 1 then cs[ci] = cs[ci] + 1 end
            end
            if ctx.log then ctx.log[#ctx.log + 1] = x end
            touch(model, ctx, x)
        end
    end
end

-- Level 1 to a fixpoint. Returns false on a contradiction.
local function runSingles(model, ctx)
    local queue, inq, cs, cu = ctx.queue, ctx.inq, ctx.cs, ctx.cu
    local clues = model.clues
    local head = 1
    while head <= #queue do
        local ci = queue[head]
        head = head + 1
        inq[ci] = false
        local u = cu[ci]
        local need = clues[ci].value - cs[ci]
        if need < 0 or need > u then return false end
        if u > 0 and (need == 0 or need == u) then
            setCells(model, ctx, clues[ci].nb, need == 0 and 0 or 1)
        end
    end
    for i = #queue, 1, -1 do queue[i] = nil end
    return true
end

-- The pair rule on one pair of clues; returns changed, ok.
local function pairRule(model, ctx, p)
    local cs, cu = ctx.cs, ctx.cu
    local sS, uS = tally(ctx.val, p.shared)
    -- The parts only one clue sees: that clue's block minus the shared part.
    local sA, uA = cs[p.a] - sS, cu[p.a] - uS
    local sB, uB = cs[p.b] - sS, cu[p.b] - uS
    if uS == 0 and uA == 0 and uB == 0 then return false, true end
    -- Shaded cells each clue still needs, and how many of them the shared
    -- part can hold.
    local rA = model.clues[p.a].value - sS - sA
    local rB = model.clues[p.b].value - sS - sB
    local smin = math.max(0, rA - uA, rB - uB)
    local smax = math.min(uS, rA, rB)
    if smin > smax then return false, false end
    local changed = false
    if uA > 0 then
        if rA - smax >= uA then setCells(model, ctx, p.onlyA, 1); changed = true
        elseif rA - smin <= 0 then setCells(model, ctx, p.onlyA, 0); changed = true end
    end
    if uB > 0 then
        if rB - smax >= uB then setCells(model, ctx, p.onlyB, 1); changed = true
        elseif rB - smin <= 0 then setCells(model, ctx, p.onlyB, 0); changed = true end
    end
    if uS > 0 then
        if smin >= uS then setCells(model, ctx, p.shared, 1); changed = true
        elseif smax <= 0 then setCells(model, ctx, p.shared, 0); changed = true end
    end
    return changed, true
end

-- The pair rule on every pair with a dirty clue. Returns changed, ok.
-- A pair met twice in one call is looked at once: model.pairSeen holds the
-- number of the call that last looked at it (a stamp, so nothing has to be
-- cleared between calls).
local function runPairs(model, ctx)
    local list = ctx.dirtyList
    if #list == 0 then return false, true end
    ctx.dirtyList, ctx.dirty = {}, {}
    local stamp = model.pairStamp + 1
    model.pairStamp = stamp
    local seen, active, pairs_, cluePairs = model.pairSeen, model.active, model.pairs, model.cluePairs
    local any = false
    for k = 1, #list do
        local cp = cluePairs[list[k]]
        for m = 1, #cp do
            local pi = cp[m]
            if seen[pi] ~= stamp then
                seen[pi] = stamp
                local p = pairs_[pi]
                if active[p.a] and active[p.b] then
                    local changed, ok = pairRule(model, ctx, p)
                    if not ok then return false, false end
                    any = any or changed
                end
            end
        end
    end
    return any, true
end

-- opts.seeds: cells just changed in an otherwise settled position (only
-- their clues need looking at); without it, everything is looked at.
local function newCtx(model, val, opts)
    local seeds = opts.seeds
    local ctx = { val = val, queue = {}, inq = {}, dirty = {}, dirtyList = {},
                  cs = {}, cu = {},
                  log = opts.log, stats = opts.stats, unknown = 0 }
    for i = 1, model.ncells do
        if val[i] == -1 then ctx.unknown = ctx.unknown + 1 end
    end
    local clues, cs, cu = model.clues, ctx.cs, ctx.cu
    for ci = 1, #clues do
        cs[ci], cu[ci] = tally(val, clues[ci].nb)
    end
    if seeds then
        for _, x in ipairs(seeds) do touch(model, ctx, x) end
    else
        for ci = 1, #model.clues do
            if model.active[ci] then
                ctx.queue[#ctx.queue + 1] = ci
                ctx.inq[ci] = true
                ctx.dirty[ci] = true
                ctx.dirtyList[#ctx.dirtyList + 1] = ci
            end
        end
    end
    return ctx
end

-- Runs the logic up to `level` on val (modified in place). Returns false on
-- a contradiction. Options:
--   log    receives the decided cells, in order (the hint reads it)
--   stats  counts the rounds in which the pair rule / a trial was needed
--          (stats.pairs, stats.trials), which is how puzzles get graded
--   seeds  internal, see newCtx
function Solver.propagate(model, val, level, opts)
    opts = opts or {}
    local ctx = newCtx(model, val, opts)
    local stats = ctx.stats
    local cursor, idle = 1, 0     -- level 3: where trials resume
    while true do
        if not runSingles(model, ctx) then return false end
        if ctx.unknown == 0 then return true end
        local changed = false
        if level >= 2 then
            local ok
            changed, ok = runPairs(model, ctx)
            if not ok then return false end
            if changed and stats then stats.pairs = (stats.pairs or 0) + 1 end
        end
        if not changed and level >= 3 then
            -- Try each unknown cell both ways; a value that breaks the
            -- level-2 logic is impossible. Resume after the last success
            -- and stop once a whole round has found nothing.
            local n = model.ncells
            while idle < n and not changed do
                local x = cursor
                cursor = cursor % n + 1
                idle = idle + 1
                if val[x] == -1 then
                    for v = 1, 0, -1 do
                        local trial = copy(val)
                        trial[x] = v
                        if not Solver.propagate(model, trial, 2, { seeds = { x } }) then
                            if stats then stats.trials = (stats.trials or 0) + 1 end
                            setCells(model, ctx, { x }, 1 - v)
                            changed, idle = true, 0
                            break
                        end
                    end
                end
            end
        end
        if not changed then return true end
    end
end

function Solver.isSolved(val)
    for i = 1, #val do
        if val[i] == -1 then return false end
    end
    return true
end

-- Weakest level (1..3) whose logic alone solves the puzzle, or nil.
function Solver.rate(model, max_level)
    for level = 1, max_level or 3 do
        local val = Solver.newValues(model)
        if Solver.propagate(model, val, level) and Solver.isSolved(val) then
            return level, val
        end
    end
    return nil
end

function Solver.solvesAt(model, level, stats)
    local val = Solver.newValues(model)
    return Solver.propagate(model, val, level, { stats = stats }) and Solver.isSolved(val)
end

-- Plain backtracking on top of level-1 propagation: number of solutions,
-- capped at `limit`.
function Solver.countSolutions(model, limit)
    limit = limit or 2
    local count = 0
    local function search(val)
        if not Solver.propagate(model, val, 1) then return end
        local x
        for i = 1, model.ncells do
            if val[i] == -1 then x = i; break end
        end
        if not x then count = count + 1; return end
        for _, v in ipairs({ 1, 0 }) do
            local t = copy(val)
            t[x] = v
            search(t)
            if count >= limit then return end
        end
    end
    search(Solver.newValues(model))
    return count
end

return Solver
