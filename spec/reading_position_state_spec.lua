require("busted.runner")()

local State = require("lua/lib/reading_position_state")

local function observation(engine, position, percent, at, event, explicit, status)
    return {
        engine = engine,
        position_id = position,
        percent = percent,
        observed_at = at,
        session_id = "session-1",
        event_id = event,
        explicit = explicit == true,
        status = status or "reading",
    }
end

describe("ReadingPositionState", function()
    local state

    before_each(function()
        state = State.new()
        assert.is_true(State.beginSession(state, "session-1", 100, "initial"))
    end)

    it("models exact and display observations separately", function()
        assert.is_true(State.observe(state,
            observation("koreader_live", "/body/p[1].4", 40, 101, "kr-live", true)))
        assert.is_true(State.observe(state,
            observation("koreader_persisted", "/body/p[1].2", 39, 100, "kr-disk", false)))
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAA", 38, 100, "native", false)))
        assert.is_true(State.observe(state,
            observation("shelf", nil, 38, 100, "shelf", false)))
        assert.is_true(State.observe(state,
            observation("goodreads", nil, 37, 100, "goodreads", false)))
        assert.equals(5, (function()
            local count = 0
            for _ in pairs(state.observations) do count = count + 1 end
            return count
        end)())
    end)

    it("never lets shelf or Goodreads choose an exact page", function()
        assert.is_true(State.observe(state,
            observation("shelf", nil, 90, 120, "shelf", false)))
        assert.is_true(State.observe(state,
            observation("goodreads", nil, 91, 121, "goodreads", false)))
        assert.equals("display_only",
            State.resolve(state, { "shelf", "goodreads" }, "native").action)
    end)

    it("preserves a newer intentional rewind instead of highest percent", function()
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAA", 80, 110, "native", false)))
        assert.is_true(State.observe(state,
            observation("koreader_live", "/body/p[2].1", 35, 120, "rewind", true)))
        local decision = State.resolve(
            state, { "native", "koreader_live" }, "native")
        assert.equals("apply", decision.action)
        assert.equals("koreader_live", decision.winner.engine)
        assert.equals("rewind", decision.direction)
    end)

    it("uses explicit intent as an equal-time tiebreak", function()
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAA", 60, 120, "native", false)))
        assert.is_true(State.observe(state,
            observation("koreader_live", "/body/p[3].1", 55, 120, "local", true)))
        local decision = State.resolve(
            state, { "native", "koreader_live" }, "koreader_persisted")
        assert.equals("koreader_live", decision.winner.engine)
    end)

    it("requires a promptable conflict for equal-time equal-intent disagreement", function()
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAA", 60, 120, "native", false)))
        assert.is_true(State.observe(state,
            observation("koreader_persisted", "/body/p[3].1", 55, 120, "local", false)))
        local decision = State.resolve(
            state, { "native", "koreader_persisted" }, "koreader_live")
        assert.equals("conflict", decision.action)
        assert.equals("equal_time_exact_conflict", decision.reason)
    end)

    it("deduplicates retries and rejects event id reuse", function()
        local item = observation("native", "AXMEAAANAAAA", 60, 120, "event-1", false)
        assert.is_true(State.observe(state, item))
        local ok, detail = State.observe(state, item)
        assert.is_true(ok)
        assert.equals("duplicate", detail)
        local changed = observation("native", "AXMEAAANAAAB", 61, 120, "event-1", false)
        ok, detail = State.observe(state, changed)
        assert.is_false(ok)
        assert.equals("event_id_reused", detail)
    end)

    it("serializes rapid same-second events in arrival order", function()
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAA", 60, 120, "event-1", false)))
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAB", 61, 120, "event-2", false)))
        assert.equals("AXMEAAANAAAB", state.observations.native.position_id)
        assert.equals(2, state.observations.native.sequence)
    end)

    it("bounds the retry journal without losing the latest observation", function()
        for index = 1, 80 do
            assert.is_true(State.observe(state, observation(
                "native", "AXMEAAAN" .. string.format("%04d", index),
                index, 100 + index, "event-" .. tostring(index), false)))
        end
        local count = 0
        for _ in pairs(state.seen_events) do count = count + 1 end
        assert.equals(64, count)
        assert.equals(64, #state.seen_order)
        assert.is_nil(state.seen_events["event-1"])
        assert.is_not_nil(state.seen_events["event-80"])
        assert.equals("AXMEAAAN0080", state.observations.native.position_id)
        assert.is_true(State.isValid(state))
    end)

    it("rejects malformed persisted sessions and acknowledgements", function()
        state.current_session.ordinal = "one"
        assert.is_false(State.isValid(state))
        state.current_session.ordinal = 1
        state.acknowledged = {
            position_id = "AXMEAAANAAAA",
            percent = 50,
            source_engine = "native",
            destination_engine = "koreader_live",
            session_id = "session-1",
            acknowledged_at = "later",
        }
        assert.is_false(State.isValid(state))
    end)

    it("rejects delayed events from an earlier session", function()
        assert.is_true(State.beginSession(state, "session-2", 200, "resume"))
        local delayed = observation("native", "AXMEAAANAAAA", 60, 210, "old", false)
        local ok, detail = State.observe(state, delayed)
        assert.is_false(ok)
        assert.equals("invalid_observation", detail)
    end)

    it("starts a bounded reread generation only after explicit post-completion rewind", function()
        assert.is_true(State.observe(state,
            observation("koreader_live", "/body/end", 100, 120, "complete", true, "complete")))
        local rewind = observation(
            "koreader_live", "/body/start", 5, 130, "reread", true, "reading")
        assert.is_true(State.shouldBeginReread(state, rewind))
        assert.is_true(State.beginSession(state, "session-2", 130, "reread"))
        assert.equals(2, state.current_session.ordinal)
        assert.equals(1, #state.session_history)
    end)

    it("does not misclassify ordinary incomplete rewinds as rereads", function()
        local rewind = observation(
            "koreader_live", "/body/start", 5, 130, "rewind", true, "reading")
        assert.is_false(State.shouldBeginReread(state, rewind))
    end)

    it("waits for destination readback after an acknowledged write", function()
        local source = observation(
            "koreader_live", "/body/p[4].1", 45, 120, "local", true)
        assert.is_true(State.observe(state, source))
        assert.is_true(State.observe(state,
            observation("native", "AXMEAAANAAAA", 40, 110, "native", false)))
        assert.is_true(State.acknowledge(state, source, "native", 121))
        local decision = State.resolve(
            state, { "koreader_live" }, "native")
        assert.equals("await_destination_readback", decision.action)
    end)

    it("becomes a no-op after exact destination readback", function()
        local source = observation(
            "koreader_live", "/body/p[4].1", 45, 120, "local", true)
        assert.is_true(State.observe(state, source))
        assert.is_true(State.observe(state,
            observation("native", "/body/p[4].1", 45, 122, "readback", false)))
        local decision = State.resolve(
            state, { "koreader_live" }, "native")
        assert.equals("no_op", decision.action)
    end)

    it("bounds completed session history", function()
        for index = 2, 12 do
            assert.is_true(State.beginSession(
                state, "session-" .. tostring(index), 100 + index, "resume"))
        end
        assert.equals(8, #state.session_history)
        assert.equals(12, state.current_session.ordinal)
    end)

    it("rejects exact positions from display-only engines", function()
        local invalid = observation(
            "shelf", "AXMEAAANAAAA", 40, 110, "shelf", false)
        local ok, detail = State.observe(state, invalid)
        assert.is_false(ok)
        assert.equals("display_source_cannot_claim_exact_position", detail)
    end)
end)
