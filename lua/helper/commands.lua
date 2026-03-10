local generate_ctags= require('helper.commands.generate_ctags')
local system = require('system.system')
local msvc = require('helper.plugins.msvc_plugin')
local cpphelper_telescope = require('helper.telescope')

local M = {}

local commands = {
	GenerateCTAGS = function()
		generate_ctags.generate()
	end,
	SystemInstall = function ()
		system.install_libs()
	end,
	LoadSolution = function()
		msvc.load()
	end,
	GenerateCompileCommands = function ()
		msvc.load()
		if msvc.solution == nil then
			cpphelper_telescope.find_solution()
		end

		if msvc.solution ~= nil then
			cpphelper_telescope.generate_compile_commands()
		end
	end
}

function M.commands_list()
	return vim.tbl_keys(commands)
end

function M.load_command(cmd, ...)
	local args = { ... }
	if next(args) ~= nil then
		commands[cmd](args[1])
	else
		commands[cmd]()
	end
end

return M
