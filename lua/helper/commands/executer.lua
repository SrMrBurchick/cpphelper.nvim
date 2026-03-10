local M = {}
local status, notify = pcall(require, 'notify')
if (status) then
	vim.notify = notify
end

local function show_result(command)
	vim.notify(M.execute(command))
end

function M.execute(command)
	local result = vim.fn.system(command)
	show_result(result)
	return result
end

return M
