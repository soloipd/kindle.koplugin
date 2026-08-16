require("busted.runner")()

local State = require("lua/lib/reading_position_state")

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for key, item in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(item, seen)
    end
    return copy
end

local function count(value)
    local total = 0
    for _ in pairs(value) do total = total + 1 end
    return total
end

local function runSimulation()
    local state = State.new()
    assert.is_true(State.beginSession(state, "stress-session", 100, "initial"))
    local engines = {
        "native", "koreader_live", "shelf", "goodreads", "koreader_persisted",
    }
    local last_event
    for index = 1, 5000 do
        local engine = engines[((index - 1) % #engines) + 1]
        local exact = engine ~= "shelf" and engine ~= "goodreads"
        local item = {
            engine = engine,
            position_id = exact and string.format("P%011d", index) or nil,
            percent = index % 101,
            observed_at = 100 + math.floor(index / 10),
            session_id = "stress-session",
            event_id = "event-" .. tostring(index),
            explicit = engine == "koreader_live",
            status = "reading",
        }
        assert.is_true(State.observe(state, item))
        last_event = item
        if index == 2500 then
            -- Equivalent to reloading the text-free table from settings after
            -- a KOReader crash or reboot.
            state = deepCopy(state)
            assert.is_true(State.isValid(state))
        end
    end
    assert.is_true(State.observe(state, last_event))
    return state, State.resolve(state, {
        "native", "koreader_live", "koreader_persisted",
    }, "native")
end

describe("reading position stress", function()
    it("is bounded, restart-safe, and deterministic across rapid events", function()
        local first, first_decision = runSimulation()
        local second, second_decision = runSimulation()

        assert.is_true(State.isValid(first))
        assert.equals(64, #first.seen_order)
        assert.equals(64, count(first.seen_events))
        assert.equals(5, count(first.observations))
        assert.same(first.observations, second.observations)
        assert.same(first_decision, second_decision)
        assert.equals("apply", first_decision.action)
        assert.equals("koreader_persisted", first_decision.winner.engine)
        assert.is_nil(first.title)
        assert.is_nil(first.source_path)
        assert.is_nil(first.annotation_text)
    end)
end)
