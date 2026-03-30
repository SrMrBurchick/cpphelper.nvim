--- Progress notification helper for cpphelper.nvim
--- Modelled after https://github.com/mrded/nvim-lsp-notify
--- Provides a single-window, spinner-animated notification that updates in-place.

---@class CppHelperNotifyConfig
local options = {
	--- Function used for notifications.
	--- Works best when vim.notify is already overridden by require('notify').
	--- Pass `notify = require('notify')` explicitly if needed.
	notify = vim.notify,

	--- Override in-place replace detection. nil = auto-detect.
	--- Set to true if auto-detection fails with nvim-notify installed.
	replace = nil,

	---@type {spinner: string[] | false, done: string | false} | false
	icons = {
		--- Spinner animation frames. Set to `false` to disable.
		spinner = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
		--- Icon shown on completion. Set to `false` to disable.
		done = "✓",
	},
}

--- Whether the current notify backend supports in-place replacement.
--- true when nvim-notify is active; false when using the built-in cmdline.
--- nil means not yet detected.
local supports_replace = nil

--- Test-send a hidden notification and try to replace it.
---@return boolean
local function check_supports_replace()
	local result = false
	local checked = false
	local probe = options.notify("cpphelper: probe", vim.log.levels.DEBUG, {
		hide_from_history = true,
		on_open = function(win)
			-- Shrink to invisible so it does not flash on screen
			pcall(function()
				vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(false, true))
				vim.api.nvim_win_set_config(win, {
					width = 1, height = 1, border = "none",
					relative = "editor", row = 0, col = 0,
				})
			end)
			-- Replace must happen after on_open so the notification exists
			vim.schedule(function()
				result = pcall(options.notify, "cpphelper: probe", vim.log.levels.DEBUG, {
					replace = probe,
				})
				checked = true
			end)
		end,
		timeout = false,
		animate = false,
	})
	-- on_open fires synchronously for nvim-notify but the pcall inside is
	-- deferred.  For built-in vim.notify on_open never fires and probe is nil.
	-- Either way, fall back to probe ~= nil as a reliable indicator.
	if not checked then
		return probe ~= nil
	end
	return result
end

--- Ensure supports_replace has been resolved (lazy detection).
local function ensure_detected()
	if supports_replace == nil then
		if options.replace ~= nil then
			supports_replace = options.replace
		else
			supports_replace = check_supports_replace()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Task
-- ---------------------------------------------------------------------------

---@class CppHelperTask
local Task = {
	title   = "",
	message = "",
}

---@param title string
---@param message string?
---@return CppHelperTask
function Task.new(title, message)
	local self = vim.deepcopy(Task)
	self.title   = title
	self.message = message or ""
	return self
end

function Task:format()
	return "  "
		.. (self.title or "")
		.. (self.title ~= "" and self.message ~= "" and " — " or "")
		.. (self.message or "")
end

-- ---------------------------------------------------------------------------
-- Notification handle
-- ---------------------------------------------------------------------------

---@class CppHelperNotification
local Notification = {
	title        = "CppHelper",
	spinner_idx  = 1,
	notification = nil,  -- nvim-notify handle
	window       = nil,  -- floating window handle
	task         = nil,  ---@type CppHelperTask
}

---@param title string?
---@return CppHelperNotification
function Notification:new(title)
	local o = vim.deepcopy(Notification)
	o.title = title or "CppHelper"
	return o
end

function Notification:_spinner_icon()
	if options.icons and options.icons.spinner then
		return options.icons.spinner[self.spinner_idx]
	end
end

function Notification:_advance_spinner()
	if options.icons and options.icons.spinner then
		self.spinner_idx = (self.spinner_idx % #options.icons.spinner) + 1
	end
end

function Notification:_body()
	return self.task and self.task:format() or ""
end

--- Start the notification (begin phase).
function Notification:start()
	ensure_detected()
	self.spinner_idx = 1
	self.notification = options.notify(" ", vim.log.levels.INFO, {
		title             = self.title,
		icon              = self:_spinner_icon(),
		timeout           = false,
		hide_from_history = false,
		on_open = function(win)
			self.window = win
		end,
	})
	-- Kick off spinner animation
	self:_tick_spinner()
end

--- Advance spinner animation (runs via vim.defer_fn while notification lives).
function Notification:_tick_spinner()
	if not self.notification then return end
	self:_advance_spinner()
	if supports_replace and options.icons and options.icons.spinner then
		self.notification = options.notify(self:_body(), vim.log.levels.INFO, {
			hide_from_history = true,
			icon              = self:_spinner_icon(),
			replace           = self.notification,
		})
	end
	vim.defer_fn(function()
		self:_tick_spinner()
	end, 100)
end

--- Update the notification with a new progress message.
---@param msg string
---@param level integer?
function Notification:progress(msg, level)
	self.task = Task.new("", msg)
	if supports_replace then
		self.notification = options.notify(self:_body(), level or vim.log.levels.INFO, {
			title             = self.title,
			replace           = self.notification,
			hide_from_history = true,
		})
		if self.window then
			pcall(vim.api.nvim_win_set_height, self.window, 3)
		end
	end
end

--- Finish the notification (done phase).
---@param msg string?
function Notification:finish(msg)
	self.task = Task.new("", msg or "Done")
	options.notify(self:_body(), vim.log.levels.INFO, {
		title             = self.title,
		icon              = (options.icons and options.icons.done) or nil,
		replace           = self.notification,
		timeout           = 3000,
		hide_from_history = false,
	})
	if self.window then
		pcall(vim.api.nvim_win_set_height, self.window, 3)
	end
	-- Stop spinner by clearing the handle
	self.notification = nil
	self.window       = nil
	self.task         = nil
end

-- ---------------------------------------------------------------------------
-- Public module API
-- ---------------------------------------------------------------------------

local M = {}

--- Configure the module.
---@param opts CppHelperNotifyConfig?
function M.setup(opts)
	options          = vim.tbl_deep_extend("force", options, opts or {})
	if options.replace ~= nil then
		supports_replace = options.replace
	else
		-- Reset so ensure_detected() will re-probe with the new options
		supports_replace = true
	end
end

--- Create and return a new progress notification.
--- Call :progress(msg) to update and :finish(msg) to close.
---@param title string?
---@return CppHelperNotification
function M.begin(title)
	local n = Notification:new(title)
	n:start()
	return n
end

return M
