-- Text-free per-book reading-position state and conflict resolution.
--
-- Percentages are display hints, never ordering keys. Exact page movement is
-- selected from session-scoped observations by event time, explicit intent,
-- and acknowledgement state. This preserves intentional rewinds and prevents
-- stale shelf/Goodreads echoes from moving either reader.

local ReadingPositionState = {}

local SCHEMA_VERSION = 1
local MAX_SESSIONS = 8
local EXACT_ENGINES = {
    koreader_live = true,
    koreader_persisted = true,
    native = true,
}
local DISPLAY_ENGINES = {
    shelf = true,
    goodreads = true,
}
local ALL_ENGINES = {
    koreader_live = true,
    koreader_persisted = true,
    native = true,
    shelf = true,
    goodreads = true,
}
local SESSION_REASONS = {
    initial = true,
    resume = true,
    reread = true,
    manual = true,
    import = true,
}
local STATUSES = {
    unread = true,
    reading = true,
    complete = true,
    dnf = true,
}

local function safeId(value, maximum)
    return type(value) == "string"
        and #value >= 1
        and #value <= maximum
        and value:match("^[A-Za-z0-9._-]+$") ~= nil
end

local function safePosition(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 1024
        and value:find("[\r\n%z]") == nil
end

local function wholeTimestamp(value)
    return type(value) == "number"
        and value >= 0
        and value == math.floor(value)
end

local function validPercent(value)
    return type(value) == "number" and value >= 0 and value <= 100
end

local function shallowCopy(value)
    local copy = {}
    for key, item in pairs(value or {}) do copy[key] = item end
    return copy
end

local function sameObservation(left, right)
    if not left or not right then return false end
    for _, key in ipairs({
        "engine", "position_id", "percent", "observed_at", "session_id",
        "session_ordinal", "event_id", "explicit", "status",
    }) do
        if left[key] ~= right[key] then return false end
    end
    return true
end

local function currentSession(state)
    return type(state) == "table" and state.current_session or nil
end

function ReadingPositionState.new()
    return {
        version = SCHEMA_VERSION,
        current_session = nil,
        session_history = {},
        observations = {},
        seen_events = {},
        acknowledged = nil,
        last_decision = nil,
    }
end

function ReadingPositionState.isValid(state)
    return type(state) == "table"
        and state.version == SCHEMA_VERSION
        and type(state.observations) == "table"
        and type(state.seen_events) == "table"
        and type(state.session_history) == "table"
end

function ReadingPositionState.beginSession(state, session_id, started_at, reason)
    if not ReadingPositionState.isValid(state)
        or not safeId(session_id, 64)
        or not wholeTimestamp(started_at)
        or not SESSION_REASONS[reason]
    then
        return false, "invalid_session"
    end
    local current = currentSession(state)
    if current and current.id == session_id then
        return true, "duplicate"
    end
    if current and started_at < current.started_at then
        return false, "stale_session"
    end
    if current then
        table.insert(state.session_history, {
            id = current.id,
            ordinal = current.ordinal,
            started_at = current.started_at,
            completed_at = current.completed_at,
            reason = current.reason,
        })
        while #state.session_history > MAX_SESSIONS do
            table.remove(state.session_history, 1)
        end
    end
    state.current_session = {
        id = session_id,
        ordinal = current and current.ordinal + 1 or 1,
        started_at = started_at,
        reason = reason,
    }
    state.observations = {}
    state.seen_events = {}
    state.acknowledged = nil
    state.last_decision = nil
    return true, "started"
end

local function validateObservation(state, observation)
    local session = currentSession(state)
    if not ReadingPositionState.isValid(state)
        or not session
        or type(observation) ~= "table"
        or not ALL_ENGINES[observation.engine]
        or not safeId(observation.event_id, 96)
        or not safeId(observation.session_id, 64)
        or observation.session_id ~= session.id
        or not wholeTimestamp(observation.observed_at)
        or observation.observed_at < session.started_at
        or not validPercent(observation.percent)
        or type(observation.explicit) ~= "boolean"
        or not STATUSES[observation.status]
    then
        return false, "invalid_observation"
    end
    if EXACT_ENGINES[observation.engine] and not safePosition(observation.position_id) then
        return false, "exact_position_required"
    end
    if DISPLAY_ENGINES[observation.engine] and observation.position_id ~= nil then
        return false, "display_source_cannot_claim_exact_position"
    end
    return true
end

function ReadingPositionState.observe(state, observation)
    local valid, detail = validateObservation(state, observation)
    if not valid then return false, detail end
    local session = currentSession(state)
    local stored = shallowCopy(observation)
    stored.session_ordinal = session.ordinal
    local previous_event = state.seen_events[observation.event_id]
    if previous_event then
        if sameObservation(previous_event, stored) then
            return true, "duplicate"
        end
        return false, "event_id_reused"
    end
    local previous = state.observations[stored.engine]
    if previous and stored.observed_at < previous.observed_at then
        return false, "stale_observation"
    end
    if previous and stored.observed_at == previous.observed_at
        and not sameObservation(previous, stored)
    then
        return false, "same_engine_time_conflict"
    end
    state.observations[stored.engine] = stored
    state.seen_events[stored.event_id] = shallowCopy(stored)
    if stored.status == "complete" then
        session.completed_at = math.max(session.completed_at or 0, stored.observed_at)
    end
    return true, "recorded"
end

function ReadingPositionState.shouldBeginReread(state, observation)
    local session = currentSession(state)
    return session ~= nil
        and session.completed_at ~= nil
        and type(observation) == "table"
        and observation.explicit == true
        and validPercent(observation.percent)
        and observation.percent < 90
        and wholeTimestamp(observation.observed_at)
        and observation.observed_at > session.completed_at
end

local function exactCandidates(state, engines)
    local candidates = {}
    for _, engine in ipairs(engines or {}) do
        local observation = state.observations[engine]
        if EXACT_ENGINES[engine] and observation then
            table.insert(candidates, observation)
        end
    end
    return candidates
end

local function samePosition(left, right)
    return left and right and left.position_id == right.position_id
end

function ReadingPositionState.resolve(state, source_engines, destination_engine)
    if not ReadingPositionState.isValid(state)
        or not EXACT_ENGINES[destination_engine]
    then
        return { action = "invalid" }
    end
    local candidates = exactCandidates(state, source_engines)
    if #candidates == 0 then
        local has_display = false
        for _, engine in ipairs(source_engines or {}) do
            has_display = has_display or (DISPLAY_ENGINES[engine]
                and state.observations[engine] ~= nil)
        end
        return { action = has_display and "display_only" or "insufficient" }
    end
    table.sort(candidates, function(left, right)
        if left.observed_at ~= right.observed_at then
            return left.observed_at > right.observed_at
        end
        if left.explicit ~= right.explicit then return left.explicit end
        return left.engine < right.engine
    end)
    local winner = candidates[1]
    if candidates[2]
        and candidates[2].observed_at == winner.observed_at
        and candidates[2].explicit == winner.explicit
        and not samePosition(candidates[2], winner)
    then
        return {
            action = "conflict",
            reason = "equal_time_exact_conflict",
            observed_at = winner.observed_at,
        }
    end
    local destination = state.observations[destination_engine]
    if samePosition(destination, winner) then
        return { action = "no_op", winner = shallowCopy(winner) }
    end
    local acknowledgement = state.acknowledged
    if acknowledgement
        and acknowledgement.session_id == winner.session_id
        and acknowledgement.position_id == winner.position_id
        and destination
        and destination.observed_at <= acknowledgement.acknowledged_at
    then
        return { action = "await_destination_readback", winner = shallowCopy(winner) }
    end
    local direction = "unknown"
    if destination and validPercent(destination.percent) then
        if winner.percent > destination.percent then direction = "forward"
        elseif winner.percent < destination.percent then direction = "rewind"
        else direction = "same_percent" end
    end
    local decision = {
        action = "apply",
        winner = shallowCopy(winner),
        destination_engine = destination_engine,
        direction = direction,
        reason = winner.explicit and "newest_explicit_event" or "newest_exact_event",
    }
    state.last_decision = {
        action = decision.action,
        source_engine = winner.engine,
        destination_engine = destination_engine,
        direction = direction,
        decided_at = winner.observed_at,
        session_id = winner.session_id,
    }
    return decision
end

function ReadingPositionState.acknowledge(state, observation, destination_engine, acknowledged_at)
    if not ReadingPositionState.isValid(state)
        or type(observation) ~= "table"
        or not EXACT_ENGINES[observation.engine]
        or not EXACT_ENGINES[destination_engine]
        or not safePosition(observation.position_id)
        or observation.session_id ~= (currentSession(state) or {}).id
        or not wholeTimestamp(acknowledged_at)
        or acknowledged_at < observation.observed_at
    then
        return false, "invalid_acknowledgement"
    end
    state.acknowledged = {
        position_id = observation.position_id,
        percent = observation.percent,
        source_engine = observation.engine,
        destination_engine = destination_engine,
        session_id = observation.session_id,
        acknowledged_at = acknowledged_at,
    }
    return true
end

return ReadingPositionState
