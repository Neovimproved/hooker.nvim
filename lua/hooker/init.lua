local M = {}

local cached_hooks
local hooker_buffer, hooker_win = -1, -1

local hooker_directory = vim.fs.joinpath(vim.fn.stdpath("data"), "hooker")
local hook_links_directory = vim.fs.joinpath(hooker_directory, "links")
local hooks_directory = vim.fs.joinpath(hooker_directory, "hooks")

local hooks_file_path, hooks_file_basename, hooks_link_file_path

local mpack = vim.mpack
local separator = package.config:sub(1, 1)

local default_options = require("hooker.default_options")
---@type Options
local hooker_config

---@alias Hooks string[]

---@param a table
---@param b table
local function list_shallow_equal(a, b)
    if #a ~= #b then
        return false
    end

    for i, val in pairs(a) do
        if b[i] ~= val then
            return false
        end
    end

    return true
end

---@param hooks Hooks
local function hooks_empty(hooks)
    return #hooks == 0 or #hooks == 1 and hooks[1] == ""
end

---@param directory string
local function set_hooks_file_path(directory)
    local stat = assert(vim.uv.fs_stat(directory), "Failed to stat directory " .. directory)
    local birthtime = stat.birthtime

    hooks_file_basename = ("%d-%d.%d.mpack"):format(stat.ino, birthtime.sec, birthtime.nsec)
    hooks_file_path = vim.fs.joinpath(hooks_directory, hooks_file_basename)

    local target_dir = hooker_config.target_directory
    target_dir = vim.fs.relpath(vim.fs.normalize("~"), target_dir) or target_dir

    hooks_link_file_path = vim.fs.joinpath(hook_links_directory, vim.fn.sha256(target_dir))

    cached_hooks = nil
end

---@param hooks_link string
---@return string?
local function read_hooks_link(hooks_link)
    if not vim.uv.fs_stat(hooks_link) then
        return
    end

    local file = assert(io.open(hooks_link, "r"), "Failed to open hooks link file")
    local path = file:read("*a")
    file:close()

    return path
end

---@param path string The path of the link
local function write_link(path)
    vim.fn.mkdir(hook_links_directory, "p")
    local file = assert(io.open(path, "w"), "Failed to open hooks link file")
    file:write(hooks_file_basename)
    file:close()
end

local function read_hooker_file(path)
    local hooker_file = assert(io.open(path, "r"), ("Failed to open hooker file (%s)"):format(path))
    local data = hooker_file:read("*a")
    hooker_file:close()
    return mpack.decode(data)
end

local function resolve_hooks_link(hooks_link)
    local link = read_hooks_link(hooks_link)

    if link then
        return vim.fs.joinpath(hooks_directory, link)
    end
end

---@param hooks Hooks
---@return string preview of the hooks
local function preview_hooks(hooks)
    if #hooks <= 10 then
        return table.concat(hooks, ", ")
    else
        local copy = {}
        vim.list_extend(copy, hooks, 1, 9)
        return table.concat(copy, ", ") .. "..."
    end
end

local function calculate_window_geometry()
    local width = math.floor(vim.o.columns * hooker_config.width)
    local height = math.min(vim.o.lines - 1, hooker_config.lines)

    return {
        width = width,
        height = height,

        row = math.floor(math.max(0, vim.o.lines - height - vim.o.cmdheight - 1) / 2),
        col = math.floor((vim.o.columns - width) / 2),
    }
end

local function cache_written_hooks()
    if vim.uv.fs_stat(hooks_file_path) then
        cached_hooks = read_hooker_file(hooks_file_path)
    elseif vim.uv.fs_stat(hooks_link_file_path) then
        local path = resolve_hooks_link(hooks_link_file_path)

        if not vim.uv.fs_stat(path) then
            -- non-existent - assumed to be empty by default
            if hooks_file_path ~= path then
                -- it both doesn't point to what we want and doesn't point to anything that exists, so delete it
                vim.uv.fs_unlink(hooks_link_file_path)
            end

            cached_hooks = {}
            return
        end

        local hooks = read_hooker_file(path)

        local option = vim.fn.confirm(
            ("Would you like to use the hooker file found: '%s'?"):format(preview_hooks(hooks)),
            "&Yes\n&No, create a new hooker file\n&Cancel action",
            3
        )

        if option == 1 then
            cached_hooks = read_hooker_file(path)
            M.write_hooks(cached_hooks)
        elseif option == 2 then
            M.init_empty_hooks()
            write_link(hooks_link_file_path)
        elseif option == 3 then
            vim.notify("Failed to initialize hooks", vim.log.levels.WARN)
        else
            error(("Unexpected response (number %d)"):format(option))
        end
    else
        M.init_empty_hooks()
    end
