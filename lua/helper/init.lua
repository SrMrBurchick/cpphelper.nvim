local cpphelper_opts = require('helper.opts')
local cpphelper_telescope = require('helper.telescope')

local M = {
	opts = cpphelper_opts,
	telescope = cpphelper_telescope
}


M.cpphelper_augroup = api.nvim_create_augroup('CPPHelper', { clear = true })

function M.setup(opts)
    if nil == opts then
        return
    end
end

return M
