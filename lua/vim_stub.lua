--- Minimal vim API stub for running cpphelper outside Neovim.
--- Source this before requiring any plugin module.

-- Use dkjson or another JSON library if available; fall back to a tiny bundled impl.
local json_ok, json = pcall(require, "dkjson")
if not json_ok then
	json_ok, json = pcall(require, "cjson")
end

local function tbl_deep_extend(mode, base, ...)
	local result = {}
	for k, v in pairs(base) do result[k] = v end
	for _, tbl in ipairs({...}) do
		for k, v in pairs(tbl) do
			if mode == "force" or result[k] == nil then
				if type(v) == "table" and type(result[k]) == "table" then
					result[k] = tbl_deep_extend(mode, result[k], v)
				else
					result[k] = v
				end
			end
		end
	end
	return result
end

vim = vim or {}

vim.log = { levels = { DEBUG = 0, INFO = 1, WARN = 2, ERROR = 3 } }

vim.notify = function(msg, level)
	local prefix = ""
	if level == vim.log.levels.ERROR then prefix = "[ERROR] "
	elseif level == vim.log.levels.WARN  then prefix = "[WARN]  "
	end
	print(prefix .. tostring(msg))
end

vim.json = {
	encode = function(val, opts)
		if json_ok then
			return json.encode(val, opts)
		end
		error("No JSON library available. Install dkjson: luarocks install dkjson")
	end,
	decode = function(str)
		if json_ok then
			local ok, v = pcall(json.decode, str)
			if ok then return v end
			-- cjson uses direct return
			return json.decode(str)
		end
		error("No JSON library available. Install dkjson: luarocks install dkjson")
	end,
}

vim.fn = {
	chdir = function(path) os.execute('cd "' .. path .. '"') end,
	mkdir = function(path)
		-- works on both Windows and Unix
		os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
	end,
}

vim.api = setmetatable({}, {
	__index = function(_, k)
		return function(...) end  -- all nvim_* calls are no-ops
	end
})

vim.defer_fn = function(fn, ms)
	-- Outside Neovim there is no event loop; skip deferred calls.
end

vim.deepcopy = function(obj)
	if type(obj) ~= "table" then return obj end
	local copy = {}
	for k, v in pairs(obj) do copy[k] = vim.deepcopy(v) end
	return setmetatable(copy, getmetatable(obj))
end

vim.tbl_deep_extend = tbl_deep_extend

vim.lsp = { handlers = {} }
