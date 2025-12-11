---@alias Autoread.CursorBehavior
---| "preserve" Keep cursor at its current position
---| "scroll_down" Scroll to the bottom after reload
---| "none" Let Neovim handle cursor position naturally

---@alias Autoread.Events
---| "AutoreadPreCheck" Before checking files
---| "AutoreadPostCheck" After checking files
---| "AutoreadPreReload" Before reloading changed files
---| "AutoreadPostReload" After reloading changed files

---@class Autoread.Config
---@field interval integer? Checks for changes every `interval` milliseconds
---@field notify_on_change boolean? Whether to notify when a file is reloaded
---@field cursor_behavior Autoread.CursorBehavior? How to handle cursor position after file reload

---@class Autoread.ConfigStrict
---@field interval integer Checks for changes every `interval` milliseconds
---@field notify_on_change boolean Whether to notify when a file is reloaded
---@field cursor_behavior Autoread.CursorBehavior How to handle cursor position after file reload

---@class Autoread.MonitoredBuffer
---@field bufnr integer
---@field cursor_behavior Autoread.CursorBehavior
---@field private _cursor_handler fun(bufnr: integer, cursor: integer[])?

---@alias Autoread.CursorHandlerCallback fun(bufnr: integer)

---@class Autoread.Meta
---@field config Autoread.ConfigStrict
---@field private _timer uv.uv_timer_t?
---@field private _monitored_buffers Autoread.MonitoredBuffer[]
local M = {
	_monitored_buffers = {},
}


---@type Autoread.ConfigStrict
local default_config = {
	interval = 500,
	notify_on_change = true,
	cursor_behavior = "preserve",
}

local function notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "Autoread" })
end

---@param interval integer?
local function assert_interval(interval)
	assert(type(interval) == "number", "interval must be a number")
	assert(interval > 0, "interval must be greater than 0")
end

---@param bufnr integer?
local function assert_bufnr(bufnr)
	assert(type(bufnr) == "number", "bufnr must be a number")
	assert(vim.api.nvim_buf_is_valid(bufnr), "bufnr must be a valid buffer")
end

---@param cursor_behavior Autoread.CursorBehavior? How to handle cursor position after file reload
local function assert_cursor_behavior(cursor_behavior)
	assert(
		type(cursor_behavior) == "string",
		"cursor_behavior must be a string"
	)

	local valid_behaviors = {
		preserve = true,
		scroll_down = true,
		none = true,
	}

	assert(
		valid_behaviors[cursor_behavior],
		"cursor_behavior must be one of: 'preserve', 'scroll_down', or 'none'"
	)
end

local get_current_buffer = vim.api.nvim_get_current_buf

local function should_timer_stop()
	return vim.tbl_isempty(M._monitored_buffers)
end

---@param event Autoread.Events|string
---@param opts vim.api.keyset.exec_autocmds?
local function exec_autocmds(event, opts)
	vim.api.nvim_exec_autocmds(
		"User",
		vim.tbl_deep_extend("force", { pattern = event }, opts or {})
	)
end

local function trigger_reload()
	exec_autocmds("AutoreadPreCheck")
	for bufnr, _ in pairs(M._monitored_buffers) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			local ok, _ = pcall(vim.api.nvim_buf_call, bufnr, function()
				vim.api.nvim_command("checktime")
			end)
			if not ok then
				-- Buffer became invalid during call, remove from monitored list
				M._monitored_buffers[bufnr] = nil
			end
		else
			-- Buffer no longer valid, remove from monitored list
			M._monitored_buffers[bufnr] = nil
		end
	end
	exec_autocmds("AutoreadPostCheck")
end

---@param interval integer? Checks for changes every `interval` milliseconds *(default: M.config.interval)*
---@return uv.uv_timer_t timer Timer instance or nil if creation failed
local function create_timer(interval)
	local timer = vim.uv.new_timer()
	if timer then
		timer:start(
			0,
			interval or M.config.interval,
			vim.schedule_wrap(trigger_reload)
		)
	end

	assert(timer ~= nil, "Timer could not be created.")

	return timer
end

---@param interval integer?
---@return uv.uv_timer_t timer
local function ensure_timer(interval)
	if M._timer == nil then
		M._timer = create_timer(interval)
	end

	return M._timer
end

local function close_timer()
	if M._timer then
		M._timer:close()
		M._timer = nil
	end
end

--- Always returns a valid buffer number, if none is provided, the current buffer is used
---@param bufnr integer?
local function ensure_bufnr(bufnr)
	if bufnr ~= nil then
		assert_bufnr(bufnr)
	else
		bufnr = get_current_buffer()
	end

	return bufnr
