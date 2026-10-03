local command = require("nvim-chezmoi.chezmoi.command")
local chezmoi_cache = require("nvim-chezmoi.chezmoi.cache")
local chezmoi_decrypt = require("nvim-chezmoi.chezmoi.commands.decrypt")
local chezmoi_execute_template =
    require("nvim-chezmoi.chezmoi.commands.execute_template")
local chezmoi_helper = require("nvim-chezmoi.chezmoi.helper")
local log = require("nvim-chezmoi.core.log")
local async = require("nvim-chezmoi.core.async")

---Cached contents of gotmpl_injection.scm (lazy-loaded, module-local).
local gotmpl_injection_tpl = nil

---@class ChezmoiEdit: ChezmoiCommand
local M = setmetatable({
    cmd = "edit",
}, {
    __index = command,
})

function M:init(opts)
    self.opts = opts
    self:create_user_commands()
end

function M:on_edit(bufnr)
    chezmoi_execute_template:create_buf_user_commands(bufnr)

    self:create_buf_user_commands(bufnr)
    self:detect_filetype(bufnr)
    if
        type(self.opts.edit.apply_on_save) ~= nil
        and self.opts.edit.apply_on_save ~= "never"
    then
        self:create_autocmds(bufnr)
    end
end

---@return ChezmoiAutoCommand[]
function M:autoCommands(bufnr)
    return {
        {
            event = "BufWritePost",
            opts = {
                group = "ApplyOnSave",
                buffer = bufnr,
                callback = function(ev)
                    local apply = function()
                        local result = require(
                            "nvim-chezmoi.chezmoi.commands.target_path"
                        ):exec({
                            ev.file,
                        })
                        if
                            result.success
                            and require("nvim-chezmoi.chezmoi.commands.apply"):exec({
                                result.data[1],
                            }).success
                        then
                            log.info("Applied " .. result.data[1])
                        end
                    end

                    if self.opts.edit.apply_on_save == "confirm" then
                        local choice = vim.ui.select({ "Yes", "No" }, {
                            prompt = "Apply " .. ev.file .. "?",
                        }, function(_, choice_idx)
                            if choice_idx == 1 then
                                apply()
                            end
                        end)
                    elseif self.opts.edit.apply_on_save == "auto" then
                        apply()
                    end
                end,
            },
        },
    }
end

---@param bufnr integer
---@return ChezmoiUserCommand[]
function M:bufUserCommands(bufnr)
    return {
        {
            name = "ChezmoiDetectFiletype",
            desc = "Detects filetype for a source file based on the target file name.",
            callback = function() self:detect_filetype(bufnr) end,
        },
    }
end

---@return ChezmoiUserCommand[]
function M:userCommands()
    return {
        {
            name = "ChezmoiEdit",
            desc = "Edit a chezmoi file.",
            callback = function(cmd)
                local file
                if #cmd.fargs > 0 then
                    file = cmd.fargs[1]
                else
                    file = vim.api.nvim_buf_get_name(0)
                end
                M:exec(file)
            end,
            opts = {
                nargs = "?",
            },
        },
    }
end

---Opens the specified `file` in new buffer.
---@param file string
---@return ChezmoiCommandResult|nil
function M:exec(file)
    file = vim.fs.normalize(file)
    local result =
        require("nvim-chezmoi.chezmoi.commands.source_path"):exec({ file })
    if not result.success then
        return result
    end

    file = result.data[1]

    if chezmoi_helper.is_encrypted(file) then
        vim.schedule(function()
            local decrypt_result = chezmoi_decrypt:exec(file)
            if decrypt_result.success then
                local bufnr = decrypt_result.data[1]
                if bufnr ~= -1 then
                    self:on_edit(bufnr)
                    log.warn("Consider using `chezmoi edit` instead.")
                end
            end
        end)
    else
        vim.cmd.edit(file)
    end
end

---Opens the specified `file` in a new buffer asynchronously.
---Identical to `exec` but replaces the blocking `source_path:exec` call
---with `source_path:async`, so the caller is not blocked.
---@param file string
---@param callback? fun(result: ChezmoiCommandResult)
---@return vim.SystemObj Process handle.
function M:async(file, callback)
    file = vim.fs.normalize(file)
    local job = require("nvim-chezmoi.chezmoi.commands.source_path"):async(
        { file },
        function(result)
            if not result.success then
                if type(callback) == "function" then
                    callback(result)
                end
                return
            end

            file = result.data[1]

            if chezmoi_helper.is_encrypted(file) then
                local decrypt_result = chezmoi_decrypt:exec(file)
                if decrypt_result.success then
                    local bufnr = decrypt_result.data[1]
                    if bufnr ~= -1 then
                        self:on_edit(bufnr)
                        log.warn("Consider using `chezmoi edit` instead.")
                    end
                end
                if type(callback) == "function" then
                    callback(decrypt_result)
                end
            else
                vim.cmd.tabedit(file)
                if type(callback) == "function" then
                    callback({ args = {}, success = true, data = {} })
                end
            end
        end
    )

    return job
