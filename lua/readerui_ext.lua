---
--- ReaderUI extensions for Kindle virtual library.
--- Patches ReaderUI to navigate back to virtual library after closing books
--- and update BookList cache with final reading progress.
--- Adapted from kobo.koplugin/src/readerui_ext.lua (reading_state_sync removed).

local logger = require("logger")
local Event = require("ui/event")
local Trapper = require("ui/trapper")

local ReaderUIExt = {}

--- Capture the current rolling-renderer position before ReaderUI teardown.
--- ReaderUI normally dispatches SaveSettings from inside onClose, which is too
--- late for a durable snapshot queued by an outer onClose wrapper.
local function captureLiveCloseSnapshot(reader_self)
    local snapshot
    local rolling = reader_self and reader_self.rolling
    if rolling
        and type(rolling.getBookLocation) == "function"
        and type(rolling.getLastPercent) == "function"
    then
        local location_ok, xpointer = pcall(
            rolling.getBookLocation, rolling)
        local percent_ok, percent = pcall(
            rolling.getLastPercent, rolling)
        if location_ok and percent_ok
            and type(xpointer) == "string"
            and type(percent) == "number"
            and percent >= 0 and percent <= 1
        then
            snapshot = {
                xpointer = xpointer,
                percent = percent,
            }
        end
    end

    -- Refresh every module's in-memory DocSettings view as KOReader's normal
    -- close path will do moments later. This also makes the synchronous
    -- fallback consume the live page if durable enqueue is unavailable.
    if reader_self and type(reader_self.handleEvent) == "function" then
        local saved = pcall(
            reader_self.handleEvent,
            reader_self,
            Event:new("SaveSettings")
        )
        if not saved then
            logger.warn("KindlePlugin: live close settings refresh failed")
        end
    end
    return snapshot
end

---
--- Creates a new ReaderUIExt instance.
--- @return table: A new ReaderUIExt instance.
function ReaderUIExt:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    return o
end

---
--- Updates BookList cache with final reading progress.
--- @param virtual_path string: Virtual library path.
--- @param doc_settings table: Document settings instance.
local function updateBookListCache(virtual_path, doc_settings)
    if not doc_settings then
        return
    end

    local percent_finished = doc_settings:readSetting("percent_finished")
    if not percent_finished then
        return
    end

    local BookList = require("ui/widget/booklist")
    logger.dbg("KindlePlugin: updating complete virtual BookList metadata")
    local cache_ok = type(BookList.setBookInfoCache) == "function"
        and pcall(BookList.setBookInfoCache, virtual_path, doc_settings)
    if not cache_ok then
        -- Compatibility fallback for KOReader versions without the complete
        -- cache API. A current KOReader uses setBookInfoCache so status and
        -- annotation presence make the cached percentage durable.
        pcall(
            BookList.setBookInfoCacheProperty,
            virtual_path,
            "percent_finished",
            percent_finished
        )
    end
end

---
--- Initializes the ReaderUIExt module.
--- @param virtual_library table: Virtual library instance.
--- @param reading_state_sync table|nil: Reading state sync instance (optional).
function ReaderUIExt:init(virtual_library, reading_state_sync)
    self.virtual_library = virtual_library
    self.reading_state_sync = reading_state_sync
    self.original_methods = {}
end

---
--- Applies monkey patches to ReaderUI.
--- Patches showFileManager and onClose for virtual library navigation.
--- @param ReaderUI table: ReaderUI module to patch.
function ReaderUIExt:apply(ReaderUI)
    if not self.virtual_library:isActive() then
        logger.info("KindlePlugin: virtual library not active, skipping ReaderUI patches")
        return
    end

    logger.info("KindlePlugin: Applying ReaderUI monkey patches for virtual library navigation")

    self.original_methods.showFileManager = ReaderUI.showFileManager
    ReaderUI.showFileManager = function(reader_self, file, selected_files)
        if not file or not self.virtual_library:isVirtualPath(file) then
            return self.original_methods.showFileManager(reader_self, file, selected_files)
        end

        logger.info("KindlePlugin: navigating to the virtual library")
        return self.original_methods.showFileManager(reader_self, file, selected_files)
    end

    self.original_methods.onClose = ReaderUI.onClose
    ReaderUI.onClose = function(reader_self, full_refresh)
        -- Try document.virtual_path first (set by document_ext for virtual paths)
        -- Fall back to looking up via the open alias (set by showreader_ext)
        local virtual_path = reader_self.document and reader_self.document.virtual_path
        local epub_path = reader_self.document and reader_self.document.file
        if not virtual_path and reader_self.document and reader_self.document.file then
            virtual_path = self.virtual_library:getVirtualPath(reader_self.document.file)
        end

        local sync_context
        local durable_attempted = false
        local sync_completed_before_close = false
        if virtual_path and reader_self.doc_settings
            and self.reading_state_sync
            and self.reading_state_sync:isAutomaticSyncEnabled()
        then
            local cde_key = self.reading_state_sync:extractCdeKey(
                virtual_path, reader_self.doc_settings)
            local book = self.virtual_library:getBook(virtual_path)
            local source_path = book and book.source_path
            if cde_key or source_path then
                local live_snapshot = captureLiveCloseSnapshot(reader_self)
                sync_context = {
                    cde_key = cde_key,
                    source_path = source_path,
                }
                logger.info("KindlePlugin: auto-syncing progress on book close")
                if type(self.reading_state_sync.canSyncCloseInBackground)
                        == "function"
                    and self.reading_state_sync:canSyncCloseInBackground()
                    and type(self.reading_state_sync
                        .syncToKindleAutomaticInBackground) == "function"
                then
                    durable_attempted = true
                    local queued = self.reading_state_sync
                        :syncToKindleAutomaticInBackground(
                        cde_key,
                        source_path,
                        reader_self.doc_settings,
                        epub_path,
                        live_snapshot
                    )
                    if not queued then
                        -- A failed durable enqueue is rare. Complete the silent
                        -- save while the document is still valid; never fork a
                        -- second KOReader process from the close lifecycle.
                        logger.warn("KindlePlugin: durable close queue unavailable")
                        Trapper:wrap(function()
                            self.reading_state_sync:syncToKindleAutomatic(
                                cde_key,
                                source_path,
                                reader_self.doc_settings,
                                epub_path
                            )
                        end)
                        sync_completed_before_close = true
                    end
                end
            end
        end

        self.original_methods.onClose(reader_self, full_refresh)

        if virtual_path and reader_self.doc_settings then
            updateBookListCache(virtual_path, reader_self.doc_settings)
        end

        -- Prompted directions still run in-process. Silent directions were
        -- durably queued before ReaderUI unloaded the document.
        if sync_context and not durable_attempted
            and not sync_completed_before_close
        then
            Trapper:wrap(function()
                self.reading_state_sync:syncToKindleAutomatic(
                    sync_context.cde_key,
                    sync_context.source_path,
                    reader_self.doc_settings,
                    epub_path
                )
            end)
        end
    end
end

---
--- Removes all monkey patches and restores original methods.
--- @param ReaderUI table: ReaderUI module to restore.
function ReaderUIExt:unapply(ReaderUI)
    logger.info("KindlePlugin: Removing ReaderUI monkey patches")

    for method_name, original_method in pairs(self.original_methods) do
        ReaderUI[method_name] = original_method
    end

    self.original_methods = {}
end

return ReaderUIExt