end

---@param bufnr integer
---@return boolean
local function is_buffer_monitored(bufnr)
	return M._monitored_buffers[bufnr] ~= nil
end

---@param bufnr integer
---@return Autoread.MonitoredBuffer
local function get_monitored_buffer(bufnr)
	return M._monitored_buffers[bufnr]
		or assert(
			"Buffer "
				.. tostring(bufnr)
				.. " is not being monitored by Autoread."
		)
end

---@param bufnr integer
local function start_monitoring_buffer(bufnr)
	if not is_buffer_monitored(bufnr) then
		M._monitored_buffers[bufnr] = {
			bufnr = bufnr,
			cursor_behavior = M.config.cursor_behavior,
		}
	end
end

---@param bufnr integer
local function stop_monitoring_buffer(bufnr)
	if is_buffer_monitored(bufnr) then
		M._monitored_buffers[bufnr] = nil
	end
end

local function stop_monitoring_all_buffers()
	M._monitored_buffers = {}
end

---@param interval integer Checks for changes every `interval` milliseconds
function M.set_interval(interval)
	assert_interval(interval)
	M.config.interval = interval
end

function M.get_interval()
	return M.config.interval
end

---@param interval integer? Temporary interval in ms that doesn't affect the config
function M.update_interval(interval)
	if M.is_enabled() then
		M._timer:stop()
		M._timer:start(
			0,
			interval or M.config.interval,
			vim.schedule_wrap(trigger_reload)
		)
	end
end

---@param interval integer? Temporary interval in ms that doesn't affect the config
---@param bufnr integer? Buffer to enable autoread for (default: current buffer)
function M.enable(interval, bufnr)
	if interval then
		assert_interval(interval)
	end
	ensure_timer(interval)
	start_monitoring_buffer(ensure_bufnr(bufnr))
end

---@param bufnr integer? Buffer to enable autoread for (default: current buffer)
function M.disable(bufnr)
	stop_monitoring_buffer(ensure_bufnr(bufnr))

	if should_timer_stop() then
		close_timer()
	end
end

function M.disable_all()
	stop_monitoring_all_buffers()
	close_timer()
end

---@param interval integer? Optional temporary interval in milliseconds (doesn't change default config)
---@param bufnr integer? Optional buffer to enable autoread for (default: current buffer)
function M.toggle(interval, bufnr)
	if interval then
		assert_interval(interval)
	end

	if M.is_enabled(bufnr) then
		M.disable(bufnr)
	else
		M.enable(interval, bufnr)
	end
end

---@param bufnr integer?
---@return boolean
function M.is_enabled(bufnr)
	return is_buffer_monitored(ensure_bufnr(bufnr))
end

---@param cursor_behavior Autoread.CursorBehavior? How to handle cursor position after file reload
---@param bufnr integer? Buffer to set cursor behavior for (default: current buffer)
function M.set_cusor_behavior(cursor_behavior, bufnr)
	assert_cursor_behavior(cursor_behavior)
	---@cast cursor_behavior Autoread.CursorBehavior

	local ok, result = pcall(get_monitored_buffer, ensure_bufnr(bufnr))
	if not ok then
		notify(error, vim.log.levels.WARN)
		return
	end

	result.cursor_behavior = cursor_behavior
	M.config.cursor_behavior = cursor_behavior
end

---@param cursor_behavior Autoread.CursorBehavior? How to handle cursor position after file reload
function M.set_global_cusor_behavior(cursor_behavior)
	assert_cursor_behavior(cursor_behavior)
	---@cast cursor_behavior Autoread.CursorBehavior

	vim.tbl_map(function(buffer)
		buffer.cursor_behavior = cursor_behavior
	end, M._monitored_buffers)

	M.config.cursor_behavior = cursor_behavior
end

---@class Autoread._WindowState
---@field cursor integer[]

---@alias Autoread.WindowStates Autoread._WindowState[]

---@param bufnr integer
---@return Autoread.WindowStates
local function get_window_states(bufnr)
	assert_bufnr(bufnr)
	local window_ids = vim.fn.win_findbuf(bufnr) or {}
	return vim.tbl_map(function(win)
		return {
			-- TODO: i would like to save the scroll height aswell
			cursor = vim.api.nvim_win_get_cursor(win),
		}
	end, window_ids)
end

---@param window_states Autoread.WindowStates
---@return Autoread.CursorHandlerCallback
local function cursor_perserve_handler(window_states)
	return function(bufnr)
		assert_bufnr(bufnr)
		local window_ids = vim.fn.win_findbuf(bufnr) or {}
		for _, window_id in ipairs(window_ids) do
			local window_state = window_states[window_id]
			if not window_state then
				return
			end

			pcall(vim.api.nvim_win_set_cursor, window_id, window_state.cursor)
		end
	end
end

---@return Autoread.CursorHandlerCallback
local function cursor_scroll_down_handler()
	return function(bufnr)
		assert_bufnr(bufnr)
		local window_ids = vim.fn.win_findbuf(bufnr) or {}
		for _, window_id in ipairs(window_ids) do
			vim.api.nvim_win_call(window_id, function()
				vim.cmd("normal! Gzb")
			end)
		end
	end
end

---@param bufnr integer
---@return Autoread.CursorHandlerCallback
local function create_cursor_handler(bufnr)
	local monitored_buffer = get_monitored_buffer(bufnr)
	assert(
		monitored_buffer,
		string.format(
			"Buffer %s is not being monitored by Autoread.",
			tostring(bufnr)
		)
	)

	local cursor_behavior = monitored_buffer.cursor_behavior

	if cursor_behavior == "preserve" then
		local window_states = get_window_states(bufnr)
		return cursor_perserve_handler(window_states)
	elseif cursor_behavior == "scroll_down" then
		return cursor_scroll_down_handler()
	end

	return function() end
end

local function setup_events()
	local group = vim.api.nvim_create_augroup("AutoreadGroup", {})

	---@type Autoread.CursorHandlerCallback?
	local cursor_handler_fn

	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = group,
		callback = function(event)
			if M.is_enabled() and event and event.file then
				local has_content = vim.api.nvim_buf_line_count(event.buf) > 1
				if has_content then
					exec_autocmds("AutoreadPreReload", { data = event })
				end

				if M.config.notify_on_change then
					notify(
						string.format("File changed on disk: %s", event.file)
					)
				end

				if has_content then
					if cursor_handler_fn then
						cursor_handler_fn(event.buf)
						cursor_handler_fn = nil
					end
					cursor_handler_fn = create_cursor_handler(event.buf)

					exec_autocmds("AutoreadPostReload", { data = event })
				end
			end
		end,
	})