end

---Reads gotmpl_injection.scm once and caches it.
---@return string?
local function get_gotmpl_injection_tpl()
    if gotmpl_injection_tpl then
        return gotmpl_injection_tpl
    end

    local path = vim.api.nvim_get_runtime_file("gotmpl_injection.scm", false)[1]
    if not path then
        log.warn(
            "gotmpl_injection.scm not found on runtimepath, treesitter attach skipped for buffer"
        )
        return nil
    end

    gotmpl_injection_tpl = table.concat(vim.fn.readfile(path), "\n")
    return gotmpl_injection_tpl
end

local function is_template_ft(ft, filename)
    if filename and filename ~= "" and not filename:match("%.tmpl$") then
        return false
    end
    return ft == "template" or ft == "gotmpl" or ft == "tmpl"
end

---@param buf integer
---@param target_ft string
function M:attach_gotmpl_ts(buf, target_ft)
    if not vim.api.nvim_buf_is_valid(buf) then
        log.debug(
            "gotmpl treesitter attach skipped: buffer "
                .. tostring(buf)
                .. " is no longer valid"
        )
        return
    end

    if target_ft == "" or target_ft == "gotmpl" then
        log.debug(
            "gotmpl treesitter attach skipped for buffer "
                .. buf
                .. ": no distinct target filetype to inject (target_ft="
                .. tostring(target_ft)
                .. ")"
        )
        return
    end

    if not vim.treesitter.language.add("gotmpl") then
        log.warn(
            "gotmpl treesitter parser is not installed; cannot attach dual"
                .. " gotmpl/"
                .. target_ft
                .. " highlighting for buffer "
                .. buf
        )
        return
    end

    if not pcall(vim.treesitter.language.add, target_ft) then
        log.debug(
            "no treesitter parser installed for target filetype '"
                .. target_ft
                .. "'; attaching gotmpl-only highlighting for buffer "
                .. buf
        )
        vim.treesitter.start(buf, "gotmpl")
        return
    end

    local tpl = get_gotmpl_injection_tpl()
    if not tpl then
        return
    end
    local injections = string.format(tpl, target_ft)

    local ok, parser, err = pcall(vim.treesitter.get_parser, buf, "gotmpl", {
        injections = { gotmpl = injections },
    })
    if not ok or not parser then
        log.warn(
            "failed to create combined gotmpl/"
                .. target_ft
                .. " parser for buffer "
                .. buf
                .. ": "
                .. tostring(err)
        )
        return
    end

    vim.treesitter.highlighter.new(parser)
    log.debug(
        "attached gotmpl treesitter parser to buffer "
            .. buf
            .. " with '"
            .. target_ft
            .. "' injected (combined) into (text) regions"
    )
end

