local M = {}
local executer = require('helper.commands.executer')

function M.install_libs()
	local cwd = vim.fn.getcwd()
	executer.execute( cwd .. "/libs.bat")
end

return M
