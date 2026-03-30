local cpp_notify = require('helper.notify')

local M = {
	solution = {
		root_dir = "",
		projects = {},
		globals = {},
		configurations = {},
		config_map = {}
	},
	generator_path = nil
}

-- Notification handle for the current operation.
local _notif = nil

local function notif_begin(title)
	_notif = cpp_notify.begin(title)
end

local function notif_log(msg, level)
	if _notif then
		_notif:progress(msg, level)
	else
		vim.notify(msg, level)
	end
end

local function notif_done(msg)
	if _notif then
		_notif:finish(msg)
		_notif = nil
	else
		vim.notify(msg or "Done")
	end
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local content = f:read("*all")
	f:close()
	return content
end

function M.get_generator_path()
	if M.generator_path then
		return M.generator_path
	end

	local candidates = {}

	-- 1. Relative to plugin directory (development/local install)
	local info = debug.getinfo(1, "S")
	local src = info.source:sub(2)
	local plugin_root = src:match("(.*[/\\])lua[/\\]")
	if plugin_root then
		table.insert(candidates, plugin_root .. "generator\\target\\debug\\generator.exe")
	end

	-- 2. XDG data directory
	table.insert(candidates, vim.fn.stdpath("data") .. "/cpphelper/generator.exe")

	for _, path in ipairs(candidates) do
		if vim.fn.filereadable(path) == 1 then
			M.generator_path = path
			return path
		end
	end

	-- 4. System PATH
	if vim.fn.executable("generator") == 1 then
		M.generator_path = "generator"
		return "generator"
	end

	vim.notify(
		"cpphelper: generator binary not found.\n"
			.. "Either:\n"
			.. "  1. Build: cd generator && cargo build\n"
			.. "  2. Set generator_path in setup:\n"
			.. "     require('cpphelper').setup({ generator_path = '/path/to/generator' })",
		vim.log.levels.ERROR
	)
	return nil
end

function M.set_generator_path(path)
	M.generator_path = path
end

local function run_generator(args)
	local gen_path = M.get_generator_path()
	if not gen_path then
		return false, { "Generator binary not found" }
	end
	local cmd = vim.list_extend({ gen_path }, args)
	local result = { stdout = {}, stderr = {} }

	local job_id = vim.fn.jobstart(cmd, {
		on_stdout = function(_, data)
			result.stdout = data
		end,
		on_stderr = function(_, data)
			result.stderr = data
		end,
		on_exit = function(_, code)
			result.exit_code = code
		end,
	})

	if job_id <= 0 then
		return false, { "Failed to start generator" }
	end

	vim.fn.jobwait({ job_id })

	if result.exit_code ~= 0 then
		local output = vim.tbl_filter(function(l) return l ~= "" end, result.stderr)
		if #output == 0 then
			output = vim.tbl_filter(function(l) return l ~= "" end, result.stdout)
		end
		return false, output
	end

	return true, result.stderr
end

function M.load_solution(path)
	notif_begin("Loading Solution")

	local ext = path:match("^.+(%..+)$")
	if ext ~= ".sln" and ext ~= ".slnx" then
		notif_done("Unsupported file type: " .. tostring(ext))
		return false
	end

	local cwd = vim.fn.getcwd()
	local cache_dir = cwd .. "/.cache"
	if vim.fn.isdirectory(cache_dir) == 0 then
		vim.fn.mkdir(cache_dir, "p")
	end

	local ok, output = run_generator({ "load", path, cache_dir })

	for _, line in ipairs(output) do
		if line ~= "" then
			notif_log(line)
		end
	end

	if not ok then
		notif_done("Failed to parse solution")
		return false
	end

	M.load()
	return true
end

function M.generate_compile_commands(target_solution_config)
	notif_begin("Generating compile_commands.json")

	local cwd = vim.fn.getcwd()
	local solution_json = cwd .. "/.cache/helper.json"
	local output_path = cwd .. "/compile_commands.json"

	local args = { "compile-commands", target_solution_config or "all", solution_json, output_path }
	local ok, output = run_generator(args)

	for _, line in ipairs(output) do
		if line ~= "" then
			notif_log(line)
		end
	end

	if not ok then
		notif_done("Failed to generate compile_commands.json")
		return false
	end

	notif_done("Generated: " .. output_path .. " for " .. (target_solution_config or "all"))
	return true
end

function M.load()
	local output_name = ".cache/helper.json"
	local content = read_file(output_name)
	if not content then
		notif_log("No cache found at " .. output_name, vim.log.levels.WARN)
		return false
	end
	M.solution = vim.json.decode(content)
	if M.solution ~= nil then
		notif_done("Project was successfully loaded")
	end
end

return M
