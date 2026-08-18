-- Tests for ReaderUIExt module
-- Covers: initialization, onClose sync triggers, both-sides-complete skip,
-- auto-sync disabled, virtual path resolution, book list cache update.

require('busted.runner')()
local helper = require("spec/test_helper")

describe("ReaderUIExt", function()
    local BookList
    local ReaderUIExt
    local original_set_book_info_cache
    local original_set_book_info_cache_property

    setup(function()
        helper.setup_complete()
        BookList = require("ui/widget/booklist")
        original_set_book_info_cache = BookList.setBookInfoCache
        original_set_book_info_cache_property =
            BookList.setBookInfoCacheProperty
    end)

    before_each(function()
        package.loaded["lua/readerui_ext"] = nil
        ReaderUIExt = require("lua/readerui_ext")
    end)

    after_each(function()
        BookList.setBookInfoCache = original_set_book_info_cache
        BookList.setBookInfoCacheProperty =
            original_set_book_info_cache_property
    end)

    describe("initialization", function()
        it("should create a new instance", function()
            local ext = ReaderUIExt:new()
            assert.is_not_nil(ext)
        end)

        it("should initialize with virtual library and reading state sync", function()
            local mock_vlib = {
                isActive = function() return true end,
            }
            local mock_sync = {
                isEnabled = function() return true end,
            }

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            assert.equals(mock_vlib, ext.virtual_library)
            assert.equals(mock_sync, ext.reading_state_sync)
            assert.is_table(ext.original_methods)
        end)
    end)

    describe("onClose sync behavior", function()
        local function createMockVirtualLibrary(is_active)
            return {
                isActive = function()
                    return is_active
                end,
                isVirtualPath = function(self, path)
                    return path and path:match("^KINDLE_VIRTUAL://") ~= nil
                end,
                getVirtualPath = function(self, real_path)
                    if real_path == "/mnt/us/documents/test.kfx" then
                        return "KINDLE_VIRTUAL://B001/test.kfx"
                    end
                    return nil
                end,
                getBook = function(self, virtual_path)
                    if virtual_path == "KINDLE_VIRTUAL://B001/test.kfx" then
                        return { source_path = "/mnt/us/documents/test.kfx", cde_key = "B001" }
                    end
                    return nil
                end,
            }
        end

        local function createMockSync(is_enabled, sync_tracker)
            return {
                isAutomaticSyncEnabled = function()
                    return is_enabled
                end,
                extractCdeKey = function(self, virtual_path, doc_settings)
                    if virtual_path then
                        return virtual_path:match("^KINDLE_VIRTUAL://([A-Z0-9]+)/")
                    end
                    return nil
                end,
                syncToKindleAutomatic = function(self, cde_key, source_path, doc_settings, epub_path)
                    if is_enabled and sync_tracker then
                        sync_tracker.called = true
                        sync_tracker.cde_key = cde_key
                        sync_tracker.source_path = source_path
                        sync_tracker.epub_path = epub_path
                    end
                    return is_enabled
                end,
            }
        end

        local function createMockReaderUI(virtual_path, doc_settings)
            local doc_file = virtual_path and virtual_path:gsub("KINDLE_VIRTUAL://[A-Z0-9]+/", "/mnt/us/documents/") or nil
            return {
                onClose = function(reader_self, full_refresh) end,
                showFileManager = function(reader_self, file, selected_files)
                    return true
                end,
                document = virtual_path and {
                    virtual_path = virtual_path,
                    file = doc_file,
                } or nil,
                doc_settings = doc_settings,
            }
        end

        it("should sync progress to Kindle on book close", function()
            local tracker = { called = false }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true, tracker)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx",
                {
                    readSetting = function(self, key)
                        if key == "percent_finished" then return 0.75 end
                        if key == "summary" then return { status = "reading" } end
                        return nil
                    end,
                }
            )

            ext:apply(mock_rui)
            mock_rui.onClose(mock_rui, false)

            assert.is_true(tracker.called)
            assert.equals("B001", tracker.cde_key)
            assert.equals("/mnt/us/documents/test.kfx", tracker.source_path)
            assert.equals("/mnt/us/documents/test.kfx", tracker.epub_path)
        end)

        it("should durably queue silent sync before unloading the reader", function()
            local tracker = {
                background = false,
                blocking = false,
                reader_closed = false,
            }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true)
            mock_sync.canSyncCloseInBackground = function() return true end
            mock_sync.syncToKindleAutomatic = function()
                tracker.blocking = true
            end
            mock_sync.syncToKindleAutomaticInBackground = function(
                self, cde_key, source_path, doc_settings, epub_path
            )
                assert.is_false(tracker.reader_closed)
                tracker.background = true
                tracker.cde_key = cde_key
                tracker.source_path = source_path
                tracker.epub_path = epub_path
                return true
            end
            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx",
                {
                    readSetting = function(self, key)
                        if key == "percent_finished" then return 0.54 end
                        if key == "last_xpointer" then return "/body/p/text().54" end
                        if key == "summary" then return { status = "reading" } end
                        return nil
                    end,
                }
            )
            mock_rui.onClose = function()
                tracker.reader_closed = true
            end
            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)
            ext:apply(mock_rui)

            mock_rui.onClose(mock_rui, false)

            assert.is_true(tracker.background)
            assert.is_false(tracker.blocking)
            assert.is_true(tracker.reader_closed)
            assert.equals("B001", tracker.cde_key)
            assert.equals("/mnt/us/documents/test.kfx", tracker.source_path)
            assert.equals("/mnt/us/documents/test.kfx", tracker.epub_path)
        end)

        it("should queue the live rolling page instead of stale sidecar state", function()
            local tracker = {
                reader_closed = false,
                save_event = false,
            }
            local data = {
                percent_finished = 0.40,
                last_xpointer = "/body/p/text().40",
                summary = { status = "reading" },
            }
            local doc_settings = {
                readSetting = function(_, key) return data[key] end,
                saveSetting = function(_, key, value) data[key] = value end,
            }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true)
            mock_sync.canSyncCloseInBackground = function() return true end
            mock_sync.syncToKindleAutomaticInBackground = function(
                _, _, _, _, _, live_snapshot
            )
                assert.is_false(tracker.reader_closed)
                tracker.live_snapshot = live_snapshot
                tracker.persisted_xpointer = data.last_xpointer
                tracker.persisted_percent = data.percent_finished
                return true
            end
            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx", doc_settings)
            mock_rui.rolling = {
                getBookLocation = function()
                    return "/body/p/text().54"
                end,
                getLastPercent = function() return 0.54 end,
            }
            mock_rui.handleEvent = function()
                tracker.save_event = true
                data.last_xpointer = "/body/p/text().54"
                data.percent_finished = 0.54
            end
            mock_rui.onClose = function()
                tracker.reader_closed = true
            end
            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)
            ext:apply(mock_rui)

            mock_rui.onClose(mock_rui, false)

            assert.is_true(tracker.save_event)
            assert.is_true(tracker.reader_closed)
            assert.same({
                xpointer = "/body/p/text().54",
                percent = 0.54,
            }, tracker.live_snapshot)
            assert.equals("/body/p/text().54", tracker.persisted_xpointer)
            assert.equals(0.54, tracker.persisted_percent)
        end)

        it("should synchronously save before unload if durable enqueue fails", function()
            local order = {}
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true)
            mock_sync.canSyncCloseInBackground = function() return true end
            mock_sync.syncToKindleAutomaticInBackground = function()
                table.insert(order, "enqueue")
                return false
            end
            mock_sync.syncToKindleAutomatic = function()
                table.insert(order, "fallback")
                return true
            end
            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx",
                {
                    readSetting = function(self, key)
                        if key == "percent_finished" then return 0.54 end
                        if key == "last_xpointer" then
                            return "/body/p/text().54"
                        end
                        if key == "summary" then
                            return { status = "reading" }
                        end
                    end,
                }
            )
            mock_rui.onClose = function()
                table.insert(order, "close")
            end
            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)
            ext:apply(mock_rui)

            mock_rui.onClose(mock_rui, false)

            assert.same({ "enqueue", "fallback", "close" }, order)
        end)

        it("should refresh the complete virtual shelf cache from KOReader metadata", function()
            local full_cache_call
            local property_cache_called = false
            BookList.setBookInfoCache = function(path, doc_settings)
                full_cache_call = { path = path, doc_settings = doc_settings }
            end
            BookList.setBookInfoCacheProperty = function()
                property_cache_called = true
            end
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(false)
            local doc_settings = {
                readSetting = function(self, key)
                    if key == "percent_finished" then return 0.54 end
                    if key == "summary" then return { status = "reading" } end
                    if key == "annotations" then return { { page = 455 } } end
                    return nil
                end,
            }
            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx", doc_settings)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)
            ext:apply(mock_rui)
            mock_rui.onClose(mock_rui, false)

            assert.is_not_nil(full_cache_call)
            assert.equals(
                "KINDLE_VIRTUAL://B001/test.kfx", full_cache_call.path)
            assert.equals(doc_settings, full_cache_call.doc_settings)
            assert.is_false(property_cache_called)
        end)

        it("should not sync when auto-sync is disabled", function()
            local tracker = { called = false }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(false, tracker)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx",
                {
                    readSetting = function(self, key)
                        if key == "percent_finished" then return 0.6 end
                        return nil
                    end,
                }
            )

            ext:apply(mock_rui)
            mock_rui.onClose(mock_rui, false)

            assert.is_false(tracker.called)
        end)

        it("should not sync when no virtual path", function()
            local tracker = { called = false }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true, tracker)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            -- No document → no virtual path
            local mock_rui = {
                onClose = function() end,
                showFileManager = function() return true end,
                document = nil,
                doc_settings = {
                    readSetting = function() return 0.5 end,
                },
            }

            ext:apply(mock_rui)
            mock_rui.onClose(mock_rui, false)

            assert.is_false(tracker.called)
        end)

        it("should not sync when no reading state sync configured", function()
            local mock_vlib = createMockVirtualLibrary(true)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, nil) -- no sync module

            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx",
                {
                    readSetting = function() return 0.75 end,
                }
            )

            ext:apply(mock_rui)
            -- Should not crash when sync is nil
            local ok = pcall(function()
                mock_rui.onClose(mock_rui, false)
            end)
            assert.is_true(ok)
        end)

        it("should resolve virtual path from real path when document.virtual_path is nil", function()
            local tracker = { called = false }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true, tracker)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            -- Document has no virtual_path set, but has file
            local mock_rui = {
                onClose = function() end,
                showFileManager = function() return true end,
                document = {
                    virtual_path = nil,
                    file = "/mnt/us/documents/test.kfx",
                },
                doc_settings = {
                    readSetting = function() return 0.5 end,
                },
            }

            ext:apply(mock_rui)
            mock_rui.onClose(mock_rui, false)

            -- Should have resolved virtual path via getVirtualPath
            assert.is_true(tracker.called)
            assert.equals("/mnt/us/documents/test.kfx", tracker.source_path)
        end)

        it("should not apply patches when virtual library is not active", function()
            local tracker = { called = false }
            local mock_vlib = createMockVirtualLibrary(false)
            local mock_sync = createMockSync(true, tracker)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            local mock_rui = {
                onClose = function() end,
                showFileManager = function() return true end,
            }

            ext:apply(mock_rui)

            -- Original methods should NOT be replaced since VL is not active
            assert.is_nil(ext.original_methods.onClose)
        end)

        it("should handle doc_settings with minimal data without crash", function()
            local tracker = { called = false }
            local mock_vlib = createMockVirtualLibrary(true)
            local mock_sync = createMockSync(true, tracker)

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, mock_sync)

            local mock_rui = createMockReaderUI(
                "KINDLE_VIRTUAL://B001/test.kfx",
                {
                    readSetting = function() return nil end,
                }
            )

            ext:apply(mock_rui)
            local ok = pcall(function()
                mock_rui.onClose(mock_rui, false)
            end)
            assert.is_true(ok)
        end)
    end)

    describe("unapply", function()
        it("should restore original methods", function()
            local mock_vlib = {
                isActive = function() return true end,
            }

            local ext = ReaderUIExt:new()
            ext:init(mock_vlib, nil)

            local original_onClose = function() end
            local original_showFileManager = function() end
            local mock_rui = {
                onClose = original_onClose,
                showFileManager = original_showFileManager,
            }

            ext:apply(mock_rui)
            -- After apply, onClose should be different
            assert.is_not.equals(original_onClose, mock_rui.onClose)

            ext:unapply(mock_rui)
            -- After unapply, should be restored
            assert.equals(original_onClose, mock_rui.onClose)
            assert.equals(original_showFileManager, mock_rui.showFileManager)
        end)
    end)
end)
