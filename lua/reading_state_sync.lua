--- Reading State Synchronization for Kindle virtual library.
--- Syncs reading progress between KOReader and Kindle's authoritative ReaderSDK
--- state, then mirrors the accepted value to cc.db for shelf display.
--- Adapted from kobo.koplugin/src/reading_state_sync.lua.
---
--- Kindle stores progress in /var/local/cc.db, Entries table:
---   p_percentFinished (float 0-100), p_lastAccess (Unix timestamp), p_readState (int)
---
--- KOReader stores progress in doc_settings:
---   percent_finished (float 0-1), summary.status (string)

local DocSettings = require("docsettings")
local Event = require("ui/event")
local ReadHistory = require("readhistory")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template
local BookList = require("ui/widget/booklist")
local Trapper = require("ui/trapper")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local KindleStateReader = require("lua/lib/kindle_state_reader")
local KindleStateWriter = require("lua/lib/kindle_state_writer")
local SyncDecisionMaker = require("lua/lib/sync_decision_maker")
local ReadingPositionState = require("lua/lib/reading_position_state")

local ReadingStateSync = {}
local GOODREADS_PROGRESS_DIR =
    "/mnt/us/koreader/settings/goodreads_native_progress"

---
--- Extracts book cdeKey (ASIN or PDOC hash) from virtual path.
--- @param virtual_path string: Virtual path in format KINDLE_VIRTUAL://BOOKID/filename.
--- @return string|nil: Book cdeKey if extracted.
local function extractCdeKeyFromVirtualPath(virtual_path)
    if not virtual_path or not virtual_path:match("^KINDLE_VIRTUAL://") then
        return nil
    end

    -- Extract book ID from virtual path
    local book_id = virtual_path:match("^KINDLE_VIRTUAL://([^/]+)/")
    if book_id then
        logger.dbg("KindlePlugin: extracted a virtual book identifier")
        return book_id
    end

    return nil
end

---
--- Extracts ASIN from a file path like .../Throne of Glass_B007N6JEII.kfx
--- @param file_path string: Real file path on device.
--- @return string|nil: ASIN if found.
local function extractCdeKeyFromPath(file_path)
    if not file_path then
        return nil
    end
    -- Match _B007N6JEII.kfx (ASIN) or _5AFAFAA13FFE43ECBE78F0FF3761814C.kfx (PDOC hash)
    -- The cdeKey is always the last segment before the extension after underscore
    local key = file_path:match("_([A-Z0-9]+)%.%w+$")
    if key and #key >= 10 then
        logger.dbg("KindlePlugin: extracted a catalog identifier from a path")
        return key
    end
    return nil
end

---
--- Extracts book cdeKey from doc_path in doc_settings.
--- @param doc_settings table: Document settings instance.
--- @return string|nil: Book cdeKey if extracted.
local function extractCdeKeyFromDocPath(doc_settings)
    if not doc_settings or not doc_settings.data or not doc_settings.data.doc_path then
        return nil
    end

    local doc_path = doc_settings.data.doc_path
    -- Try extracting from virtual path
    local book_id = extractCdeKeyFromVirtualPath(doc_path)
    if book_id then
        return book_id
    end

    -- Try extracting ASIN from filename pattern like _B007N6JEII.kfx
    local asin = extractCdeKeyFromPath(doc_path)
    if asin then
        logger.dbg("KindlePlugin: extracted a catalog identifier from document settings")
        return asin
    end

    return nil
end

