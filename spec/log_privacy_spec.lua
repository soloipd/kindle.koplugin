require("busted.runner")()

local lfs = require("lfs")

local function pluginRoot()
    local source = debug.getinfo(1, "S").source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    return assert(source:match("^(.*)/spec/"))
end

local function luaFiles(path, output)
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local mode = lfs.attributes(child, "mode")
            if mode == "directory" then
                luaFiles(child, output)
            elseif mode == "file" and name:match("%.lua$") then
                table.insert(output, child)
            end
        end
    end
end

local function filesWithExtension(path, extension, output)
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local child = path .. "/" .. name
            local mode = lfs.attributes(child, "mode")
            if mode == "directory" then
                filesWithExtension(child, extension, output)
            elseif mode == "file" and name:sub(-#extension) == extension then
                table.insert(output, child)
            end
        end
    end
end

local function withoutStringContents(value)
    local output, quote, escaped = {}, nil, false
    for index = 1, #value do
        local char = value:sub(index, index)
        if quote then
            if escaped then
                escaped = false
            elseif char == "\\" then
                escaped = true
            elseif char == quote then
                quote = nil
                table.insert(output, char)
            end
        elseif char == '"' or char == "'" then
            quote = char
            table.insert(output, char)
        else
            table.insert(output, char)
        end
    end
    return table.concat(output)
end

local PRIVATE_LOG_EXPRESSIONS = {
    "book%.id", "book%.source_path", "book%.title",
    "bookinfo%.title", "bookinfo%.authors", "self%.db_location",
    "result%.message", "stderr_output", "output:sub",
}

local PRIVATE_LOG_IDENTIFIERS = {
    "file", "filepath", "actual_file", "real_file", "real_path",
    "virtual_path", "epub_path", "source_path", "thumbnail_path",
    "cover_path", "sidecar_dir", "input_path", "output_path", "kfx_path",
    "cache_dir", "root", "asin", "cde_key", "book_id", "err",
    "map_error",
}

describe("diagnostic privacy", function()
    it("does not pass book identifiers, paths, text, or raw errors to logger", function()
        local root = pluginRoot()
        local files = { root .. "/main.lua" }
        luaFiles(root .. "/lua", files)
        for _, path in ipairs(files) do
            local handle = assert(io.open(path, "rb"))
            local content = handle:read("*a")
            handle:close()
            for call in content:gmatch("logger%.%a+%s*%b()") do
                local code = withoutStringContents(call)
                for _, expression in ipairs(PRIVATE_LOG_EXPRESSIONS) do
                    assert.is_nil(code:match(expression),
                        path .. " contains a private logger expression: " .. expression)
                end
                for _, identifier in ipairs(PRIVATE_LOG_IDENTIFIERS) do
                    local pattern = "%f[%w_]" .. identifier .. "%f[^%w_]"
                    assert.is_nil(code:match(pattern),
                        path .. " contains a private logger identifier: " .. identifier)
                end
            end
        end
    end)

    it("does not print helper paths or raw per-book failures", function()
        local root = pluginRoot()
        local files = {}
        filesWithExtension(root .. "/python", ".py", files)
        filesWithExtension(root .. "/scripts", ".py", files)
        local forbidden = {
            "{kfx_path}", "{voucher_path}", "{output_path}", "{rel}",
            "{args.input}", "{args.output}", "{error}", "{e}",
            "{validation_error}",
        }
        for _, path in ipairs(files) do
            local handle = assert(io.open(path, "rb"))
            for line in handle:lines() do
                if line:match("print%s*%(") or line:match("logging%.") then
                    for _, value in ipairs(forbidden) do
                        assert.is_nil(line:find(value, 1, true),
                            path .. " prints private helper data: " .. value)
                    end
                end
            end
            handle:close()
        end
    end)
end)