end

---@param path string? The path? that will be used
local function resolve_file_path_rel(path)
    path = path or vim.api.nvim_buf_get_name(0)
    return vim.fs.relpath(hooker_config.target_directory, path) or path
end

function M.dump_data()
    vim.print("Buffer: " .. hooker_buffer, "Window: " .. hooker_win)
    vim.print("Cached:", cached_hooks)
end

function M.init_empty_hooks()
    if cached_hooks then
        error(("Unintended usage (hooks: %s)"):format(vim.inspect(cached_hooks)))
    end

    cached_hooks = {}
end

---Get the hooks that are written to the disk (but a cache is used for efficiency)
---@return Hooks hooks that are written to the disk
function M.get_written_hooks()
    if not cached_hooks then
        cache_written_hooks()
    end

    return cached_hooks
end

---Check the length
function M.length()
    return #M.get_written_hooks()
end

---Select a given item from the hooks
---@param index integer
function M.select(index)
    local filename

    if vim.api.nvim_win_is_valid(hooker_win) and vim.api.nvim_buf_is_valid(hooker_buffer) then
        filename = vim.api.nvim_buf_get_lines(hooker_buffer, index - 1, index, true)[1]
    else
        filename = M.get_written_hooks()[index]
    end

    if not filename then
        vim.notify(string.format("No file found\nIndex: `%s`", index), vim.log.levels.WARN)
        return
    end

    local file_path = vim.fs.joinpath(hooker_config.target_directory, filename)

    if vim.fn.isdirectory(file_path) == 1 then
        hooker_config.open_directory(file_path)
    elseif vim.api.nvim_buf_get_name(0) == file_path then
        vim.notify("File is already open")
    else
        vim.cmd.edit(file_path)
    end
end

---Reconfigure the current window, checking if it exists before trying to do so
function M.reconfigure_win_checked()
    if vim.api.nvim_win_is_valid(hooker_win) then
        local geometry = calculate_window_geometry()
        local current_config = vim.api.nvim_win_get_config(hooker_win)

        local updated_config = vim.tbl_deep_extend("force", current_config, geometry)

        if vim.deep_equal(updated_config, current_config) then
            return
        end

        vim.api.nvim_win_set_config(hooker_win, updated_config)
    end
end

function M.is_empty()
    return hooks_empty(M.get_written_hooks())
end

