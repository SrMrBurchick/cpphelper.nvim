local api = vim.api
local cpphelper_opts = require('helper.opts')
local cpphelper_telescope = require('helper.telescope')
local cpp_notify = require('helper.notify')
local msvc = require('helper.plugins.msvc_plugin')

local M = {
	opts = cpphelper_opts,
	telescope = cpphelper_telescope
}

M.cpphelper_augroup = api.nvim_create_augroup('CPPHelper', { clear = true })

function M.setup(opts)
	opts = opts or {}
	cpp_notify.setup(opts)
	if opts.generator_path then
		msvc.set_generator_path(opts.generator_path)
	end
end

--- Build the generator and install to stdpath("data")/cpphelper/generator.exe.
--- Run once after installing or updating the plugin.
function M.build_generator()
	local plugin_root = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])lua[/\\]")
	if not plugin_root then
		vim.notify("cpphelper: could not locate plugin directory", vim.log.levels.ERROR)
		return
	end
	local cargo_toml = plugin_root .. "generator\\Cargo.toml"
	if vim.fn.filereadable(cargo_toml) == 0 then
		vim.notify("cpphelper: generator source not found at " .. plugin_root .. "generator\\", vim.log.levels.ERROR)
		return
	end

	local data_dir = vim.fn.stdpath("data") .. "/cpphelper"
	if vim.fn.isdirectory(data_dir) == 0 then
		vim.fn.mkdir(data_dir, "p")
	end

	vim.notify("cpphelper: building generator...")
	vim.fn.jobstart({ "cargo", "build", "--release", "--manifest-path", cargo_toml, "--target-dir", data_dir .. "/build" }, {
		on_exit = function(_, code)
			if code == 0 then
				local src = data_dir .. "/build/release/generator.exe"
				local dst = data_dir .. "/generator.exe"
				if vim.fn.filereadable(src) == 1 then
					vim.fn.rename(src, dst)
					msvc.set_generator_path(dst)
					vim.notify("cpphelper: generator installed to " .. dst)
				else
					vim.notify("cpphelper: build succeeded but binary not found", vim.log.levels.ERROR)
				end
			else
				vim.notify("cpphelper: generator build failed (exit code " .. code .. ")", vim.log.levels.ERROR)
			end
		end,
	})
end

return M
