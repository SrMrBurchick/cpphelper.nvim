local executer = require('helper.commands.executer')
local cpp_notify = require('helper.notify')

local M = {
	solution = {
		root_dir = "",
		projects = {},
		globals = {},
		configurations = {},
		-- maps { [solution_config] = { [proj_guid] = project_config } }
		config_map = {}
	}
}

local function get_file_extension(path)
	return path:match("^.+(%..+)$")
end

local function get_directory(filepath)
	return filepath:match("(.*[\\/])") or ""
end

-- Normalize a Windows path by resolving all ".." and "." segments.
local function normalize_path(path)
	-- Unify separators to backslash
	path = path:gsub("/", "\\")
	local drive, rest = path:match("^([A-Za-z]:)(.*)")
	if not drive then
		drive, rest = "", path
	end
	local parts = {}
	for part in rest:gmatch("[^\\]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	local result = drive .. "\\" .. table.concat(parts, "\\")
	-- Preserve trailing separator if original had one
	if path:sub(-1) == "\\" then
		result = result .. "\\"
	end
	return result
end

local function trim_quotes(s)
	return s:match('^%s*"(.-)"%s*$') or s:match('^%s*(.-)%s*$')
end

-- Notification handle for the current operation (set by notif_begin).
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

-- Expand MSBuild variables in a path string.
-- proj_dir: directory of the .vcxproj file
-- config:   config name string like "pc_Debug|x64"
local function expand_msbuild_vars(str, proj_dir, config)
	local sln_dir = M.solution.root_dir
	local cfg_name, platform = (config or ""):match("^(.+)|(.+)$")
	cfg_name = cfg_name or config or ""
	platform = platform or ""

	return (str:gsub("%$%((.-)%)", function(var)
		local lv = var:lower()
		if lv == "solutiondir"       then return sln_dir
		elseif lv == "projectdir"    then return proj_dir
		elseif lv == "configuration" then return cfg_name
		elseif lv == "platform"      then return platform
		elseif lv == "outdir"        then return proj_dir .. "bin\\"
		elseif lv == "intdir"        then return proj_dir .. "obj\\"
		else
			-- Fallback to environment variable
			return os.getenv(var) or ("$(" .. var .. ")")
		end
	end))
end

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local content = f:read("*all")
	f:close()
	return content
end

-- Parse a .props file and return { [condition_or_global] = { defines, include_dirs } }
-- Recursively follows <Import Project="..."> for nested .props.
-- visited: set of already-parsed paths to avoid cycles.
local function parse_props(props_path, proj_dir, visited)
	visited = visited or {}
	props_path = normalize_path(props_path)
	if visited[props_path] then return {} end
	visited[props_path] = true

	local content = read_file(props_path)
	if not content then return {} end

	-- Strip XML comments
	content = content:gsub("<!%-%-.-%-%->", "")

	local props_dir = get_directory(props_path)
	local result = {} -- { condition -> { defines=string, include_dirs={} } }

	local function ensure_entry(cond)
		if not result[cond] then
			result[cond] = { defines = "", include_dirs = {} }
		end
	end

	local function apply_defs(cond, block)
		ensure_entry(cond)
		-- Preprocessor defines
		local preprocessor = block:match('<PreprocessorDefinitions>(.-)</PreprocessorDefinitions>')
		if preprocessor then
			local clean = preprocessor:gsub("%%%(.-%)", ""):gsub("%$%(.-%)", "")
			if clean ~= "" then
				result[cond].defines = result[cond].defines .. clean
			end
		end
		-- Include directories
		local inc_dirs_raw = block:match('<AdditionalIncludeDirectories>(.-)</AdditionalIncludeDirectories>')
		if inc_dirs_raw then
			for dir in inc_dirs_raw:gmatch("([^;]+)") do
				dir = dir:match("^%s*(.-)%s*$")
				if dir ~= "" and not dir:match("^%%%(") and not dir:match("%$%(inherit%)") then
					dir = expand_msbuild_vars(dir, proj_dir, cond)
					table.insert(result[cond].include_dirs, dir)
				end
			end
		end
	end

	-- ItemDefinitionGroup with Condition
	for cond, block in content:gmatch('<ItemDefinitionGroup%s+[^>]*Condition=".-==\'(.-)\'[^"]*"[^>]*>(.-)</ItemDefinitionGroup>') do
		local clcompile = block:match('<ClCompile>(.-)</ClCompile>')
		if clcompile then apply_defs(cond, clcompile) end
	end

	-- ItemDefinitionGroup WITHOUT condition (global to all configs)
	for block in content:gmatch('<ItemDefinitionGroup%s*>(.-)</ItemDefinitionGroup>') do
		local clcompile = block:match('<ClCompile>(.-)</ClCompile>')
		if clcompile then apply_defs("*", clcompile) end
	end

	-- PropertyGroup with Condition
	for cond, block in content:gmatch('<PropertyGroup%s+[^>]*Condition=".-==\'(.-)\'[^"]*"[^>]*>(.-)</PropertyGroup>') do
		apply_defs(cond, block)
	end

	-- Recursively follow <Import Project="...">
	for imp_path in content:gmatch('<Import%s+[^>]*Project="([^"]+)"') do
		-- Skip Microsoft-provided props (SDK, platform toolset)
		if not imp_path:match("%$%(VCTargets") and not imp_path:match("Microsoft%.Cpp") then
			-- Expand variables FIRST, then resolve relative paths against props_dir
			local abs_imp = expand_msbuild_vars(imp_path, proj_dir, nil)
			if not abs_imp:match("^[A-Za-z]:") and not abs_imp:match("^[\\/]") then
				abs_imp = props_dir .. abs_imp
			end
			local nested = parse_props(abs_imp, proj_dir, visited)
			for cond, data in pairs(nested) do
				ensure_entry(cond)
				result[cond].defines = result[cond].defines .. data.defines
				for _, d in ipairs(data.include_dirs) do
					table.insert(result[cond].include_dirs, d)
				end
			end
		end
	end

	return result
end

local function parse_vcxproj(full_path)
	local proj_dir = get_directory(full_path)
	local f = io.open(full_path, "r")
	if not f then return nil end
	local content = f:read("*all")
	f:close()

	-- Strip XML comments <!-- ... -->
	content = content:gsub("<!%-%-.-%-%->", "")

	local project_data = {
		configurations = {}
	}

	for config in content:gmatch('<ProjectConfiguration%s+Include="(.-)">') do
		project_data.configurations[config] = { files = {}, defines = "" }
	end

	-- Collect .props files imported by this vcxproj (skip SDK/toolset imports)
	local props_data = {}
	local visited_props = {}
	for imp_path in content:gmatch('<Import%s+[^>]*Project="([^"]+)"') do
		if not imp_path:match("%$%(VCTargets") and not imp_path:match("Microsoft%.Cpp") then
			-- Expand variables FIRST, then resolve relative paths against proj_dir
			local abs_imp = expand_msbuild_vars(imp_path, proj_dir, nil)
			if not abs_imp:match("^[A-Za-z]:") and not abs_imp:match("^[\\/]") then
				abs_imp = proj_dir .. abs_imp
			end
			if abs_imp:match("%.props$") then
				notif_log("  Importing props: " .. abs_imp)
				local pd = parse_props(abs_imp, proj_dir, visited_props)
				for cond, data in pairs(pd) do
					if not props_data[cond] then
						props_data[cond] = { defines = "", include_dirs = {} }
					end
					props_data[cond].defines = props_data[cond].defines .. data.defines
					for _, d in ipairs(data.include_dirs) do
						table.insert(props_data[cond].include_dirs, d)
					end
				end
			end
		end
	end

	-- Helper: merge props data into a config entry
	local function apply_props(config_entry, config_name)
		-- Apply global props (wildcard key "*")
		local global = props_data["*"]
		if global then
			if global.defines ~= "" then
				config_entry.defines = (config_entry.defines or "") .. global.defines
			end
			config_entry.include_dirs = config_entry.include_dirs or {}
			for _, d in ipairs(global.include_dirs) do
				table.insert(config_entry.include_dirs, d)
			end
		end
		-- Apply config-specific props
		if config_name then
			local specific = props_data[config_name]
			if specific then
				if specific.defines ~= "" then
					config_entry.defines = (config_entry.defines or "") .. specific.defines
				end
				config_entry.include_dirs = config_entry.include_dirs or {}
				for _, d in ipairs(specific.include_dirs) do
					table.insert(config_entry.include_dirs, d)
				end
			end
		end
	end

	-- Parse all <ClCompile> and <ClInclude> entries.
	-- Use ([^"]+) for the path to prevent matching past the closing quote across newlines.
	-- Self-closing: <ClCompile Include="path" />
	for tag, file_path in content:gmatch('<(Cl%w+)%s+Include="([^"]+)"%s*/>') do
		for config, data in pairs(project_data.configurations) do
			table.insert(data.files, { path = file_path, type = tag })
		end
	end

	-- Block form: <ClCompile Include="path"> ... </ClCompile>
	-- Use ([^"]+) for the path and ([^<]*<[^>]*>)* is too complex — use .-
	-- but anchored by closing </TagName> with tag name repeated via %1.
	for tag, file_path, block in content:gmatch('<(Cl%w+)%s+Include="([^"]+)">(.-)</%1>') do
		local excluded_configs = {}
		for cond, val in block:gmatch('<ExcludedFromBuild%s+Condition="[^"]*==\'([^\']+)\'[^"]*">%s*([^<]*)</ExcludedFromBuild>') do
			if val:match("^%s*[Tt]rue%s*$") then
				excluded_configs[cond] = true
			end
		end
		for config, data in pairs(project_data.configurations) do
			if not excluded_configs[config] then
				table.insert(data.files, { path = file_path, type = tag })
			end
		end
	end

	local inline_map = {
		Disabled             = "/Ob0",
		OnlyExplicitInline   = "/Ob1",
		AnySuitable          = "/Ob2",
	}

	-- Helper: extract defines/include_dirs/inline from a ClCompile block and
	-- merge them INTO an existing config_entry table.
	local function merge_idg_block(defs, config_entry, condition)
		local preprocessor = defs:match('<PreprocessorDefinitions>(.-)</PreprocessorDefinitions>')
		if preprocessor then
			local clean_defs = preprocessor:gsub("%%%(.-%)", "")
			config_entry.defines = (config_entry.defines or "") .. clean_defs
		end

		local inline = defs:match('<InlineFunctionExpansion>(.-)</InlineFunctionExpansion>')
		if inline then
			inline = inline:match("^%s*(.-)%s*$")
			if not config_entry.inline_expansion then
				config_entry.inline_expansion = inline_map[inline]
			end
		end

		local inc_dirs_raw = defs:match('<AdditionalIncludeDirectories>(.-)</AdditionalIncludeDirectories>')
		if inc_dirs_raw then
			config_entry.include_dirs = config_entry.include_dirs or {}
			for dir in inc_dirs_raw:gmatch("([^;]+)") do
				dir = dir:match("^%s*(.-)%s*$")
				if dir ~= "" and not dir:match("^%%%(") then
					dir = expand_msbuild_vars(dir, proj_dir, condition)
					table.insert(config_entry.include_dirs, dir)
				end
			end
		end
	end

	-- 1. Unconditional <ItemDefinitionGroup> → applies to ALL configurations
	for block in content:gmatch('<ItemDefinitionGroup%s*>(.-)</ItemDefinitionGroup>') do
		local clcompile = block:match('<ClCompile>(.-)</ClCompile>') or block
		for config_name, config_entry in pairs(project_data.configurations) do
			merge_idg_block(clcompile, config_entry, config_name)
		end
	end

	-- 2. Conditioned <ItemDefinitionGroup Condition="...=='cfg'"> → specific config
	for condition, block in content:gmatch('<ItemDefinitionGroup%s+[^>]*Condition="[^"]*==\'([^\']+)\'[^"]*"[^>]*>(.-)</ItemDefinitionGroup>') do
		if project_data.configurations[condition] then
			local clcompile = block:match('<ClCompile>(.-)</ClCompile>') or block
			merge_idg_block(clcompile, project_data.configurations[condition], condition)
		end
	end

	-- 3. Merge props data for every configuration
	for config_name, config_entry in pairs(project_data.configurations) do
		config_entry.include_dirs = config_entry.include_dirs or {}
		apply_props(config_entry, config_name)
	end

	return project_data
end

local function parse_vcxproj_deps(full_path)
	if full_path == nil then
		notif_log("Invalid path for vcxproj: " .. tostring(full_path), "warn")
		return
	end
	notif_log("Read project: " .. full_path)
	local content = read_file(full_path)
	if not content then return {} end

	local deps = {}
	for dep_path in content:gmatch('<ProjectReference%s+Include="(.-)"') do
		table.insert(deps, dep_path)
	end
	return deps
end

local function parse_sln(file)
	if file == nil then
		return
	end

	local current_project_guid = nil
	local in_config_section = false
	local in_proj_config_section = false

	for line in file:lines() do
		local type_guid, name, proj_path, proj_guid = line:match('^Project%("{(.-)}"%)%s*=%s*"(.-)"%s*,%s*"(.-)"%s*,%s*"(.-)"')

		if type_guid then
			notif_log("Parsing: " .. type_guid .. ", name: " .. name)
			current_project_guid = proj_guid
			local project_path = M.solution.root_dir .. proj_path
			M.solution.projects[proj_guid] = {
				name = name,
				path = proj_path,
				full_path = project_path,
				guid = proj_guid,
				type_guid = type_guid,
				dependencies = {},
				details = {}
			}

			if proj_path:match("%.vcxproj$") then
				M.solution.projects[current_project_guid].dependencies = parse_vcxproj_deps(project_path)
				M.solution.projects[current_project_guid].details = parse_vcxproj(project_path)
			end
		end

		local dep_guid = line:match('^%s*({.-})%s*=%s*{.-}%s*$')
		if dep_guid and current_project_guid then
			M.solution.projects[current_project_guid].sln_deps = dep_guid
		end

		if line:match("^EndProject") then
			current_project_guid = nil
		end

		local global_key, global_val = line:match('^%s*(%w+)%s*=%s*(.-)$')
		if global_key and global_val then
			M.solution.globals[global_key] = trim_quotes(global_val)
		end

		if line:find("GlobalSection%(SolutionConfigurationPlatforms%) = preSolution") then
			in_config_section = true
		elseif line:find("GlobalSection%(ProjectConfigurationPlatforms%) = postSolution") then
			in_proj_config_section = true
		elseif (in_config_section or in_proj_config_section) and line:find("EndGlobalSection") then
			in_config_section = false
			in_proj_config_section = false
		end

		if in_config_section then
			if line:find("GlobalSection%(SolutionConfigurationPlatforms%) = preSolution") == nil then
				local config = line:match("^%s*(.-)%s*=")
				if config then
					table.insert(M.solution.configurations, config)
				end
			end
		end

		-- Parse ProjectConfigurationPlatforms:
		-- {GUID}.SolutionConfig|Platform.ActiveCfg = ProjectConfig|Platform
		if in_proj_config_section then
			local guid, sln_cfg, proj_cfg = line:match(
				'^%s*({[^}]+})%.([^.]+|[^.]+)%.ActiveCfg%s*=%s*(.-)%s*$'
			)
			if guid and sln_cfg and proj_cfg then
				if not M.solution.config_map[sln_cfg] then
					M.solution.config_map[sln_cfg] = {}
				end
				M.solution.config_map[sln_cfg][guid] = proj_cfg
			end
		end
	end
end

local function parse_slnx(file)
end

local function build_command(file_path, config_data)
	local cmd = "cl.exe /c /EHsc "

	if config_data.inline_expansion then
		cmd = cmd .. config_data.inline_expansion .. " "
	end

	local defines = config_data.defines or ""
	for define in defines:gmatch("([^;]+)") do
		if define ~= "" and not define:find("%%") then
			cmd = cmd .. "/D" .. define .. " "
		end
	end

	for _, inc in ipairs(config_data.include_dirs or {}) do
		cmd = cmd .. '/I"' .. normalize_path(inc) .. '" '
	end

	cmd = cmd .. '"' .. file_path .. '"'
	return cmd
end

function M.generate_compile_commands(target_solution_config)
	notif_begin("Generating compile_commands.json")
	local db = {}

	for _, project in pairs(M.solution.projects) do
		if project.details and project.details.configurations then
			-- Resolve the project-specific config name from the solution config map.
			-- e.g. target_solution_config = "Debug|x64"
			--      config_map["Debug|x64"][project.guid] = "pc_Debug|x64"
			local resolved_config = target_solution_config
			if target_solution_config and M.solution.config_map[target_solution_config] then
				local guid_map = M.solution.config_map[target_solution_config]
				resolved_config = guid_map[project.guid] or target_solution_config
			end

			local proj_dir = project.full_path:match("(.*[\\/])") or ""

			for config_name, config_data in pairs(project.details.configurations) do
				if not resolved_config or config_name == resolved_config then
					notif_log("Parsing project: " .. project.name .. " config: " .. config_name)
					for _, file in ipairs(config_data.files) do
						-- Resolve to absolute path: vcxproj paths may be relative to project dir
						local abs_path = file.path
						if not abs_path:match("^[A-Za-z]:") and not abs_path:match("^[\\/]") then
							abs_path = proj_dir .. file.path
						end

						local norm_path = normalize_path(abs_path)
						local norm_dir  = normalize_path(proj_dir)
						-- Only emit entries for .cpp/.c source files.
						-- CLANGD infers header flags from the .cpp that includes them.
						if file.type == "ClCompile" then
							table.insert(db, {
								directory = norm_dir,
								command   = build_command(norm_path, config_data),
								file      = norm_path,
							})
						end
					end
				end
			end
		end
	end

	-- Compute the common ancestor of all file paths in the DB so that
	-- CLANGD can find compile_commands.json regardless of which sub-tree
	-- the opened file belongs to (e.g. solution in trixie\, sources in s2\).
	local function path_parts(p)
		local parts = {}
		for seg in p:gmatch("[^\\]+") do
			table.insert(parts, seg)
		end
		return parts
	end

	local common_parts = nil
	for _, entry in ipairs(db) do
		local parts = path_parts(entry.file)
		-- Drop the filename itself; keep only directory segments
		table.remove(parts)
		if common_parts == nil then
			common_parts = parts
		else
			-- Trim common_parts to the shared prefix
			local new_len = 0
			for i = 1, math.min(#common_parts, #parts) do
				if common_parts[i]:lower() == parts[i]:lower() then
					new_len = i
				else
					break
				end
			end
			while #common_parts > new_len do
				table.remove(common_parts)
			end
		end
	end

	local out_dir = M.solution.root_dir
	if common_parts and #common_parts > 0 then
		out_dir = table.concat(common_parts, "\\") .. "\\"
	end

	-- Write compile_commands.json to the common ancestor so clangd finds it
	local output_name = "compile_commands.json"
	local f = io.open(output_name, "w")
	if f then
		f:write(vim.json.encode(db))
		f:close()
		notif_done("Generated: " .. output_name .. " for " .. (target_solution_config or "all"))
	else
		notif_done("Failed to write: " .. output_name)
		vim.notify("Failed to write: " .. output_name, vim.log.levels.ERROR)
	end
end

function M.load_solution(path)
	notif_begin("Loading Solution")
	local file = io.open(path, 'r')
	local type = get_file_extension(path)
	if file ~= nil then
		M.solution.root_dir = get_directory(path)
		if type == ".sln" then
			parse_sln(file)
		elseif type == ".slnx" then
			parse_slnx(file)
		else
			return false
		end
	else
		return false
	end
	notif_log("Creating cache")
	vim.fn.chdir(M.solution.root_dir)
	vim.fn.mkdir(M.solution.root_dir .. "/.cache")
	local output_name = M.solution.root_dir .. ".cache/helper.json"
	local f = io.open(output_name, "w")
	if f then
		f:write(vim.json.encode(M.solution, { indent = true }))
		f:close()
	end

	file:close()

	notif_done("Solution loaded successfully")

	return true
end

function M.load()
	local output_name = ".cache/helper.json"
	M.solution = vim.json.decode(read_file(output_name))
	if M.solution ~= nil then
		notif_done("Project was successfully loaded")
	end
end

return M