---Detects and sets filetype for `buf` using various heuristics
---@param buf integer
function M:detect_filetype(buf)
    local source_file = vim.api.nvim_buf_get_name(buf)

    log.debug(
        "detect_filetype: starting detection for buffer "
            .. buf
            .. " (source file '"
            .. source_file
            .. "')"
    )

    local is_tmpl_ext = source_file:match("%.tmpl$")

    local set_file_type = vim.schedule_wrap(function(ft)
        if is_tmpl_ext then
            local compound_ft = (ft and ft ~= "" and ft .. "." or "")
                .. "gotmpl"
            log.debug(
                "setting filetype of buffer "
                    .. buf
                    .. " to '"
                    .. compound_ft
                    .. "' (was '"
                    .. vim.bo[buf].filetype
                    .. "')"
            )

            if vim.bo[buf].filetype ~= compound_ft then
                vim.bo[buf].filetype = compound_ft
            end
            self:attach_gotmpl_ts(buf, ft)

            return
        end

        if vim.bo[buf].filetype ~= ft then
            log.debug(
                "setting filetype of buffer "
                    .. buf
                    .. " to '"
                    .. ft
                    .. "' (was '"
                    .. vim.bo[buf].filetype
                    .. "')"
            )

            vim.bo[buf].filetype = ft
        end

        self:attach_gotmpl_ts(buf, ft)
    end)

    if
        not is_tmpl_ext
        and vim.bo[buf].filetype ~= ""
        and not is_template_ft(vim.bo[buf].filetype)
    then
        log.debug(
            "Non-template source file '"
                .. vim.fs.basename(source_file)
                .. "' already has a filetype '"
                .. vim.bo[buf].filetype
                .. "'; using it directly"
        )

        return
    end

    local ok, s = pcall(vim.api.nvim_buf_get_var, buf, "encrypted_source_path")
    if ok then
        log.debug(
            "buffer "
                .. buf
                .. " is a decrypted scratch buffer; using its"
                .. " encrypted_source_path '"
                .. s
                .. "' for filetype detection instead of '"
                .. source_file
                .. "'"
        )
        source_file = s
    end

    -- Try cache first
    local cached = chezmoi_cache.find_success("ft_detect", { source_file })

    if cached ~= nil then
        local ft = cached.result.data.ft
        if ft ~= vim.bo[buf].filetype then
            log.debug(
                "ft_detect cache hit for '"
                    .. source_file
                    .. "': filetype '"
                    .. tostring(ft)
                    .. "'"
            )
            set_file_type(ft)
            return
        end

        log.debug(
            "ft_detect cache hit for '"
                .. source_file
                .. "' matches current buffer filetype '"
                .. tostring(vim.bo[buf].filetype)
                .. "'; skipping redundant set_file_type"
        )
    else
        log.debug(
            "no ft_detect cache entry for '"
                .. source_file
                .. "'; resolving target path to derive filetype"
        )
    end

    -- Get target path for source file, then derive the filetype from it.
    local target_path = require("nvim-chezmoi.chezmoi.commands.target_path")
    async.run(function()
        local target_file_result = async.await(
            function(cb) target_path:async({ source_file }, cb) end
        )
        if not target_file_result.success then
            log.warn(
                "could not resolve target path for source file '"
                    .. source_file
                    .. "'; skipping filetype detection"
            )
            return
        end

        local target_file = target_file_result.data[1]
        log.debug(
            "resolved target path '"
                .. target_file
                .. "' for source file '"
                .. source_file
                .. "'"
        )

        -- Try match
        local ft = vim.filetype.match({ filename = target_file }) or ""

        -- Could't find the filetype, try temp buf
        if ft == "" then
            log.debug(
                "filename-based match on target path '"
                    .. target_file
                    .. "' found nothing; probing loaded buffers for a"
                    .. " match"
            )

            local existing = -1
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if vim.api.nvim_buf_get_name(b) == target_file then
                    existing = b
                    break
                end
            end
            if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
                log.debug(
                    "found existing buffer "
                        .. existing
                        .. " for target path '"
                        .. target_file
                        .. "'; matching filetype from its contents"
                )
                ft = vim.filetype.match({ buf = existing }) or ""
            else
                log.debug(
                    "no existing buffer for target path '"
                        .. target_file
                        .. "'; matching filetype using a scratch buffer"
                )
                local tmp_buf = vim.api.nvim_create_buf(true, true)
                vim.api.nvim_buf_set_name(tmp_buf, target_file)
                ft = vim.filetype.match({ buf = tmp_buf }) or ""
                vim.api.nvim_buf_delete(tmp_buf, { force = true })
            end
        end

        if ft ~= "" then
            if
                vim.api.nvim_buf_is_valid(buf)
                and vim.api.nvim_buf_get_name(buf) == source_file
                and vim.bo[buf].filetype ~= ft
            then
                log.debug(
                    "target-path based detection resolved filetype '"
                        .. ft
                        .. "' for source file '"
                        .. source_file
                        .. "'"
                )
                set_file_type(ft)
            else
                log.debug(
                    "target-path based detection resolved filetype '"
                        .. ft
                        .. "' for '"
                        .. source_file
                        .. "', but buffer "
                        .. buf
                        .. " no longer matches (renamed/closed) or already"
                        .. " has that filetype; not reassigning"
                )
            end

            vim.filetype.add({
                filename = {
                    [vim.fs.basename(source_file)] = ft,
                },
            })

            -- Cache it
            chezmoi_cache.new("ft_detect", { source_file }, {
                args = {},
                success = true,
                data = { ft = ft },
            })
            log.debug(
                "cached ft_detect result '"
                    .. ft
                    .. "' for source file '"
                    .. source_file
                    .. "'"
            )
        else
            log.warn(
                "could not determine filetype for target file '"
                    .. target_file
                    .. "' (source file '"
                    .. source_file
                    .. "')"
            )
        end
    end)
end

return M
