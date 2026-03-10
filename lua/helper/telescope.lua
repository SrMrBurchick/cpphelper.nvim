local action_state = require('telescope.actions.state')
local actions = require('telescope.actions')
local conf = require('telescope.config').values
local entry_display = require('telescope.pickers.entry_display')
local finders = require('telescope.finders')
local make_entry = require('telescope.make_entry')
local msvc = require('helper.plugins.msvc_plugin')
local pickers = require('telescope.pickers')
local putils = require('telescope.previewers.utils')
local action_set = require("telescope.actions.set")
local telescope = require("telescope")


local M = {}


local function telescope_buffer_dir()
	return vim.fn.expand('%:p:h')
end

function M.generate_compile_commands(opts)
	local configs = msvc.solution.configurations
	opts = opts or {}

	if nil == configs then
		return
	end

	pickers.new(opts, {
		prompt_title = "Generate compile comands for config",
		finder = finders.new_table {
			results = configs
		},
		previewer = conf.file_previewer(opts),
		sorter = conf.generic_sorter(opts),
		attach_mappings = function(prompt_bufnr, map)
			map('i', '<CR>', function()
				local picker = action_state.get_current_picker(prompt_bufnr)

				-- temporarily register a callback which keeps selection on refresh
				local selection = picker:get_selection_row()
				local entry = picker.manager:get_entry(picker:get_index(selection))
				if nil ~= entry then
					vim.notify("Generating compile commands for config: " .. entry.value)
					msvc.generate_compile_commands(entry.value)
				end

				actions.close(prompt_bufnr)
			end)
			return true
		end,
	}):find()
end

function M.find_solution(opts)
	telescope.extensions.file_browser.file_browser({
		theme = "ivy",
		path = "%:p:h",
		cwd = telescope_buffer_dir(),
		respect_gitignore = false,
		hidden = true,
		grouped = true,
		previewer = false,
		initial_mode = "normal",
		layout_config = { height = 40 },
		attach_mappings = function(prompt_bufnr, map)
			actions.select_default:replace_if(
				-- returns true only for files (not directories)
				function()
					local entry = action_state.get_selected_entry()
					if not entry then return false end
					local path = entry.path or entry[1] or ""
					return not entry.is_dir and vim.fn.isdirectory(path) == 0
				end,
				-- called only when condition is true (file selected)
				function()
					local entry = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if entry then
						local path = entry.path or entry[1]
						vim.notify("Loading soulution: " .. path)
						if msvc.load_solution(path) == false then
							vim.notify("Invalid file: " .. path)
						end
					end
				end
			)
			return true
		end,
	})
end

return M
