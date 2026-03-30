local M = {}
local status, notify_lib = pcall(require, 'notify')
if status and type(notify_lib) == "table" then
	notify_lib.setup()
	vim.notify = notify_lib
end

function M.execute(command)
	local result = vim.fn.system(command)
	result = vim.trim(result)
	if result ~= "" then
		vim.notify(result)
	end
	return result
end

return M
