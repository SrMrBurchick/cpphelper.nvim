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

return M
