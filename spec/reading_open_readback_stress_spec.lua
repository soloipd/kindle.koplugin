require("busted.runner")()

local helper = require("spec/test_helper")

describe("opened-reader destination readback stress", function()
    local ReadingStateSync

    setup(function()
        helper.setup_complete()
    end)

    before_each(function()
        helper.before_each()
        package.loaded["lua/reading_state_sync"] = nil
        ReadingStateSync = require("lua/reading_state_sync")
    end)

    it("keeps only the newest of 1,000 rapid staged opens", function()
        local sync = ReadingStateSync:new()
        sync:setEnabled(true)
        local plugin = {
            settings = {
                enable_auto_sync = true,
                enable_position_source_of_truth = true,
            },
            save_count = 0,
            saveSettings = function(self)
                self.save_count = self.save_count + 1
            end,
        }
        sync:setPlugin(plugin, {})

        local latest_xpointer
        for index = 1, 1000 do
            latest_xpointer = string.format(
                "/body/DocFragment/body/p/text().%d", index)
            local verification_id = sync:stageOpenPositionVerification(
                "B007N6JEII",
                "/mnt/us/documents/test_B007N6JEII.kfx",
                "/cache/book.epub",
                latest_xpointer,
                {
                    long = "ATwFAACbAAAA",
                    pid = 442000 + index,
                    percent = ((index - 1) % 99) + 1,
                },
                {
                    percent_read = ((index - 1) % 99) + 1,
                    timestamp = 1000 + index,
                    status = "reading",
                },
                "pull",
                900 + index
            )
            assert.equals(index, verification_id)
        end

        assert.equals(1000, sync.pending_open_verification.id)
        assert.is_nil(sync.pending_open_verification.title)
        assert.is_nil(sync.pending_open_verification.annotation_text)

        local saved = {}
        local doc_settings = {
            readSetting = function(self, key) return saved[key] end,
            saveSetting = function(self, key, value) saved[key] = value end,
            flush = function() end,
        }
        local reader = {
            document = { file = "/cache/book.epub" },
            doc_settings = doc_settings,
            rolling = {
                getBookLocation = function() return latest_xpointer end,
                getLastPercent = function() return 0.51 end,
            },
        }

        for stale_id = 1, 999 do
            assert.is_false(sync:verifyOpenedKOReaderPosition(
                reader, "/cache/book.epub", nil, stale_id))
        end
        assert.equals(1000, sync.pending_open_verification.id)
        assert.is_true(sync:verifyOpenedKOReaderPosition(
            reader, "/cache/book.epub", nil, 1000))
        assert.is_nil(sync.pending_open_verification)
        assert.equals(443000,
            plugin.settings.position_sync_receipts.B007N6JEII.pid)
        assert.equals(51, plugin.settings.reading_position_states.B007N6JEII
            .observations.koreader_persisted.percent)
        assert.equals(1, plugin.save_count)
    end)
end)