---
--- Creates a new ReadingStateSync instance.
--- @return table: A new ReadingStateSync instance.
function ReadingStateSync:new(helper_client)
    local o = {
        enabled = false,
        plugin = nil,
        sync_direction = nil,
        helper_client = helper_client,
        goodreads_progress_dir = GOODREADS_PROGRESS_DIR,
        -- KOReader has one foreground reader. Keep only the newest staged
        -- destination readback so rapid or failed opens remain bounded.
        pending_open_verification = nil,
        pending_open_sequence = 0,
        -- Exact, memory-only three-way merge base for the current reader
        -- session. Both coordinates use Kindle's canonical KFX representation;
        -- no book or annotation text is retained here.
        open_session_baseline = nil,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

---
--- Sets plugin instance and sync direction constants.
--- @param plugin table: Main plugin instance with settings.
--- @param sync_direction table: SYNC_DIRECTION constants.
function ReadingStateSync:setPlugin(plugin, sync_direction)
    self.plugin = plugin
    self.sync_direction = sync_direction
end

--- Provides access to the virtual-library mapping and its cached EPUBs.
function ReadingStateSync:setVirtualLibrary(virtual_library)
    self.virtual_library = virtual_library
end

local function receiptAsin(cde_key, source_path)
    local asin = cde_key
    if not asin or not asin:match("^B[A-Z0-9]+$") then
        asin = extractCdeKeyFromPath(source_path)
    end
    if asin and #asin == 10 and asin:match("^B[A-Z0-9]+$") then
        return asin
    end
    return nil
end

local function validNativePosition(position)
    return type(position) == "table"
        and type(position.long) == "string"
        and position.long:match("^[A-Za-z0-9+/]+$")
        and #position.long == 12
        and type(position.pid) == "number"
        and position.pid >= 0
        and position.pid == math.floor(position.pid)
end

local function canonicalPositionId(position)
    if not validNativePosition(position) then return nil end
    return position.long .. ":" .. tostring(position.pid)
end

local function boundedPercent(value, maximum)
    local percent = tonumber(value)
    if not percent or percent ~= percent or percent < 0 or percent > maximum then
        return nil
    end
    return percent
end

local function validPositionReceipt(receipt)
    if receipt == nil then return true end
    return validNativePosition(receipt)
        and (receipt.percent == nil
            or boundedPercent(receipt.percent, 100) ~= nil)
        and (receipt.direction == nil
            or receipt.direction == "push"
            or receipt.direction == "pull"
            or receipt.direction == "bootstrap")
        and (receipt.synced_at == nil
            or (type(receipt.synced_at) == "number"
                and receipt.synced_at >= 0
                and receipt.synced_at == math.floor(receipt.synced_at)))
end

local function validXPointer(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= 16384
        and value:find("[\r\n%z]") == nil
end

local function comparableXPointer(value)
    if not validXPointer(value) then return nil end
    -- KOReader may spell the first text node as either text() or text()[1].
    -- They identify the same node, so do not start the packaged Python helper
    -- merely to prove this harmless normalization difference.
    return (value:gsub("text%(%)%[1%]", "text()"))
end

local function sameReceiptPosition(receipt, position)
    return receipt and validNativePosition(position)
        and receipt.long == position.long
        and receipt.pid == position.pid
end

local function copyNativePosition(position)
    if not validNativePosition(position) then return nil end
    return {
        long = position.long,
        pid = position.pid,
        percent = boundedPercent(position.percent, 100),
    }
end

--- Remember what each renderer pointed at when this KOReader session opened.
--- A close can then distinguish a real local page turn from a native page turn
--- even when the last durable global receipt predates both positions.
function ReadingStateSync:stageOpenSessionBaseline(
    cde_key, source_path, epub_path, native_position, local_position
)
    local asin = receiptAsin(cde_key, source_path)
    local native = copyNativePosition(native_position)
    if not asin or type(source_path) ~= "string"
        or type(epub_path) ~= "string" or not epub_path:match("%.epub$")
        or not native
    then
        self.open_session_baseline = nil
        return false
    end
    self.open_session_baseline = {
        asin = asin,
        source_path = source_path,
        epub_path = epub_path,
        native = native,
        local_position = copyNativePosition(local_position),
    }
    return self.open_session_baseline.local_position ~= nil
end

function ReadingStateSync:updateOpenSessionBaseline(
    epub_path, native_position, local_position
)
    local baseline = self.open_session_baseline
    if not baseline or baseline.epub_path ~= epub_path then return false end
    if native_position ~= nil then
        local native = copyNativePosition(native_position)
        if not native then return false end
        baseline.native = native
    end
    if local_position ~= nil then
        local local_copy = copyNativePosition(local_position)
        if not local_copy then return false end
        baseline.local_position = local_copy
    end
    return baseline.local_position ~= nil
end

function ReadingStateSync:discardOpenSessionBaseline(epub_path)
    local baseline = self.open_session_baseline
    if baseline and (epub_path == nil or baseline.epub_path == epub_path) then
        self.open_session_baseline = nil
        return true
    end
    return false
end

function ReadingStateSync:getOpenSessionBaseline(
    cde_key, source_path, epub_path
)
    local baseline = self.open_session_baseline
    local asin = receiptAsin(cde_key, source_path)
    if not baseline or baseline.asin ~= asin
        or baseline.source_path ~= source_path
        or baseline.epub_path ~= epub_path
        or not validNativePosition(baseline.native)
        or not validNativePosition(baseline.local_position)
    then
        return nil
    end
    return {
        native = copyNativePosition(baseline.native),
        local_position = copyNativePosition(baseline.local_position),
    }
end

local function resolveSessionCloseBaseline(baseline, local_position, native_position)
    if type(baseline) ~= "table"
        or not validNativePosition(baseline.native)
        or not validNativePosition(baseline.local_position)
        or not validNativePosition(local_position)
        or not validNativePosition(native_position)
    then
        return nil
    end
    if sameReceiptPosition(local_position, native_position) then
        return { action = "no_op", reason = "renderers_already_equal" }
    end
    local local_changed = not sameReceiptPosition(
        local_position, baseline.local_position)
    local native_changed = not sameReceiptPosition(
        native_position, baseline.native)
    if local_changed and not native_changed then
        return {
            action = "apply",
            reason = "only_koreader_changed_during_session",
            winner = { engine = "koreader_live" },
        }
    end
    if not local_changed and native_changed then
        return { action = "no_op", reason = "only_native_changed_during_session" }
    end
    if local_changed and native_changed then
        return { action = "conflict", reason = "both_changed_during_session" }
    end
    return { action = "no_op", reason = "no_session_position_change" }
end

local function liveXPointerMatches(
    sync, epub_path, actual_xpointer, expected_xpointer, native_position
)
    if not validXPointer(actual_xpointer) then return false end
    if comparableXPointer(actual_xpointer)
        == comparableXPointer(expected_xpointer)
    then
        return true
    end
    if not sync.helper_client
        or type(sync.helper_client.translatePosition) ~= "function"
    then
        return false
    end
    local ok, translated = pcall(
        sync.helper_client.translatePosition,
        sync.helper_client,
        epub_path,
        actual_xpointer
    )
    return ok
        and canonicalPositionId(translated) == canonicalPositionId(native_position)
end

--- Return the last exact native position reconciled by this plugin.
--- Coordinates contain no book text and are stored in KOReader's atomic
--- settings file, so they survive restarts without creating another sidecar.
function ReadingStateSync:getPositionReceipt(cde_key, source_path)
    local asin = receiptAsin(cde_key, source_path)
    local receipts = self.plugin and self.plugin.settings
        and self.plugin.settings.position_sync_receipts
    local receipt = asin and type(receipts) == "table" and receipts[asin]
    if not validNativePosition(receipt) then
        return nil
    end
    return receipt
end

local function normalizedPositionStatus(status)
    if status == "complete" or status == "finished" then return "complete" end
    if status == "abandoned" or status == "dnf" then return "dnf" end
    if status == "unread" or status == "new" then return "unread" end
    return "reading"
end

local function modelEventId(state, engine)
    local sequence = (tonumber(state.model_event_sequence) or 0) + 1
    state.model_event_sequence = sequence
    return string.format("%s-%d-%d", engine,
        state.current_session.ordinal, sequence)
end

local function storeModelObservation(
    state, engine, position_id, percent, observed_at, explicit, status
)
    local previous = state.observations[engine]
    local normalized_percent = tonumber(percent)
    if not normalized_percent then normalized_percent = 0 end
    normalized_percent = math.max(0, math.min(100, normalized_percent))
    local normalized_status = normalizedPositionStatus(status)
    if previous
        and previous.position_id == position_id
        and math.abs(previous.percent - normalized_percent) < 0.0001
        and previous.status == normalized_status
    then
        return previous, false
    end
    if position_id ~= nil and previous and previous.position_id == position_id then
        local changed = math.abs(previous.percent - normalized_percent) >= 0.0001
            or previous.status ~= normalized_status
        if changed then
            -- Percentage and status are display/state hints. When the exact
            -- coordinate did not move, update those hints without inventing a
            -- newer page event that could defeat a real move in another reader.
            previous.percent = normalized_percent
            previous.status = normalized_status
            if normalized_status == "complete" then
                local completed_at = math.max(0,
                    math.floor(tonumber(observed_at) or os.time()))
                state.current_session.completed_at = math.max(
                    state.current_session.completed_at or 0, completed_at)
            end
        end
        return previous, changed
    end
    local at = tonumber(observed_at) or os.time()
    at = math.max(0, math.floor(at))
    local observation = {
        engine = engine,
        position_id = position_id,
        percent = normalized_percent,
        observed_at = at,
        session_id = state.current_session.id,
        event_id = modelEventId(state, engine),
        explicit = explicit == true,
        status = normalized_status,
    }
    if engine == "koreader_live"
        and ReadingPositionState.shouldBeginReread(state, observation)
    then
        local next_ordinal = state.current_session.ordinal + 1
        local session_id = string.format("s-%d-%d", at, next_ordinal)
        local started = ReadingPositionState.beginSession(
            state, session_id, at, "reread")
        if not started then return nil, false end
        observation.session_id = session_id
        observation.event_id = modelEventId(state, engine)
    end
    local recorded = ReadingPositionState.observe(state, observation)
    if not recorded then return nil, false end
    return state.observations[engine], true
end

function ReadingStateSync:getPositionState(cde_key, source_path)
    local asin = receiptAsin(cde_key, source_path)
    if not asin or not self.plugin or type(self.plugin.settings) ~= "table" then
        return nil
    end
    local settings = self.plugin.settings
    if type(settings.reading_position_states) ~= "table" then
        settings.reading_position_states = {}
    end
    local state = settings.reading_position_states[asin]
    if not ReadingPositionState.isValid(state) then
        state = ReadingPositionState.new()
        settings.reading_position_states[asin] = state
    end
    if not state.current_session then
        local receipt = self:getPositionReceipt(cde_key, source_path)
        local started_at = receipt and tonumber(receipt.synced_at) or 0
        started_at = math.max(0, math.floor(started_at or 0))
        ReadingPositionState.beginSession(
            state, string.format("s-%d-1", started_at), started_at,
            receipt and "import" or "initial")
        if receipt then
            local source = receipt.direction == "push"
                and "koreader_live" or "native"
            local destination = receipt.direction == "push"
                and "native" or "koreader_persisted"
            local position_id = canonicalPositionId(receipt)
            local first = storeModelObservation(
                state, source, position_id, receipt.percent,
                started_at, false, "reading")
            storeModelObservation(
                state, destination, position_id, receipt.percent,
                started_at, false, "reading")
            if first then
                ReadingPositionState.acknowledge(
                    state, first, destination, started_at)
            end
        end
    end
    return state
end

function ReadingStateSync:isPositionSourceOfTruthEnabled()
    return self.plugin ~= nil
        and type(self.plugin.settings) == "table"
        and self.plugin.settings.enable_position_source_of_truth == true
end

--- Stage a Kindle-to-KOReader pull until the opened renderer confirms it.
--- The record is memory-only, text-free, and latest-wins.
function ReadingStateSync:stageOpenPositionVerification(
    cde_key, source_path, epub_path, expected_xpointer, native_position,
    kindle_state, direction, kr_timestamp
)
    local asin = receiptAsin(cde_key, source_path)
    if not self:isPositionSourceOfTruthEnabled()
        or not asin
        or type(epub_path) ~= "string"
        or not epub_path:match("%.epub$")
        or not validXPointer(expected_xpointer)
        or not validNativePosition(native_position)
    then
        return nil
    end
    self.pending_open_sequence = (self.pending_open_sequence % 2147483647) + 1
    local verification_id = self.pending_open_sequence
    local native_percent = boundedPercent(native_position.percent, 100)
        or boundedPercent(kindle_state and kindle_state.percent_read, 100)
    self.pending_open_verification = {
        id = verification_id,
        cde_key = cde_key,
        source_path = source_path,
        epub_path = epub_path,
        expected_xpointer = expected_xpointer,
        native_position = {
            long = native_position.long,
            pid = native_position.pid,
            percent = native_percent,
        },
        native_percent = native_percent,
        native_timestamp = tonumber(kindle_state and kindle_state.timestamp) or 0,
        koreader_timestamp = tonumber(kr_timestamp) or 0,
        -- Preserve KOReader's existing status vocabulary in doc settings;
        -- recordPositionReceipt normalizes it only inside the model.
        status = kindle_state and kindle_state.status or "reading",
        direction = direction == "bootstrap" and "bootstrap" or "pull",
    }
    logger.info("KindlePlugin: staged exact KOReader destination readback")
    return verification_id
end

function ReadingStateSync:discardOpenPositionVerification(epub_path)
    local pending = self.pending_open_verification
    if pending and (epub_path == nil or pending.epub_path == epub_path) then
        self.pending_open_verification = nil
        return true
    end
    return false
end

--- Confirm that ReaderRolling rendered the exact staged destination. Only a
--- successful live readback may create the pull receipt/acknowledgement.
function ReadingStateSync:verifyOpenedKOReaderPosition(
    reader, epub_path, virtual_path, verification_id
)
    local pending = self.pending_open_verification
    if not pending
        or pending.id ~= verification_id
        or pending.epub_path ~= epub_path
    then
        return false
    end
    -- Consume this exact callback once. A failed readback remains
    -- unacknowledged in the durable model and is retried on the next open.
    self.pending_open_verification = nil
    if not self:isAutomaticSyncEnabled()
        or not self:isPositionSourceOfTruthEnabled()
        or type(reader) ~= "table"
        or type(reader.document) ~= "table"
        or reader.document.file ~= epub_path
        or type(reader.doc_settings) ~= "table"
        or type(reader.rolling) ~= "table"
        or type(reader.rolling.getBookLocation) ~= "function"
        or type(reader.rolling.getLastPercent) ~= "function"
    then
        logger.warn("KindlePlugin: exact KOReader destination readback unavailable")
        self:discardOpenSessionBaseline(epub_path)
        return false
    end

    local location_ok, actual_xpointer = pcall(
        reader.rolling.getBookLocation, reader.rolling)
    local percent_ok, live_percent = pcall(
        reader.rolling.getLastPercent, reader.rolling)
    live_percent = percent_ok and boundedPercent(live_percent, 1) or nil
    if not location_ok
        or not liveXPointerMatches(
            self, epub_path, actual_xpointer,
            pending.expected_xpointer, pending.native_position)
        or not live_percent
    then
        logger.warn("KindlePlugin: live KOReader destination did not match staged position")
        self:discardOpenSessionBaseline(epub_path)
        return false
    end

    local kindle_state = {
        percent_read = pending.native_percent or 0,
        timestamp = pending.native_timestamp,
        status = pending.status,
        kindle_status = 1,
    }
    self:applyKindleStateToKOReader(
        kindle_state,
        reader.doc_settings,
        pending.koreader_timestamp,
        live_percent
    )
    reader.doc_settings:saveSetting("last_xpointer", actual_xpointer)
    if type(reader.doc_settings.flush) == "function" then
        reader.doc_settings:flush()
    end
    self:updateOpenSessionBaseline(
        epub_path, nil, pending.native_position)

    local recorded = self:recordPositionReceipt(
        pending.cde_key,
        pending.source_path,
        pending.native_position,
        pending.direction,
        pending.status,
        os.time(),
        nil,
        {
            native_percent = pending.native_percent,
            koreader_percent = live_percent * 100,
        }
    )
    if not recorded then
        logger.warn("KindlePlugin: exact KOReader destination receipt failed")
        return false
    end
    if type(virtual_path) == "string" and virtual_path ~= "" then
        local cache_ok = type(BookList.setBookInfoCache) == "function"
            and pcall(
                BookList.setBookInfoCache,
                virtual_path,
                reader.doc_settings
            )
        if not cache_ok then
            cache_ok = pcall(
                BookList.setBookInfoCacheProperty,
                virtual_path,
                "percent_finished",
                live_percent
            )
        end
        if not cache_ok then
            logger.warn("KindlePlugin: KOReader shelf cache refresh failed")
        end
    end
    logger.info("KindlePlugin: exact KOReader destination readback confirmed")
    return true
end

--- Read the last percentage that the Goodreads companion confirmed as sent.
--- The existing receipt contains one integer and its filesystem timestamp;
--- neither plugin needs access to account credentials or book text.
function ReadingStateSync:readGoodreadsProgress(cde_key, source_path)
    local asin = receiptAsin(cde_key, source_path)
    if not asin or type(self.goodreads_progress_dir) ~= "string" then
        return nil
    end
    local path = self.goodreads_progress_dir .. "/" .. asin
    local attributes = lfs.attributes(path)
    local observed_at = attributes and tonumber(attributes.modification)
    local size = attributes and tonumber(attributes.size)
    if not attributes or attributes.mode ~= "file" or not observed_at
        or not size or size ~= math.floor(size) or size < 1 or size > 4
    then
        return nil
    end
    local file = io.open(path, "rb")
    if not file then return nil end
    -- Read one byte past the largest valid receipt so a concurrent append is
    -- rejected without ever loading attacker-sized content into KOReader.
    local line = file:read(5)
    file:close()
    if type(line) ~= "string" or #line ~= size then return nil end
    if line:sub(-1) == "\n" then line = line:sub(1, -2) end
    if type(line) ~= "string" or not line:match("^%d+$") then return nil end
    local percent = tonumber(line)
    if not percent or percent < 1 or percent > 100 then return nil end
    return {
        percent = percent,
        observed_at = math.max(0, math.floor(observed_at)),
        status = percent == 100 and "complete" or "reading",
    }
end

local function saveModelIfChanged(sync, changed)
    if changed and sync.plugin and type(sync.plugin.saveSettings) == "function" then
        sync.plugin:saveSettings()
    end
end

function ReadingStateSync:observeGoodreadsPositionFact(
    state, cde_key, source_path
)
    if not self:isPositionSourceOfTruthEnabled() or not state then return false end
    local progress = self:readGoodreadsProgress(cde_key, source_path)
    if not progress then return false end
    local _, changed = storeModelObservation(
        state, "goodreads", nil, progress.percent,
        progress.observed_at, false, progress.status)
    return changed
end

function ReadingStateSync:getCanonicalKOReaderPosition(epub_path, doc_settings)
    if not self.helper_client or type(self.helper_client.translatePosition) ~= "function"
        or type(epub_path) ~= "string" or not epub_path:match("%.epub$")
        or type(doc_settings) ~= "table"
    then
        return nil
    end
    local xpointer = doc_settings:readSetting("last_xpointer")
    if type(xpointer) ~= "string" or xpointer == "" then return nil end
    local position = self.helper_client:translatePosition(epub_path, xpointer)
    if not validNativePosition(position) then return nil end
    return position
end

--- Observe all open-time facts before selecting a source. Unchanged facts do
--- not receive a fresh timestamp, so merely opening a reader cannot make stale
--- state win. A changed exact coordinate is a new event even when cc.db time is
--- stale.
function ReadingStateSync:observeOpenPositionFacts(
    cde_key, source_path, doc_settings, epub_path, kindle_state, native_position,
    kr_timestamp, local_position
)
    if not self:isPositionSourceOfTruthEnabled() then return nil end
    local state = self:getPositionState(cde_key, source_path)
    local native_id = canonicalPositionId(native_position)
    if not state or not native_id then return nil end
    local_position = validNativePosition(local_position)
        and local_position
        or self:getCanonicalKOReaderPosition(epub_path, doc_settings)
    local local_id = canonicalPositionId(local_position)
    local acknowledged_id = state.acknowledged and state.acknowledged.position_id
    local concurrent_divergence = acknowledged_id ~= nil
        and local_id ~= nil
        and native_id ~= acknowledged_id
        and local_id ~= acknowledged_id
        and native_id ~= local_id
    local now = os.time()
    local changed = false
    local previous_native = state.observations.native
    local native_at = tonumber(kindle_state and kindle_state.timestamp) or 0
    if previous_native and previous_native.position_id ~= native_id then
        native_at = now
    end
    if native_at <= 0 then native_at = now end
    local _, native_changed = storeModelObservation(
        state, "native", native_id,
        native_position.percent or (kindle_state and kindle_state.percent_read),
        native_at, false, kindle_state and kindle_state.status)
    changed = changed or native_changed
    local _, shelf_changed = storeModelObservation(
        state, "shelf", nil,
        kindle_state and kindle_state.percent_read or 0,
        tonumber(kindle_state and kindle_state.timestamp) or now,
        false, kindle_state and kindle_state.status)
    changed = changed or shelf_changed
    changed = self:observeGoodreadsPositionFact(
        state, cde_key, source_path) or changed

    if local_id then
        local summary = doc_settings:readSetting("summary") or {}
        local _, local_changed = storeModelObservation(
            state, "koreader_persisted", local_id,
            (doc_settings:readSetting("percent_finished") or 0) * 100,
            tonumber(kr_timestamp) or 0,
            false, summary.status)
        changed = changed or local_changed
    end
    local conflict_reason = concurrent_divergence
        and "both_readers_changed_since_acknowledgement" or nil
    if state.last_open_conflict ~= conflict_reason then
        state.last_open_conflict = conflict_reason
        changed = true
    end
    saveModelIfChanged(self, changed)
    if concurrent_divergence then
        -- Both exact readers moved away from the last acknowledged position.
        -- Kindle's catalog time can be stale, so inventing an ordering here
        -- would silently discard one reader's real intent. Keep both until a
        -- later explicit close or manual choice supplies a winner.
        return {
            action = "conflict",
            reason = conflict_reason,
        }
    end
    if not state.observations.koreader_persisted then return nil end
    local to_koreader = ReadingPositionState.resolve(
        state, { "native", "koreader_persisted" }, "koreader_persisted")
    if to_koreader.action == "conflict"
        or (to_koreader.action == "apply"
            and to_koreader.winner.engine == "native")
    then
        return to_koreader
    end
    local to_native = ReadingPositionState.resolve(
        state, { "native", "koreader_persisted" }, "native")
    if to_native.action == "apply"
        and to_native.winner.engine == "koreader_persisted"
    then
        return to_native
    end
    return to_koreader
end

--- Observe close-time live KOReader intent and the current native fact before
--- writing anything. A close with no local movement cannot overwrite a newer
--- native change; a real local rewind remains a newer explicit event.
function ReadingStateSync:observeClosePositionFacts(
    cde_key, source_path, doc_settings, epub_path, kindle_state, closed_at
)
    if not self:isPositionSourceOfTruthEnabled() then return nil end
    local state = self:getPositionState(cde_key, source_path)
    if not state then return nil end
    local changed = false
    local local_position = self:getCanonicalKOReaderPosition(epub_path, doc_settings)
    local local_id = canonicalPositionId(local_position)
    if local_id then
        local summary = doc_settings:readSetting("summary") or {}
        local _, local_changed = storeModelObservation(
            state, "koreader_live", local_id,
            (doc_settings:readSetting("percent_finished") or 0) * 100,
            closed_at, true, summary.status)
        changed = changed or local_changed
    end
    local native_position
    if self.helper_client and type(self.helper_client.readNativeProgress) == "function" then
        local asin = receiptAsin(cde_key, source_path)
        local native = asin and self.helper_client:readNativeProgress(asin, source_path)
        local native_id = canonicalPositionId(native)
        if native_id then
            native_position = native
            local previous_native = state.observations.native
            local native_at = tonumber(kindle_state and kindle_state.timestamp) or 0
            if previous_native and previous_native.position_id ~= native_id then
                native_at = closed_at
            end
            if native_at <= 0 then native_at = closed_at end
            local _, native_changed = storeModelObservation(
                state, "native", native_id,
                native.percent or (kindle_state and kindle_state.percent_read),
                native_at, false, kindle_state and kindle_state.status)
            changed = changed or native_changed
        end
    end
    local _, shelf_changed = storeModelObservation(
        state, "shelf", nil,
        kindle_state and kindle_state.percent_read or 0,
        tonumber(kindle_state and kindle_state.timestamp) or closed_at,
        false, kindle_state and kindle_state.status)
    changed = changed or shelf_changed
    changed = self:observeGoodreadsPositionFact(
        state, cde_key, source_path) or changed
    saveModelIfChanged(self, changed)
    local session_decision = resolveSessionCloseBaseline(
        self:getOpenSessionBaseline(cde_key, source_path, epub_path),
        local_position,
        native_position
    )
    if session_decision then
        return session_decision, local_position
    end
    if not state.observations.koreader_live or not state.observations.native then
        return nil
    end
    return ReadingPositionState.resolve(
        state, { "koreader_live", "native" }, "native"), local_position
end

--- Record an exact position only after both the authoritative LPR operation
--- and its corresponding KOReader/native state update have succeeded.
function ReadingStateSync:recordPositionReceipt(
    cde_key, source_path, position, direction, status, observed_at, model_source,
    display_percentages
)
    local asin = receiptAsin(cde_key, source_path)
    if not asin or not validNativePosition(position) or not self.plugin then
        return false
    end
    local settings = self.plugin.settings
    local state = self:isPositionSourceOfTruthEnabled()
        and self:getPositionState(cde_key, source_path) or nil
    if type(settings.position_sync_receipts) ~= "table" then
        settings.position_sync_receipts = {}
    end
    local synced_at = tonumber(observed_at) or os.time()
    synced_at = math.max(0, math.floor(synced_at))
    local native_percent = boundedPercent(
        display_percentages and display_percentages.native_percent, 100)
        or boundedPercent(position.percent, 100)
    local koreader_percent = boundedPercent(
        display_percentages and display_percentages.koreader_percent, 100)
        or native_percent
    settings.position_sync_receipts[asin] = {
        long = position.long,
        pid = position.pid,
        -- Receipt percentages always use Kindle's renderer because they repair
        -- Kindle's catalog badge. KOReader's renderer is tracked separately.
        percent = native_percent,
        direction = direction,
        synced_at = synced_at,
    }
    if state then
        local source = direction == "push" and "koreader_live" or "native"
        if direction == "push" and model_source == "koreader_persisted" then
            source = model_source
        end
        local destination = direction == "push" and "native" or "koreader_persisted"
        local position_id = canonicalPositionId(position)
        local source_percent = direction == "push"
            and koreader_percent or native_percent
        local destination_percent = direction == "push"
            and native_percent or koreader_percent
        local source_observation = storeModelObservation(
            state, source, position_id, source_percent,
            synced_at, source == "koreader_live", status)
        storeModelObservation(
            state, destination, position_id, destination_percent,
            synced_at, false, status)
        storeModelObservation(
            state, "shelf", nil, native_percent,
            synced_at, false, status)
        if source_observation then
            ReadingPositionState.acknowledge(
                state, source_observation, destination, synced_at)
        end
    end
    if type(self.plugin.saveSettings) == "function" then
        self.plugin:saveSettings()
    end
    return true
end

--- Repair only cc.db's display percentage when the exact native LPR still
--- matches the last verified receipt. This handles a stale native reader
--- process overwriting the shelf after our authoritative save without ever
--- moving either reader's actual position.
function ReadingStateSync:repairCatalogFromReceipt(
    cde_key, source_path, receipt, native_position, kindle_state
)
    if not sameReceiptPosition(receipt, native_position)
        or type(receipt.percent) ~= "number"
        or type(kindle_state) ~= "table"
        or type(kindle_state.percent_read) ~= "number"
        or math.abs(receipt.percent - kindle_state.percent_read) < 0.05
    then
        return false
    end
    logger.info("KindlePlugin: repairing stale shelf percentage from exact LPR receipt")
    return self:writeKindleState(
        cde_key,
        source_path,
        receipt.percent,
        os.time(),
        kindle_state.status or "reading"
    )
end

---
--- Checks if reading state sync is enabled.
--- @return boolean: True if sync is enabled.
function ReadingStateSync:isEnabled()
    return self.enabled
end

---
--- Sets whether reading state sync is enabled.
--- @param enabled boolean: True to enable sync.
function ReadingStateSync:setEnabled(enabled)
    self.enabled = enabled
    logger.info("KindlePlugin: Reading state sync", enabled and "enabled" or "disabled")
end

---
--- Checks if automatic sync is enabled.
--- @return boolean: True if auto-sync is enabled.
function ReadingStateSync:isAutomaticSyncEnabled()
    if not self.enabled or not self.plugin then
        return false
    end

    return self.plugin.settings.enable_auto_sync == true
end

---
--- Extracts book cdeKey from various path formats.
--- @param virtual_path string|nil: Virtual path to check.
--- @param doc_settings table|nil: Document settings instance.
--- @return string|nil: Book cdeKey if extraction succeeds.
function ReadingStateSync:extractCdeKey(virtual_path, doc_settings)
    if not virtual_path and not doc_settings then
        return nil
    end

    local cde_key = extractCdeKeyFromVirtualPath(virtual_path)
    if cde_key then
        return cde_key
    end

    cde_key = extractCdeKeyFromDocPath(doc_settings)
    if cde_key then
        return cde_key
    end

    logger.dbg("KindlePlugin: Could not extract book cdeKey from paths")
    return nil
end

---
--- Gets book title from various sources.
--- @param cde_key string: Book cdeKey.
--- @param doc_settings table: Document settings instance.
--- @return string: Book title, or "Unknown Book" if not found.
function ReadingStateSync:getBookTitle(cde_key, doc_settings)
    -- First try doc_settings
    local title = doc_settings and doc_settings:readSetting("title")
    if title and title ~= "" then
        return title
    end

    -- Try reading from cc.db
    local state = self:readKindleState(cde_key, nil)
    if state and state.title and state.title ~= "" then
        return state.title
    end

    return "Unknown Book"
end

--- Persist the exact KOReader XPointer through Kindle's native ReaderSDK.
--- The visible catalog must only be advanced after this succeeds; otherwise
--- the native reader would reopen its older LPR and overwrite the shelf value.
function ReadingStateSync:saveAuthoritativeNativePosition(
    cde_key, source_path, epub_path, doc_settings, translated_position
)
    local asin = cde_key
    if not asin or not asin:match("^B[A-Z0-9]+$") then
        asin = extractCdeKeyFromPath(source_path)
    end
    if not asin or not asin:match("^B[A-Z0-9]+$") or #asin ~= 10 then
        logger.warn("KindlePlugin: exact native progress requires a Kindle ASIN")
        return false
    end
    if not epub_path or not epub_path:match("%.epub$") then
        local doc_path = doc_settings and doc_settings.data and doc_settings.data.doc_path
        if doc_path and doc_path:match("%.epub$") then
            epub_path = doc_path
        end
    end
    local xpointer = doc_settings and doc_settings:readSetting("last_xpointer")
    if not epub_path or not xpointer then
        logger.warn("KindlePlugin: exact native progress is missing EPUB path or XPointer")
        return false
    end

    local position = translated_position
    if not validNativePosition(position) then
        position = self.helper_client:translatePosition(epub_path, xpointer)
    end
    if not position then
        logger.warn("KindlePlugin: exact native position translation failed")
        return false
    end
    local saved, _, native_percent, native_position = self.helper_client:saveNativeProgress(
        asin, source_path, position
    )
    if not saved then
        logger.warn("KindlePlugin: exact native progress save failed")
        return false
    end
    if type(native_percent) ~= "number" or native_percent < 0 or native_percent > 100 then
        logger.warn("KindlePlugin: native progress save omitted Kindle percentage")
        return false
    end
    return native_percent, native_position or {
        long = position.long,
        pid = position.pid,
        percent = native_percent,
    }
end

--- Resolve Kindle's exact local LPR back to a KOReader XPointer.
function ReadingStateSync:getAuthoritativeKindleXPointer(
    cde_key, source_path, epub_path, expected_position
)
    local asin = cde_key
    if not asin or not asin:match("^B[A-Z0-9]+$") then
        asin = extractCdeKeyFromPath(source_path)
    end
    if not asin or #asin ~= 10 or not epub_path or not epub_path:match("%.epub$") then
        return nil, "exact native position is unavailable for this book"
    end
    local native, read_error = self.helper_client:readNativeProgress(asin, source_path)
    if not native then
        return nil, read_error
    end
    if sameReceiptPosition(expected_position, native) then
        -- The ReaderSDK coordinate has not moved since our last verified
        -- reconciliation. Preserve KOReader's sidecar without paying the
        -- packaged helper's multi-second startup cost.
        return nil, nil, native, true
    end
    local translated, translate_error = self.helper_client:translateNativePosition(
        epub_path, native.long
    )
    if not translated then
        return nil, translate_error
    end
    if native.pid and translated.pid and native.pid ~= translated.pid then
        return nil, "native reverse position mismatch"
    end
    native.percent = native.percent or translated.percent
    return translated.xpointer, nil, native
end

--- Reads Kindle reading state from cc.db.
--- Tries cdeKey first, then source_path if provided.
--- @param cde_key string|nil: Book cdeKey (ASIN or hash).
--- @param source_path string|nil: Real file path on device.
--- @return table|nil: State table with percent_read, timestamp, status, kindle_status.
function ReadingStateSync:readKindleState(cde_key, source_path)
    local catalog_uuid = cde_key and cde_key:match("^cc:([%x%-]+)$")
    if catalog_uuid then
        local state = KindleStateReader.readByUuid(catalog_uuid)
        if state then
            return state
        end
    end

    -- Try by cdeKey first (avoids ICU collation issue with p_location index)
    -- Extract ASIN from source_path for virtual UUIDs and sha1 IDs.
    local actual_cde_key = cde_key
    if not actual_cde_key or catalog_uuid or actual_cde_key:match("^sha1:") then
        actual_cde_key = extractCdeKeyFromPath(source_path)
    end
    if actual_cde_key and actual_cde_key ~= "" then
        local state = KindleStateReader.readByCdeKey(actual_cde_key)
        if state then
            return state
        end
    end

    -- Fall back to source_path (may fail with ICU collation)
    if source_path and source_path ~= "" then
        return KindleStateReader.readByPath(source_path)
    end

    return nil
end

---
--- Writes KOReader reading state to Kindle cc.db.
--- Tries cdeKey first, then source_path if needed.
--- @param cde_key string|nil: Book cdeKey (ASIN or hash).
--- @param source_path string|nil: Real file path on device.
--- @param percent_read number: Progress percentage (0-100).
--- @param timestamp number: Unix timestamp of last read.
--- @param status string: KOReader status string.
--- @return boolean: True if write succeeded.
function ReadingStateSync:writeKindleState(cde_key, source_path, percent_read, timestamp, status)
    local catalog_uuid = cde_key and cde_key:match("^cc:([%x%-]+)$")
    if catalog_uuid then
        local ok = KindleStateWriter.writeByUuid(
            catalog_uuid,
            percent_read,
            timestamp,
            status
        )
        if ok then
            return true
        end
    end

    -- Try by cdeKey first (avoids ICU collation issue with p_location index)
    -- Extract ASIN from source_path for virtual UUIDs and sha1 IDs.
    local actual_cde_key = cde_key
    if not actual_cde_key or catalog_uuid or actual_cde_key:match("^sha1:") then
        actual_cde_key = extractCdeKeyFromPath(source_path)
    end
    if actual_cde_key and actual_cde_key ~= "" then
        local ok = KindleStateWriter.writeByCdeKey(actual_cde_key, percent_read, timestamp, status)
        if ok then
            return true
        end
    end

    -- Fall back to source_path (may fail with ICU collation)
    if source_path and source_path ~= "" then
        return KindleStateWriter.writeByPath(source_path, percent_read, timestamp, status)
    end

    return false
end

---
--- Evaluates whether a sync should proceed based on user settings.
--- @param is_pull_from_kindle boolean: True if pulling FROM Kindle.
--- @param is_newer boolean: True if source is newer.
--- @param sync_fn function: Callback to execute if approved.
--- @param sync_details table: Optional details for user prompt.
--- @return boolean: True if sync was executed.
function ReadingStateSync:syncIfApproved(is_pull_from_kindle, is_newer, sync_fn, sync_details)
    if not self.plugin or not self.sync_direction then
        logger.warn("KindlePlugin: Sync settings not configured, denying sync")
        return false
    end

    return SyncDecisionMaker.syncIfApproved(
        self.plugin,
        self.sync_direction,
        is_pull_from_kindle,
        is_newer,
        sync_fn,
        sync_details
    )
end

---
--- Gets KOReader timestamp from ReadHistory for a document.
--- @param doc_path string: Document path.
--- @return number: Timestamp from ReadHistory, or 0 if not found.
local function getKOReaderTimestampFromHistory(doc_path)
    if not doc_path then
        return 0
    end

    local book_id_from_virtual = nil
    if doc_path:match("^KINDLE_VIRTUAL://") then
        book_id_from_virtual = doc_path:match("^KINDLE_VIRTUAL://([^/]+)/")
    end

    for _, entry in ipairs(ReadHistory.hist) do
        if not entry.file then
            goto continue
        end

        if entry.file == doc_path then
            return entry.time or 0
        end

        if book_id_from_virtual and entry.file:match(book_id_from_virtual) then
            return entry.time or 0
        end

        ::continue::
    end

    return 0
end

---
--- Gets validated KOReader timestamp, checking for sidecar file existence.
--- @param doc_path string: Document path.
--- @return number: Valid timestamp, or 0 if no sidecar.
local function getValidatedKOReaderTimestamp(doc_path)
    local kr_timestamp = getKOReaderTimestampFromHistory(doc_path)
    if kr_timestamp == 0 then
        return 0
    end

    if not DocSettings:hasSidecarFile(doc_path) then
        logger.dbg("KindlePlugin: ReadHistory exists but no sidecar - ignoring timestamp")
        return 0
    end

    return kr_timestamp
end

---
--- Sync reading state from Kindle to KOReader (PULL).
--- @param cde_key string: Book cdeKey.
--- @param doc_settings table: Document settings instance.
--- @return boolean: True if sync was performed.
function ReadingStateSync:syncFromKindle(cde_key, source_path, doc_settings)
    if not self:isEnabled() then
        return false
    end

    local kindle_state = self:readKindleState(cde_key, source_path)
    if not kindle_state or not kindle_state.percent_read then
        return false
    end

    -- Don't pull from Kindle if the book has never been opened there
    if kindle_state.kindle_status == 0 or kindle_state.percent_read == 0 then
        logger.dbg("KindlePlugin: skipping pull for an unopened native book")
        return false
    end

    local kr_timestamp = getValidatedKOReaderTimestamp(
        doc_settings.data and doc_settings.data.doc_path
    )

    local epub_path = doc_settings.data and doc_settings.data.doc_path
    local exact_xpointer, _, native_position = self:getAuthoritativeKindleXPointer(
        cde_key, source_path, epub_path
    )
    if not exact_xpointer then
        logger.warn("KindlePlugin: exact native progress pull failed")
        return false
    end
    local receipt = self:getPositionReceipt(cde_key, source_path)
    if sameReceiptPosition(receipt, native_position) then
        self:repairCatalogFromReceipt(
            cde_key, source_path, receipt, native_position, kindle_state
        )
        logger.dbg("KindlePlugin: native LPR is already reconciled")
        return false
    end
    if not receipt and kindle_state.timestamp <= kr_timestamp then
        logger.dbg("KindlePlugin: KOReader is more recent, keeping KOReader value")
        return false
    end
    local applied = self:applyKindleStateToKOReader(
        kindle_state, doc_settings, kr_timestamp
    )
    if applied then
        doc_settings:saveSetting("last_xpointer", exact_xpointer)
        self:recordPositionReceipt(
            cde_key, source_path, native_position, "pull", kindle_state.status)
    end
    return applied
end

---
--- Applies Kindle state to KOReader settings.
--- @param kindle_state table: Kindle reading state.
--- @param doc_settings table: Document settings instance.
--- @param kr_timestamp number: KOReader timestamp for logging.
--- @param exact_koreader_percent number|nil: KOReader-rendered percentage after
---   navigating to the translated XPointer. Native Kindle percentages are not
---   interchangeable with KOReader percentages for a converted EPUB.
--- @return boolean: True if state was applied.
function ReadingStateSync:applyKindleStateToKOReader(
    kindle_state, doc_settings, kr_timestamp, exact_koreader_percent
)

    logger.info(
        "KindlePlugin: Syncing FROM Kindle - Kindle is more recent:",
        "Kindle timestamp:",
        kindle_state.timestamp,
        "vs KOReader:",
        kr_timestamp,
        "percent:",
        kindle_state.percent_read
    )

    local rendered_percent = tonumber(exact_koreader_percent)
    if rendered_percent then
        rendered_percent = math.max(0, math.min(1, rendered_percent))
        doc_settings:saveSetting("percent_finished", rendered_percent)
        doc_settings:saveSetting("last_percent", rendered_percent)
    elseif kindle_state.percent_read >= 100 then
        -- Completion is renderer-independent. For every other exact pull,
        -- preserve KOReader's own percentage until its renderer has opened the
        -- translated XPointer and can calculate the correct shelf value.
        doc_settings:saveSetting("percent_finished", 1.0)
        doc_settings:saveSetting("last_percent", 1.0)
    end

    local summary = doc_settings:readSetting("summary") or {}
    summary.status = kindle_state.status

    if kindle_state.percent_read >= 100 then
        summary.status = "complete"
    end

    doc_settings:saveSetting("summary", summary)

    return true
end

---
--- Sync reading state from KOReader to Kindle (PUSH).
--- @param cde_key string|nil: Book cdeKey.
--- @param source_path string|nil: Real file path on device.
--- @param doc_settings table: Document settings instance.
--- @return boolean: True if write succeeded.
function ReadingStateSync:syncToKindle(cde_key, source_path, doc_settings, epub_path)
    if not self:isEnabled() then
        return false
    end

    local kr_percent = doc_settings:readSetting("percent_finished") or 0
    local summary = doc_settings:readSetting("summary") or {}
    local kr_status = summary.status or "reading"
    local current_timestamp = os.time()

    logger.info(
        "KindlePlugin: Syncing TO Kindle - writing KOReader progress:",
        string.format("%.2f%%", kr_percent * 100),
        "timestamp:",
        current_timestamp
    )

    local native_percent, native_position = self:saveAuthoritativeNativePosition(
        cde_key, source_path, epub_path, doc_settings
    )
    if not native_percent then
        return false
    end
    local written = self:writeKindleState(
        cde_key, source_path, native_percent, current_timestamp, kr_status
    )
    if written then
        self:recordPositionReceipt(
            cde_key, source_path, native_position, "push", kr_status,
            current_timestamp, nil, {
                native_percent = native_percent,
                koreader_percent = kr_percent * 100,
            })
    end
    return written
end

--- Sync the native Kindle state into KOReader during an automatic open.
--- Unlike syncFromKindle(), this honors automatic-sync and all configured
--- direction choices, including an explicitly allowed older Kindle state.
function ReadingStateSync:syncFromKindleAutomatic(
    cde_key, source_path, doc_settings, epub_path, apply_live_xpointer
)
    -- Every automatic open starts a new exact three-way merge session. A
    -- failed or unmapped open must never inherit another book's baseline.
    self:discardOpenSessionBaseline()
    if self:isPositionSourceOfTruthEnabled() then
        self:discardOpenPositionVerification()
    end
    if not self:isAutomaticSyncEnabled() then
        return false
    end
    self:recoverDurableCloseProgress(false)

    local kindle_state = self:readKindleState(cde_key, source_path)
    if not kindle_state or not kindle_state.percent_read then
        return false
    end
    if kindle_state.kindle_status == 0 or kindle_state.percent_read == 0 then
        return false
    end

    local doc_path = doc_settings.data and doc_settings.data.doc_path
    local kr_timestamp = getValidatedKOReaderTimestamp(doc_path)
    local kr_percent = doc_settings:readSetting("percent_finished") or 0
    local summary = doc_settings:readSetting("summary") or {}
    local kr_status = summary.status or "reading"
    -- A shelf percentage and cc.db timestamp are not authoritative positions.
    -- Compare the exact LPR with the last successfully reconciled coordinate;
    -- this detects native-reader movement even when catalog time is stale.
    local receipt = self:getPositionReceipt(cde_key, source_path)
    local exact_xpointer, _, native_position, receipt_matches_native =
        self:getAuthoritativeKindleXPointer(
            cde_key, source_path, epub_path, receipt)
    local local_at_open = self:getCanonicalKOReaderPosition(
        epub_path, doc_settings)
    self:stageOpenSessionBaseline(
        cde_key, source_path, epub_path, native_position, local_at_open)

    local function pushPersistedWinner(model_decision)
        if not model_decision
            or not model_decision.winner
            or model_decision.winner.engine ~= "koreader_persisted"
        then
            return false
        end
        local expected_position = self:getCanonicalKOReaderPosition(
            epub_path, doc_settings)
        if canonicalPositionId(expected_position)
            ~= model_decision.winner.position_id
        then
            logger.warn("KindlePlugin: saved position changed during open reconciliation")
            return false
        end
        local sync_completed = false
        local sync_details = {
            book_title = self:getBookTitle(cde_key, doc_settings),
            source_percent = kr_percent * 100,
            dest_percent = kindle_state.percent_read,
            source_time = kr_timestamp,
            dest_time = kindle_state.timestamp,
        }
        self:syncIfApproved(false, true, function()
            local recovery_at = os.time()
            local native_percent, saved_position =
                self:saveAuthoritativeNativePosition(
                    cde_key, source_path, epub_path, doc_settings)
            if not native_percent
                or canonicalPositionId(saved_position)
                    ~= model_decision.winner.position_id
            then
                logger.warn("KindlePlugin: exact saved-position recovery failed")
                return
            end
            sync_completed = self:writeKindleState(
                cde_key, source_path, native_percent,
                recovery_at, kr_status)
            if sync_completed then
                self:updateOpenSessionBaseline(
                    epub_path, saved_position, saved_position)
                self:recordPositionReceipt(
                    cde_key, source_path, saved_position,
                    "push", kr_status, recovery_at,
                    "koreader_persisted", {
                        native_percent = native_percent,
                        koreader_percent = kr_percent * 100,
                    })
            end
        end, sync_details)
        return sync_completed
    end

    if receipt_matches_native then
        self:repairCatalogFromReceipt(
            cde_key, source_path, receipt, native_position, kindle_state)
        local model_decision = self:observeOpenPositionFacts(
            cde_key, source_path, doc_settings, epub_path,
            kindle_state, native_position, kr_timestamp, local_at_open)
        if model_decision and model_decision.action == "conflict" then
            logger.warn("KindlePlugin: equal-time exact position conflict; keeping KOReader")
            return false
        end
        if model_decision and model_decision.action == "apply"
            and model_decision.winner
            and model_decision.winner.engine == "koreader_persisted"
        then
            return pushPersistedWinner(model_decision)
        end
        logger.info("KindlePlugin: native LPR matches receipt; skipped coordinate translation")
        return false
    end
    if not exact_xpointer then
        logger.warn("KindlePlugin: exact native progress pull failed")
        return false
    end
    local pending_verification_id
    local function finishPull(destination_changed, direction)
        local live_percent
        local live_xpointer = exact_xpointer
        if apply_live_xpointer then
            local ok, applied = pcall(apply_live_xpointer, exact_xpointer)
            if not ok or applied == false then
                logger.warn("KindlePlugin: cold-start live position apply failed")
                return false
            end
            if type(applied) == "table" then
                live_xpointer = applied.xpointer
                live_percent = boundedPercent(applied.percent, 1)
            elseif not self:isPositionSourceOfTruthEnabled()
                and type(applied) == "number"
            then
                live_percent = boundedPercent(applied, 1)
            end
            if self:isPositionSourceOfTruthEnabled()
                and (not live_percent
                    or not liveXPointerMatches(
                        self, epub_path, live_xpointer,
                        exact_xpointer, native_position))
            then
                logger.warn("KindlePlugin: cold-start exact destination readback failed")
                return false
            end
            self:updateOpenSessionBaseline(
                epub_path, nil, native_position)
        end

        if destination_changed or live_percent ~= nil then
            self:applyKindleStateToKOReader(
                kindle_state,
                doc_settings,
                kr_timestamp,
                live_percent
            )
        end
        if destination_changed or apply_live_xpointer then
            doc_settings:saveSetting("last_xpointer", live_xpointer)
            doc_settings:flush()
        end

        if self:isPositionSourceOfTruthEnabled() and not apply_live_xpointer then
            pending_verification_id = self:stageOpenPositionVerification(
                cde_key,
                source_path,
                epub_path,
                exact_xpointer,
                native_position,
                kindle_state,
                direction,
                kr_timestamp
            )
            if not pending_verification_id then
                logger.warn("KindlePlugin: exact KOReader destination could not be staged")
                -- The sidecar may still have been updated for legacy/internal
                -- callers that do not provide an EPUB path. Never acknowledge
                -- it, but preserve the historical "state changed" return.
                return destination_changed == true
            end
            return true
        end

        local persisted_percent = boundedPercent(
            doc_settings:readSetting("percent_finished"), 1)
        local recorded = self:recordPositionReceipt(
            cde_key,
            source_path,
            native_position,
            direction,
            kindle_state.status,
            os.time(),
            nil,
            {
                native_percent = native_position.percent
                    or kindle_state.percent_read,
                koreader_percent = (live_percent or persisted_percent)
                    and (live_percent or persisted_percent) * 100 or nil,
            }
        )
        if recorded then
            self:updateOpenSessionBaseline(
                epub_path, nil, native_position)
        end
        return recorded
    end
    if sameReceiptPosition(receipt, native_position)
        and not self:isPositionSourceOfTruthEnabled()
    then
        self:repairCatalogFromReceipt(
            cde_key, source_path, receipt, native_position, kindle_state
        )
        logger.dbg("KindlePlugin: open-time native LPR is already reconciled")
        return false
    end
    if not receipt and (kr_timestamp <= 0 or (kindle_state.timestamp or 0) <= 0) then
        -- Upgrades have no reconciliation receipt yet. An absent timestamp is
        -- not evidence that the native LPR is newer, and pulling here could
        -- roll a valid KOReader sidecar back exactly once. Preserve KOReader;
        -- its next close will write and receipt the authoritative coordinate.
        local same_position = doc_settings:readSetting("last_xpointer") == exact_xpointer
        local same_status = kr_status == kindle_state.status
            or (kr_percent >= 1 and kindle_state.percent_read >= 100)
        if same_position and same_status then
            finishPull(false, "bootstrap")
        else
            logger.warn("KindlePlugin: deferring first exact LPR pull without comparable timestamps")
        end
        return false, pending_verification_id
    end
    local model_decision = self:observeOpenPositionFacts(
        cde_key, source_path, doc_settings, epub_path,
        kindle_state, native_position, kr_timestamp, local_at_open)
    if model_decision then
        if model_decision.action == "conflict" then
            logger.warn("KindlePlugin: equal-time exact position conflict; keeping KOReader")
            return false
        end
        if model_decision.action == "no_op" then
            if not sameReceiptPosition(receipt, native_position)
                and doc_settings:readSetting("last_xpointer") == exact_xpointer
            then
                finishPull(false, "pull")
                return false, pending_verification_id
            end
            self:repairCatalogFromReceipt(
                cde_key, source_path, receipt, native_position, kindle_state)
            return false
        end
        local awaiting_native_readback =
            model_decision.action == "await_destination_readback"
            and model_decision.winner
            and model_decision.winner.engine == "native"
        if model_decision.action == "await_destination_readback"
            and not awaiting_native_readback then
            return false
        end
        if (model_decision.action ~= "apply" and not awaiting_native_readback)
            or not model_decision.winner
        then
            return false
        end
        if model_decision.winner.engine == "koreader_persisted" then
            return pushPersistedWinner(model_decision)
        end
        if model_decision.winner.engine ~= "native" then return false end
    end
    local kindle_is_newer = model_decision ~= nil
        or receipt ~= nil
        or kindle_state.timestamp > kr_timestamp
    local sync_details = {
        book_title = self:getBookTitle(cde_key, doc_settings),
        source_percent = kindle_state.percent_read,
        dest_percent = kr_percent * 100,
        source_time = kindle_state.timestamp,
        dest_time = kr_timestamp,
    }

    local sync_completed = false
    self:syncIfApproved(true, kindle_is_newer, function()
        local same_position = doc_settings:readSetting("last_xpointer") == exact_xpointer
        local same_status = kr_status == kindle_state.status
            or (kr_percent >= 1 and kindle_state.percent_read >= 100)
        if same_position and same_status then
            sync_completed = finishPull(false, "pull")
            return
        end
        sync_completed = finishPull(true, "pull")
    end, sync_details)
    return sync_completed, pending_verification_id
end

--- Catch up a converted Kindle book that KOReader opened as its startup file.
--- At cold startup ReaderUI:showReader is already on the stack when document
--- plugins are instantiated, so ShowReaderExt cannot perform its usual pull.
--- Normal virtual-library opens register an alias before that call and are
--- deliberately skipped here to avoid a duplicate reconciliation.
function ReadingStateSync:syncColdStartReader(ui)
    if not self:isAutomaticSyncEnabled()
        or type(ui) ~= "table"
        or type(ui.document) ~= "table"
        or type(ui.document.file) ~= "string"
        or not ui.document.file:match("%.epub$")
        or type(ui.doc_settings) ~= "table"
        or type(ui.rolling) ~= "table"
        or type(ui.rolling.onGotoXPointer) ~= "function"
        or type(ui.rolling.getBookLocation) ~= "function"
        or type(ui.rolling.getLastPercent) ~= "function"
        or not self.virtual_library
    then
        return false
    end

    local epub_path = ui.document.file
    if type(self.virtual_library.isOpenAlias) == "function"
        and self.virtual_library:isOpenAlias(epub_path)
    then
        return false
    end

    local virtual_path = self.virtual_library:getVirtualPath(epub_path)
    local book = virtual_path and self.virtual_library:getBook(virtual_path)
    if not book or not book.source_path then
        return false
    end

    local cde_key = self:extractCdeKey(virtual_path, ui.doc_settings)
    logger.info("KindlePlugin: reconciling cold-start mapped reader position")
    return self:syncFromKindleAutomatic(
        cde_key,
        book.source_path,
        ui.doc_settings,
        epub_path,
        function(xpointer)
            ui.rolling:onGotoXPointer(xpointer)
            local actual_xpointer = ui.rolling:getBookLocation()
            local percent = ui.rolling:getLastPercent()
            if type(actual_xpointer) == "string"
                and type(percent) == "number"
            then
                return {
                    xpointer = actual_xpointer,
                    percent = percent,
                }
            end
            return false
        end
    )
end

--- Silent close-time sync is eligible for the durable root-private outbox.
--- Prompted sync remains in-process because UI choices require the reader.
function ReadingStateSync:canSyncCloseInBackground()
    return self:isAutomaticSyncEnabled()
        and self.plugin.settings.enable_sync_to_kindle == true
        and type(self.sync_direction) == "table"
        and self.plugin.settings.sync_to_kindle_newer
            == self.sync_direction.SILENT
end

local function validDurableCloseReceipt(receipt)
    return type(receipt) == "table"
        and type(receipt.asin) == "string" and #receipt.asin == 10
        and receipt.asin:match("^B[A-Z0-9]+$") ~= nil
        and type(receipt.sequence) == "string"
        and receipt.sequence:match("^%d+$") ~= nil
        and type(receipt.checksum) == "string"
        and receipt.checksum:match("^[0-9a-f]+$") ~= nil
        and #receipt.checksum == 64
        and validNativePosition({ long = receipt.long, pid = receipt.pid })
        and boundedPercent(receipt.native_percent, 100) ~= nil
        and boundedPercent(receipt.koreader_percent, 100) ~= nil
        and type(receipt.synced_at) == "number"
        and receipt.synced_at >= 0
        and receipt.synced_at == math.floor(receipt.synced_at)
        and type(receipt.status) == "string"
end

--- Adopt verified completion receipts left by the detached worker. Replaying a
--- receipt is idempotent and updates the same exact-position model used by
--- foreground open reconciliation.
function ReadingStateSync:recoverDurableCloseProgress(start_watcher)
    if not self.plugin or not self.helper_client then return false end
    if start_watcher
        and type(self.helper_client.startCloseProgressWatcher) == "function"
    then
        self.helper_client:startCloseProgressWatcher()
    end
    if type(self.helper_client.readCloseProgressReceipts) ~= "function" then
        return false
    end
    local receipts = self.helper_client:readCloseProgressReceipts()
    if type(receipts) ~= "table" then return false end
    local settings = self.plugin.settings
    settings.durable_close_progress_sequences =
        settings.durable_close_progress_sequences or {}
    local changed = false
    for _, receipt in ipairs(receipts) do
        local receipt_token = validDurableCloseReceipt(receipt)
            and (receipt.sequence .. ":" .. receipt.checksum) or nil
        if validDurableCloseReceipt(receipt)
            and settings.durable_close_progress_sequences[receipt.asin]
                ~= receipt_token
        then
            settings.durable_close_progress_sequences[receipt.asin] =
                receipt_token
            local recorded = self:recordPositionReceipt(
                receipt.asin,
                nil,
                {
                    long = receipt.long,
                    pid = receipt.pid,
                    percent = receipt.native_percent,
                },
                "push",
                receipt.status,
                receipt.synced_at,
                nil,
                {
                    native_percent = receipt.native_percent,
                    koreader_percent = receipt.koreader_percent,
                }
            )
            if recorded then
                changed = true
                logger.info("KindlePlugin: adopted durable close progress receipt")
            else
                settings.durable_close_progress_sequences[receipt.asin] = nil
            end
        end
    end
    return changed
end

--- Queue the latest immutable close snapshot in root-private storage. The
--- detached worker survives KOReader exit, serializes ReaderSDK access, and a
--- newer snapshot for the same ASIN atomically supersedes stale work.
function ReadingStateSync:syncToKindleAutomaticInBackground(
    cde_key, source_path, doc_settings, epub_path, live_snapshot
)
    if not self:canSyncCloseInBackground() then return false end
    local asin = receiptAsin(cde_key, source_path)
    if not asin or type(source_path) ~= "string"
        or type(epub_path) ~= "string" or type(doc_settings) ~= "table"
        or type(self.helper_client) ~= "table"
        or type(self.helper_client.enqueueCloseProgress) ~= "function"
    then
        return false
    end
    self:discardOpenPositionVerification(epub_path)
    self:recoverDurableCloseProgress(false)
    local live_xpointer = type(live_snapshot) == "table"
        and live_snapshot.xpointer or nil
    local live_percent = type(live_snapshot) == "table"
        and boundedPercent(live_snapshot.percent, 1) or nil
    local xpointer = validXPointer(live_xpointer)
        and live_xpointer or doc_settings:readSetting("last_xpointer")
    local percent = live_percent or boundedPercent(
        doc_settings:readSetting("percent_finished"), 1)
    local summary = doc_settings:readSetting("summary") or {}
    if type(xpointer) ~= "string" or not percent then return false end
    local receipt = self:getPositionReceipt(cde_key, source_path)
    local session_baseline = self:getOpenSessionBaseline(
        cde_key, source_path, epub_path)
    local queued = self.helper_client:enqueueCloseProgress(
        asin,
        source_path,
        epub_path,
        xpointer,
        percent * 100,
        summary.status or "reading",
        os.time(),
        validPositionReceipt(receipt) and receipt or nil,
        session_baseline
    )
    if not queued then
        logger.warn("KindlePlugin: durable close progress enqueue failed")
    end
    return queued == true
end

--- Sync KOReader state into Kindle's authoritative ReaderSDK state during close.
--- This honors automatic-sync and all configured direction choices.
function ReadingStateSync:syncToKindleAutomatic(cde_key, source_path, doc_settings, epub_path)
    self:discardOpenPositionVerification(epub_path)
    if not self:isAutomaticSyncEnabled() then
        return false
    end

    local kr_percent = doc_settings:readSetting("percent_finished") or 0
    local summary = doc_settings:readSetting("summary") or {}
    local kr_status = summary.status or "reading"
    local close_timestamp = os.time()

    local kindle_state = self:readKindleState(cde_key, source_path) or {
        percent_read = 0,
        timestamp = 0,
        status = "",
        kindle_status = 0,
    }
    local model_decision, local_position = self:observeClosePositionFacts(
        cde_key, source_path, doc_settings, epub_path,
        kindle_state, close_timestamp)
    if model_decision then
        if model_decision.action == "conflict" then
            logger.warn("KindlePlugin: equal-time close conflict; keeping both positions")
            return false
        end
        if model_decision.action == "no_op"
            or model_decision.action == "await_destination_readback"
        then
            return false
        end
        if model_decision.action ~= "apply"
            or not model_decision.winner
            or model_decision.winner.engine ~= "koreader_live"
        then
            return false
        end
    elseif SyncDecisionMaker.areBothSidesComplete(
        kindle_state, kr_percent, kr_status)
    then
        return false
    end
    -- This method runs in KOReader's close lifecycle. The just-captured
    -- XPointer is therefore the newest local event even if ReadHistory has not
    -- flushed its timestamp yet or the reader moved backwards in the book.
    local koreader_is_newer = true
    local sync_details = {
        book_title = self:getBookTitle(cde_key, doc_settings),
        source_percent = kr_percent * 100,
        dest_percent = kindle_state.percent_read or 0,
        source_time = close_timestamp,
        dest_time = kindle_state.timestamp or 0,
    }

    local sync_completed = false
    self:syncIfApproved(false, koreader_is_newer, function()
        local current_timestamp = close_timestamp
        -- Always verify the exact LPR even when the rounded shelf percentage
        -- already matches; two positions inside one percentage point differ.
        local native_percent, native_position = self:saveAuthoritativeNativePosition(
            cde_key, source_path, epub_path, doc_settings, local_position
        )
        if native_percent then
            sync_completed = self:writeKindleState(
                cde_key,
                source_path,
                native_percent,
                current_timestamp,
                kr_status
            )
            if sync_completed then
                self:recordPositionReceipt(
                    cde_key, source_path, native_position, "push", kr_status,
                    current_timestamp, nil, {
                        native_percent = native_percent,
                        koreader_percent = kr_percent * 100,
                    })
            end
        end
    end, sync_details)
    return sync_completed
end

---
--- Executes sync FROM Kindle to KOReader (PULL scenario).
function ReadingStateSync:executePullFromKindle(cde_key, source_path, doc_settings, kindle_state, kr_percent, kr_timestamp)
    logger.info(
        "KindlePlugin: Kindle is more recent - PULL scenario:",
        "Kindle:",
        kindle_state.percent_read,
        "% (",
        kindle_state.timestamp,
        ")",
        "KOReader:",
        kr_percent * 100,
        "% (",
        kr_timestamp,
        ")"
    )

    if kindle_state.kindle_status == 0 and kindle_state.percent_read == 0 then
        return false
    end

    local sync_details = {
        book_title = self:getBookTitle(cde_key, doc_settings),
        source_percent = kindle_state.percent_read,
        dest_percent = kr_percent * 100,
        source_time = kindle_state.timestamp,
        dest_time = kr_timestamp,
    }

    local sync_completed = false
    self:syncIfApproved(true, true, function()
        local epub_path = doc_settings.data and doc_settings.data.doc_path
        local exact_xpointer, _, native_position = self:getAuthoritativeKindleXPointer(
            cde_key, source_path, epub_path
        )
        if not exact_xpointer then
            logger.warn("KindlePlugin: exact native progress pull failed")
            return
        end
        logger.info("KindlePlugin: Syncing FROM Kindle (PULL)")
        self:applyKindleStateToKOReader(
            kindle_state, doc_settings, kr_timestamp)
        doc_settings:saveSetting("last_xpointer", exact_xpointer)
        doc_settings:flush()
        self:recordPositionReceipt(
            cde_key, source_path, native_position, "pull", kindle_state.status)

        sync_completed = true
    end, sync_details)

    return sync_completed
end

---
--- Executes sync FROM KOReader to Kindle (PUSH scenario).
function ReadingStateSync:executePushToKindle(cde_key, source_path, doc_settings, kindle_state, kr_percent, kr_timestamp)
    logger.info(
        "KindlePlugin: KOReader is more recent - PUSH scenario:",
        "KOReader:",
        kr_percent * 100,
        "% (",
        kr_timestamp,
        ")",
        "Kindle:",
        kindle_state.percent_read,
        "% (",
        kindle_state.timestamp,
        ")"
    )

    if kr_timestamp == 0 then
        return false
    end

    local sync_details = {
        book_title = self:getBookTitle(cde_key, doc_settings),
        source_percent = kr_percent * 100,
        dest_percent = kindle_state.percent_read,
        source_time = kr_timestamp,
        dest_time = kindle_state.timestamp,
    }

    local sync_completed = false
    self:syncIfApproved(false, true, function()
        local summary = doc_settings:readSetting("summary") or {}
        local kr_status = summary.status or "reading"
        local current_timestamp = os.time()

        logger.info("KindlePlugin: Syncing TO Kindle (PUSH)")
        local epub_path = doc_settings.data and doc_settings.data.doc_path
        local native_percent, native_position = self:saveAuthoritativeNativePosition(
            cde_key, source_path, epub_path, doc_settings
        )
        if native_percent then
            sync_completed = self:writeKindleState(
                cde_key, source_path, native_percent, current_timestamp, kr_status
            )
            if sync_completed then
                self:recordPositionReceipt(
                    cde_key, source_path, native_position, "push", kr_status,
                    current_timestamp, nil, {
                        native_percent = native_percent,
                        koreader_percent = kr_percent * 100,
                    })
            end
        end
    end, sync_details)

    return sync_completed
end

---
--- Bidirectional sync - used when showing virtual library.
--- Winner is whoever was read more recently.
--- @param cde_key string|nil: Book cdeKey.
--- @param source_path string|nil: Real file path on device.
--- @param doc_settings table: Document settings instance.
--- @return boolean: True if sync was performed.
function ReadingStateSync:syncBidirectional(cde_key, source_path, doc_settings)
    if not self:isEnabled() then
        return false
    end

    local kindle_state = self:readKindleState(cde_key, source_path)
    if not kindle_state then
        return false
    end

    local kr_percent = doc_settings:readSetting("percent_finished") or 0
    local doc_path = doc_settings.data and doc_settings.data.doc_path
    local kr_timestamp = getValidatedKOReaderTimestamp(doc_path)

    local summary = doc_settings:readSetting("summary") or {}
    local kr_status = summary.status

    if SyncDecisionMaker.areBothSidesComplete(kindle_state, kr_percent, kr_status) then
        logger.dbg("KindlePlugin: both readers complete; skipping sync")
        return false
    end

    if kindle_state.timestamp > kr_timestamp then
        return self:executePullFromKindle(cde_key, source_path, doc_settings, kindle_state, kr_percent, kr_timestamp)
    end

    return self:executePushToKindle(cde_key, source_path, doc_settings, kindle_state, kr_percent, kr_timestamp)
end

---
--- Syncs a single book during manual sync.
--- @param book table: Book info with path and cde_key.
--- @return boolean: True if sync was successful.
function ReadingStateSync:syncBook(book)
    local source_path = book.real_path or book.filepath or book.location
    if not source_path then
        return false
    end

    -- Exact KFX coordinates can only be translated using the converted EPUB
    -- that KOReader actually reads. Never open a second sidecar against KFX.
    local mapped_book = self.virtual_library and self.virtual_library:getBook(source_path)
    local cache_manager = self.virtual_library and self.virtual_library.cache_manager
    if not mapped_book or not cache_manager then
        logger.dbg("KindlePlugin: manual sync skipped; no virtual mapping")
        return false
    end
    local fresh, epub_path = cache_manager:isFresh(mapped_book)
    if not fresh then
        logger.dbg("KindlePlugin: manual sync skipped; no fresh cached EPUB")
        return false
    end

    local doc_settings = DocSettings:open(epub_path)
    if not doc_settings then
        return false
    end

    local cde_key = book.cde_key
    if not cde_key then
        -- Try to find the ASIN from the file path
        cde_key = source_path:match("_(B[A-Z0-9]+)%.%w+$")
    end

    return self:syncBidirectional(cde_key, source_path, doc_settings)
end

---
--- Invalidates book metadata caches and broadcasts refresh events.
function ReadingStateSync:invalidateMetadataCaches()
    logger.info("KindlePlugin: Invalidating all book metadata caches after sync")
    BookList.book_info_cache = {}
    UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache"))
end

---
--- Sync all accessible books in the library (manually triggered).
--- @return number: Number of books successfully synced.
function ReadingStateSync:syncAllBooksManual()
    if not self:isEnabled() then
        logger.warn("KindlePlugin: Sync is disabled")
        return 0
    end

    local result = 0
    Trapper:wrap(function()
        result = self:syncAllBooks()
    end)

    return result
end

---
--- Internal: Sync all accessible books (called from within Trapper:wrap context).
--- @return number: Number of books successfully synced.
function ReadingStateSync:syncAllBooks()
    if not self:isEnabled() then
        return 0
    end

    if self.virtual_library then
        local mapped = self.virtual_library:buildMappings(false)
        if not mapped then
            logger.warn("KindlePlugin: cannot build mappings for manual sync")
            return 0
        end
    end

    -- Read all books from cc.db
    local all_books = KindleStateReader.readAllProgress()
    if not all_books or #all_books == 0 then
        logger.info("KindlePlugin: No books found in cc.db")
        return 0
    end

    logger.info("KindlePlugin: Starting manual sync for", #all_books, "books")

    Trapper:setPausedText(_("Do you want to abort sync?"), _("Abort"), _("Continue"))

    local go_on = Trapper:info(_("Scanning books..."))
    if not go_on then
        return 0
    end

    local synced_count = 0
    for i, book in ipairs(all_books) do
        go_on = Trapper:info(T(_("Syncing: %1 / %2"), i, #all_books))
        if not go_on then
            logger.info("KindlePlugin: Manual sync aborted at book", i, "of", #all_books)
            Trapper:clear()
            return synced_count
        end

        if self:syncBook(book) then
            synced_count = synced_count + 1
        end
    end

    logger.info("KindlePlugin: Manual sync completed -", synced_count, "books synced")

    if synced_count > 0 then
        self:invalidateMetadataCaches()
    end

    ffiUtil.sleep(2)
    Trapper:info(T(_("Synced %1 books"), synced_count))
    ffiUtil.sleep(2)
    Trapper:clear()

    return synced_count
end

return ReadingStateSync