---Open the menu buffer to edit, view, and, optionally, go to the hooks
function M.menu()
    local hooks = M.get_written_hooks()

    if vim.api.nvim_win_is_valid(hooker_win) then
        vim.api.nvim_win_close(hooker_win, false)
    end

    local buf = vim.api.nvim_create_buf(false, true)

    vim.bo[buf].filetype = "hooker"
    local initial_undolevels = vim.bo[buf].undolevels
    vim.bo[buf].undolevels = -1
    vim.api.nvim_buf_set_lines(buf, 0, #hooks, false, hooks)
    vim.bo[buf].undolevels = initial_undolevels

    local win = vim.api.nvim_open_win(
        buf,
        true,
        vim.tbl_extend("keep", {
            relative = "editor",
            style = "minimal",
            border = "rounded",
            title = "Hooker",
        }, calculate_window_geometry())
    )

    hooker_buffer = buf
    hooker_win = win

    vim.opt.number = true

    local function close_window()
        vim.api.nvim_win_close(win, true)
    end

    vim.keymap.set("n", "<Esc>", close_window, { buffer = buf, desc = "Close window" })
    vim.keymap.set("n", "q", close_window, { buffer = buf, desc = "Close window" })

    vim.keymap.set("n", "<CR>", function()
        local current_line = vim.api.nvim_win_get_cursor(win)[1]
        M.select(current_line)
    end, { buffer = buf, desc = "Select hook" })
end

---Remove unused hooker files with vim.fn.confirm
function M.prune_hooker_files()
    local handle, err, errname = vim.uv.fs_scandir(hooks_directory)

    if not handle then
        vim.notify(("Failed to start hooker prune with error %s: %s"):format(errname, err), vim.log.levels.ERROR)
        return
    end

    local filename, filetype = vim.uv.fs_scandir_next(handle)

    while filename do
        local abs_path = vim.fs.joinpath(hooks_directory, filename)

        if filetype ~= "file" then
            vim.notify(("Unexpected filetype found in hooks directory (path: %s)"):format(abs_path))
            goto continue
        end

        do
            local option = vim.fn.confirm(
                ("Remove hooker file: '%s'?"):format(preview_hooks(read_hooker_file(abs_path))),
                "&Yes\n&No\n&Stop pruning",
                3
            )

            if option == 1 then
                vim.uv.fs_unlink(abs_path)
            elseif option == 2 then
            -- no op
            elseif option == 3 then
                break
            else
                error(("Unexpected option (%d)"):format(option))
            end
        end

        ::continue::

        filename, filetype = vim.uv.fs_scandir_next(handle)
    end
end

---Remove unused hook links with vim.fn.confirm
function M.prune_links()
    -- TODO: finish prune links impl
    error("Not yet implemented")
    local handle, errname, err = vim.uv.fs_scandir(hook_links_directory)

    if not handle then
        vim.notify(("Failed to start hooker prune with error %s: %s"):format(errname, err), vim.log.levels.ERROR)
        return
    end
end

---@return string Path
function M.get_current_file_relative()
    return resolve_file_path_rel(vim.api.nvim_buf_get_name(0))
end

---Add a file to the hooks; if no path is provided, the path of the current buffer is used
---@param path string? The path of the file that should be added
function M.add_file_ui(path)
    vim.fn.setreg('"', resolve_file_path_rel(path))
    M.menu()
end

function M.add_file(path)
    local hooks = M.get_written_hooks()
    local new_hook = resolve_file_path_rel(path)
    hooks[#hooks + 1] = new_hook
    M.write_hooks(hooks)

    vim.notify("Successfully added " .. new_hook .. " to hooks")
end

---Write the hooks to the disk
---@param hooks Hooks
function M.write_hooks(hooks)
    local hooks_link = resolve_hooks_link(hooks_link_file_path)

    if hooks_link ~= hooks_file_basename then
        write_link(hooks_link_file_path)
    end

    if hooks_empty(hooks) then -- no reason to use a file
        if vim.uv.fs_stat(hooks_file_path) then -- might as well go ahead and delete hooks file
            local ok, err, err_name = vim.uv.fs_unlink(hooks_file_path)

            if not ok then
                vim.notify(
                    ("Unable to update hooker file (%s) with err `%s`: %s:\n"):format(hooks_file_path, err_name, err),
                    vim.log.levels.ERROR
                )
            end
        end

        cached_hooks = hooks

        return
    end

    local ok, result = pcall(mpack.encode, hooks)

    if not ok then
        vim.notify(result, vim.log.levels.ERROR)
        return
    end

    vim.fn.mkdir(hooks_directory, "p")
    local hooker_file = io.open(hooks_file_path, "w")

    if not hooker_file then
        vim.notify("Unable to open hooker file", vim.log.levels.ERROR)
        return
    end

    hooker_file:write(result)
    hooker_file:close()

    cached_hooks = hooks
end

---Save the file paths that are on the current buffer as the hooks for the target directory
function M.save_buffer()
    local hooks = vim.api.nvim_buf_get_lines(hooker_buffer, 0, -1, true)

    local trim_index = #hooks + 1

    for i = #hooks, 1, -1 do
        if #hooks[i] > 0 then
            trim_index = i + 1
            break
        end
    end

    for i = trim_index, #hooks do
        hooks[i] = nil
    end

    for i, hook in ipairs(hooks) do
        if hook:sub(-1) ~= separator and vim.fn.isdirectory(hook) == 1 then
            hooks[i] = hook .. separator
        end
    end

    local written_hooks = M.get_written_hooks()

    if list_shallow_equal(hooks, written_hooks) then
        return
    end

    M.write_hooks(hooks)
end

---Setup the hooker plugin
---@param opts? Options
function M.setup(opts)
    if opts then
        hooker_config = vim.tbl_deep_extend("force", default_options, opts)
    else
        hooker_config = default_options
    end

    _G.Hooker = M

    set_hooks_file_path(hooker_config.target_directory)

    M.options = setmetatable({}, {
        __index = hooker_config,
        __newindex = function(_, key, value)
            hooker_config[key] = value

            if key == "target_directory" then
                set_hooks_file_path(value)
            elseif key == "lines" or key == "width" then
                M.reconfigure_win_checked()
            end
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        callback = function(ev)
            if ev.buf == hooker_buffer and vim.api.nvim_buf_is_valid(hooker_buffer) then
                M.save_buffer()
                vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
            end
        end,
    })

    vim.api.nvim_create_autocmd("VimResized", {
        callback = M.reconfigure_win_checked,
    })
end

return M