end

local function create_user_commands()
	local create_command = vim.api.nvim_create_user_command

	local function notify_status(status, interval)
		local msg = status
		if interval then
			assert_interval(interval)
			msg = string.format("%s (interval: %dms)", msg, interval)
		end
		notify(msg)
	end

	create_command("Autoread", function(opts)
		local interval = tonumber(opts.args)

		if M.is_enabled() and interval then
			M.update_interval(interval)
		else
			M.toggle(interval)
		end

		if M.is_enabled() then
			notify_status("enabled for buffer", interval)
		else
			notify_status("disabled for buffer")
		end
	end, {
		nargs = "?",
		desc = "Toggle autoread or update interval. With [interval]: updates timer if enabled, enables with interval if disabled",
	})

	create_command("AutoreadOn", function(opts)
		local interval = tonumber(opts.args)
		M.enable(interval)
		notify_status("enabled for buffer", interval)
	end, {
		nargs = "?",
		desc = "Enable autoread with optional temporary interval in milliseconds",
	})

	create_command("AutoreadOff", function()
		M.disable()
		notify("disabled for buffer")
	end, {
		desc = "Disable autoread",
	})

	create_command("AutoreadAllOff", function()
		M.disable_all()
		notify("disabled")
	end, {
		desc = "Disable autoread",
	})

	create_command("AutoreadCursorBehavior", function(opts)
		local cursor_behavior = opts.args
		M.set_cusor_behavior(cursor_behavior)
		notify("set the cursor behavior for buffer to: " .. cursor_behavior)
	end, {
		nargs = 1,
		desc = "Set cursor behavior",
		complete = function()
			return { "preserve", "scroll_down", "none" }
		end,
	})

	create_command("AutoreadGlobalCursorBehavior", function(opts)
		local cursor_behavior = opts.args
		M.set_global_cusor_behavior(cursor_behavior)
		notify("set the cursor behavior to: " .. cursor_behavior)
	end, {
		nargs = 1,
		desc = "Set cursor behavior",
		complete = function()
			return { "preserve", "scroll_down", "none" }
		end,
	})
end

local function validate_config(config)
	assert_interval(config.interval)

	assert(
		type(config.notify_on_change) == "boolean",
		"notify_on_change must be a boolean"
	)

	assert_cursor_behavior(config.cursor_behavior)
end

---@param user_config Autoread.Config?
function M.setup(user_config)
	M.config = vim.tbl_deep_extend("force", default_config, user_config or {})
	validate_config(M.config)

	create_user_commands()
	setup_events()
end

return M
