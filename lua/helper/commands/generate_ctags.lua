local M = {}
local executer = require('helper.commands.executer')

local function find_config()
	local cwd = vim.fn.getcwd()
	local config  = cwd .. "/.vscode/c_cpp_properties.json"
	if vim.fn.filereadable(config) == 1 then
		return config
	else
		return nil
	end
end

local function read_config(config)
	local f = io.open(config, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f.close()
	return vim.fn.json_decode(content)
end


-- Expand ${workspaceFolder}, ${config:path.*}, and env vars
local function expand_vars(str, root)
	return (str:gsub("%${(.-)}", function(key)
		if key == "workspaceFolder" then
			return root
		end
		if key:match("^config:path.") then
			-- ${config:path.VAR}
			local envname = key:match("^config:path.(.+)$")
			envname = envname:sub(2)
			if envname then
				return os.getenv(envname) or ""
			end
		end
		-- fallback to plain env vars: ${HOME}, ${SOMETHING}
		return os.getenv(key) or key
	end))
end

local function create_ctags_cmd(config)
	-- Base ctags command
	local cmd = {
		"ctags", "-R", "--languages=C++",
		"--c++-kinds=+p", "--extras=+q", "--fields=+iaS"
	}
	local args = {}
	local conf = config or {}

	-- Add std
	if conf.cppStandard then
		table.insert(args, "--options=--std=" .. conf.cppStandard)
	end

	-- Add include paths
	if conf.includePath then
		for _, inc in ipairs(conf.includePath) do
			table.insert(args, expand_vars(inc, vim.fn.getcwd()))
		end
	end

	-- Add defines
	if conf.defines then
		for _, def in ipairs(conf.defines) do
			table.insert(args, "-D" .. def)
		end
	end

	-- Merge args
	for _, a in ipairs(args) do
		table.insert(cmd, a)
	end

	table.insert(cmd, ".")

	return table.concat(cmd, " ")
end

-- Ask user to select configuration if multiple
local function choose_config(configs, callback)
	if #configs == 1 then
		callback(configs[1])
		return
	end

	local names = {}
	for _, c in ipairs(configs) do
		table.insert(names, c.name or "unnamed")
	end

	vim.ui.select(names, { prompt = "Select C++ config:" }, function(choice)
		if not choice then
			print("[c_cpp_props_ctags] Cancelled")
			return
		end
		for _, c in ipairs(configs) do
			if c.name == choice then
				callback(c)
				return
			end
		end
	end)
end

function M.generate()
	local config = find_config()
	if config == nil then
		vim.notify("Failed to find c_cpp_properties.json file")
		return
	end

	local json = read_config(config)
	if json == nil then
		vim.notify("Failed to parse " .. config)
		return
	end

	choose_config(json.configurations, function (conf)
		local cmd = create_ctags_cmd(conf)
		vim.notify("Execute: " .. cmd)
		executer.execute(cmd)
	end)

end

return M
