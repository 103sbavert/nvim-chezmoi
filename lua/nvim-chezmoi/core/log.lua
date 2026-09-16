--- A simple logging class that uses vim.notify for logging messages.
--- @class NvimChezmoi.Core.Log
--- @field show_debug_logs fun(): boolean If `true`, enables printing debug messages.
local T = {
    show_debug_logs = function() return require("nvim-chezmoi").opts.debug end,
}

local notify = function(message, level)
    vim.schedule(function()
        if type(message) == "string" then
            vim.notify(message, level, { title = "nvim-chezmoi" })
        elseif type(message) == "table" then
            vim.notify(
                table.concat(message, "\n"),
                level,
                { title = "nvim-chezmoi" }
            )
        end
    end)
end

function T.info(message) notify(message, vim.log.levels.INFO) end

function T.debug(message)
    if not T.show_debug_logs() then
        return
    end
    local logLevel = vim.log.levels.DEBUG
    notify(message, logLevel)
end

function T.error(message) notify(message, vim.log.levels.ERROR) end

function T.warn(message) notify(message, vim.log.levels.WARN) end

return T
