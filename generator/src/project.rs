use crate::paths::{get_directory, normalize_path};
use crate::solution::{ConfigEntry, FileEntry, ProjectDetails};
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::fs;

/// Expand MSBuild variables in a path string.
fn expand_msbuild_vars(str: &str, proj_dir: &str, config: Option<&str>, sln_dir: &str) -> String {
    let (cfg_name, platform) = match config {
        Some(c) => match c.rfind('|') {
            Some(pos) => (&c[..pos], &c[pos + 1..]),
            None => (c, ""),
        },
        None => ("", ""),
    };

    let re = Regex::new(r"\$\(([^)]+)\)").unwrap();
    let result = re.replace_all(str, |caps: &regex::Captures| {
        let var = &caps[1];
        let lv = var.to_lowercase();
        match lv.as_str() {
            "solutiondir" => sln_dir.to_string(),
            "projectdir" => proj_dir.to_string(),
            "configuration" => cfg_name.to_string(),
            "platform" => platform.to_string(),
            "outdir" => format!("{}bin\\", proj_dir),
            "intdir" => format!("{}obj\\", proj_dir),
            _ => std::env::var(var).unwrap_or_else(|_| format!("$({})", var)),
        }
    });

    result.into_owned()
}

/// Strip XML comments from content.
fn strip_xml_comments(content: &str) -> String {
    let re = Regex::new(r"<!--.*?-->").unwrap();
    re.replace_all(content, "").into_owned()
}

/// Parse a .props file recursively.
pub fn parse_props(
    props_path: &str,
    proj_dir: &str,
    visited: &mut HashSet<String>,
    sln_dir: &str,
) -> HashMap<String, (String, Vec<String>)> {
    let props_path = normalize_path(props_path);
    if visited.contains(&props_path) {
        return HashMap::new();
    }
    visited.insert(props_path.clone());

    let content = match fs::read_to_string(&props_path) {
        Ok(c) => strip_xml_comments(&c),
        Err(_) => return HashMap::new(),
    };

    let props_dir = get_directory(&props_path);
    let mut result: HashMap<String, (String, Vec<String>)> = HashMap::new();

    // Regex patterns
    let re_idg_cond = Regex::new(
        r#"<ItemDefinitionGroup\s+[^>]*Condition="[^']*=='([^']*)'[^"]*"[^>]*>(.*?)</ItemDefinitionGroup>"#,
    ).unwrap();
    let re_idg_nocond = Regex::new(r"<ItemDefinitionGroup\s*>(.*?)</ItemDefinitionGroup>").unwrap();
    let re_pg_cond = Regex::new(
        r#"<PropertyGroup\s+[^>]*Condition="[^']*=='([^']*)'[^"]*"[^>]*>(.*?)</PropertyGroup>"#,
    )
    .unwrap();
    let re_clcompile = Regex::new(r"<ClCompile>(.*?)</ClCompile>").unwrap();
    let re_import = Regex::new(r#"<Import\s+[^>]*Project="([^"]+)""#).unwrap();

    fn apply_defs(
        result: &mut HashMap<String, (String, Vec<String>)>,
        block: &str,
        cond: &str,
        proj_dir: &str,
        sln_dir: &str,
    ) {
        let entry = result
            .entry(cond.to_string())
            .or_insert_with(|| (String::new(), Vec::new()));

        if let Some(caps) = Regex::new(r"<PreprocessorDefinitions>(.*?)</PreprocessorDefinitions>")
            .unwrap()
            .captures(block)
        {
            let preprocessor = &caps[1];
            let re_clean = Regex::new(r"%.*?%").unwrap();
            let clean = re_clean.replace_all(preprocessor, "");
            let re_clean2 = Regex::new(r"\$\(.*?\)").unwrap();
            let clean = re_clean2.replace_all(&clean, "");
            if !clean.is_empty() {
                entry.0.push_str(&clean);
            }
        }

        if let Some(caps) =
            Regex::new(r"<AdditionalIncludeDirectories>(.*?)</AdditionalIncludeDirectories>")
                .unwrap()
                .captures(block)
        {
            let inc_dirs_raw = &caps[1];
            for dir in inc_dirs_raw.split(';') {
                let dir = dir.trim();
                if !dir.is_empty()
                    && !dir.starts_with("%(")
                    && !dir.contains("$(inherit)")
                    && !dir.contains("$(Inherit)")
                {
                    let dir = expand_msbuild_vars(dir, proj_dir, Some(cond), sln_dir);
                    entry.1.push(dir);
                }
            }
        }
    }

    // ItemDefinitionGroup with Condition
    for caps in re_idg_cond.captures_iter(&content) {
        let cond = &caps[1];
        let block = &caps[2];
        if let Some(clc) = re_clcompile.captures(block) {
            apply_defs(&mut result, &clc[1], cond, proj_dir, sln_dir);
        } else {
            apply_defs(&mut result, block, cond, proj_dir, sln_dir);
        }
    }

    // ItemDefinitionGroup WITHOUT condition
    for caps in re_idg_nocond.captures_iter(&content) {
        let block = &caps[1];
        if let Some(clc) = re_clcompile.captures(block) {
            apply_defs(&mut result, &clc[1], "*", proj_dir, sln_dir);
        } else {
            apply_defs(&mut result, block, "*", proj_dir, sln_dir);
        }
    }

    // PropertyGroup with Condition
    for caps in re_pg_cond.captures_iter(&content) {
        let cond = &caps[1];
        let block = &caps[2];
        apply_defs(&mut result, block, cond, proj_dir, sln_dir);
    }

    // Recursively follow <Import Project="...">
    for caps in re_import.captures_iter(&content) {
        let imp_path = &caps[1];
        if !imp_path.contains("$(VCTargets") && !imp_path.contains("Microsoft.Cpp") {
            let abs_imp = expand_msbuild_vars(imp_path, proj_dir, None, sln_dir);
            let abs_imp = if !abs_imp.contains(':')
                && !abs_imp.starts_with('\\')
                && !abs_imp.starts_with('/')
            {
                format!("{}{}", props_dir, abs_imp)
            } else {
                abs_imp
            };
            if abs_imp.ends_with(".props") {
                let nested = parse_props(&abs_imp, proj_dir, visited, sln_dir);
                for (cond, data) in nested {
                    let entry = result
                        .entry(cond)
                        .or_insert_with(|| (String::new(), Vec::new()));
                    entry.0.push_str(&data.0);
                    entry.1.extend(data.1);
                }
            }
        }
    }

    result
}

/// Parse a .vcxproj file.
pub fn parse_vcxproj(full_path: &str, sln_dir: &str) -> Option<ProjectDetails> {
    let proj_dir = get_directory(full_path);
    let content = fs::read_to_string(full_path).ok()?;
    let content = strip_xml_comments(&content);

    let mut details = ProjectDetails::default();
    let mut configurations: HashMap<String, ConfigEntry> = HashMap::new();

    // Parse ProjectConfiguration entries
    let re_proj_cfg = Regex::new(r#"<ProjectConfiguration\s+Include="([^"]+)">"#).unwrap();
    for caps in re_proj_cfg.captures_iter(&content) {
        let config = &caps[1];
        configurations.insert(config.to_string(), ConfigEntry::default());
    }

    // Collect .props files
    let mut props_data: HashMap<String, (String, Vec<String>)> = HashMap::new();
    let re_import = Regex::new(r#"<Import\s+[^>]*Project="([^"]+)""#).unwrap();
    for caps in re_import.captures_iter(&content) {
        let imp_path = &caps[1];
        if !imp_path.contains("$(VCTargets") && !imp_path.contains("Microsoft.Cpp") {
            let abs_imp = expand_msbuild_vars(imp_path, proj_dir, None, sln_dir);
            let abs_imp = if !abs_imp.contains(':')
                && !abs_imp.starts_with('\\')
                && !abs_imp.starts_with('/')
            {
                format!("{}{}", proj_dir, abs_imp)
            } else {
                abs_imp
            };
            if abs_imp.ends_with(".props") {
                let mut visited = HashSet::new();
                let pd = parse_props(&abs_imp, proj_dir, &mut visited, sln_dir);
                for (cond, data) in pd {
                    let entry = props_data
                        .entry(cond)
                        .or_insert_with(|| (String::new(), Vec::new()));
                    entry.0.push_str(&data.0);
                    entry.1.extend(data.1);
                }
            }
        }
    }

    // Helper to apply props to a config entry
    let apply_props = |config_entry: &mut ConfigEntry, config_name: Option<&str>| {
        // Global props
        if let Some(global) = props_data.get("*") {
            if !global.0.is_empty() {
                config_entry.defines.push_str(&global.0);
            }
            config_entry.include_dirs.extend(global.1.clone());
        }
        // Config-specific props
        if let Some(name) = config_name {
            if let Some(specific) = props_data.get(name) {
                if !specific.0.is_empty() {
                    config_entry.defines.push_str(&specific.0);
                }
                config_entry.include_dirs.extend(specific.1.clone());
            }
        }
    };

    // Parse ClCompile/ClInclude self-closing tags
    let re_self_close = Regex::new(r#"<(Cl\w+)\s+Include="([^"]+)"\s*/>"#).unwrap();
    for caps in re_self_close.captures_iter(&content) {
        let tag = &caps[1];
        let file_path = &caps[2];
        for (_, data) in configurations.iter_mut() {
            data.files.push(FileEntry {
                path: file_path.to_string(),
                file_type: tag.to_string(),
            });
        }
    }

    // Parse ClCompile/ClInclude block form with ExcludedFromBuild
    let re_block = Regex::new(
        r#"<(Cl(?:Compile|Include))\s+Include="([^"]+)">([\s\S]*?)</Cl(?:Compile|Include)>"#,
    )
    .unwrap();
    let re_excluded = Regex::new(
        r#"<ExcludedFromBuild\s+Condition="[^']*=='([^']*)'[^"]*">\s*(.*?)</ExcludedFromBuild>"#,
    )
    .unwrap();
    for caps in re_block.captures_iter(&content) {
        let tag = &caps[1];
        let file_path = &caps[2];
        let block = &caps[3];

        let mut excluded_configs: HashSet<String> = HashSet::new();
        for exc_caps in re_excluded.captures_iter(block) {
            let val = exc_caps[2].trim();
            if val.eq_ignore_ascii_case("true") {
                excluded_configs.insert(exc_caps[1].to_string());
            }
        }

        for (config_name, data) in configurations.iter_mut() {
            if !excluded_configs.contains(config_name) {
                data.files.push(FileEntry {
                    path: file_path.to_string(),
                    file_type: tag.to_string(),
                });
            }
        }
    }

    let inline_map: HashMap<&str, &str> = [
        ("Disabled", "/Ob0"),
        ("OnlyExplicitInline", "/Ob1"),
        ("AnySuitable", "/Ob2"),
    ]
    .iter()
    .cloned()
    .collect();

    // Merge IDG block helper
    let merge_idg_block = |block: &str, config_entry: &mut ConfigEntry, condition: &str| {
        let re_preproc =
            Regex::new(r"<PreprocessorDefinitions>(.*?)</PreprocessorDefinitions>").unwrap();
        if let Some(caps) = re_preproc.captures(block) {
            let preprocessor = &caps[1];
            let re_clean = Regex::new(r"%.*?%|\$\(.*?\)").unwrap();
            let clean = re_clean.replace_all(preprocessor, "");
            if !clean.is_empty() {
                config_entry.defines.push_str(&clean);
            }
        }

        let re_inline =
            Regex::new(r"<InlineFunctionExpansion>(.*?)</InlineFunctionExpansion>").unwrap();
        if let Some(caps) = re_inline.captures(block) {
            let inline_val = caps[1].trim();
            if config_entry.inline_expansion.is_none() {
                config_entry.inline_expansion = inline_map.get(inline_val).map(|s| s.to_string());
            }
        }

        let re_inc =
            Regex::new(r"<AdditionalIncludeDirectories>(.*?)</AdditionalIncludeDirectories>")
                .unwrap();
        if let Some(caps) = re_inc.captures(block) {
            let inc_dirs_raw = &caps[1];
            for dir in inc_dirs_raw.split(';') {
                let dir = dir.trim();
                if !dir.is_empty() && !dir.starts_with("%(") {
                    let dir = expand_msbuild_vars(dir, proj_dir, Some(condition), sln_dir);
                    config_entry.include_dirs.push(dir);
                }
            }
        }
    };

    // Unconditional ItemDefinitionGroup
    let re_idg_nocond = Regex::new(r"<ItemDefinitionGroup\s*>(.*?)</ItemDefinitionGroup>").unwrap();
    for caps in re_idg_nocond.captures_iter(&content) {
        let block = &caps[1];
        let clcompile = Regex::new(r"<ClCompile>(.*?)</ClCompile>")
            .unwrap()
            .captures(block)
            .map(|c| c[1].to_string())
            .unwrap_or_else(|| block.to_string());
        for (_, config_entry) in configurations.iter_mut() {
            merge_idg_block(&clcompile, config_entry, "");
        }
    }

    // Conditioned ItemDefinitionGroup
    let re_idg_cond = Regex::new(
        r#"<ItemDefinitionGroup\s+[^>]*Condition="[^']*=='([^']*)'[^"]*"[^>]*>(.*?)</ItemDefinitionGroup>"#,
    ).unwrap();
    for caps in re_idg_cond.captures_iter(&content) {
        let condition = &caps[1];
        let block = &caps[2];
        if configurations.contains_key(condition) {
            let clcompile = Regex::new(r"<ClCompile>(.*?)</ClCompile>")
                .unwrap()
                .captures(block)
                .map(|c| c[1].to_string())
                .unwrap_or_else(|| block.to_string());
            if let Some(config_entry) = configurations.get_mut(condition) {
                merge_idg_block(&clcompile, config_entry, condition);
            }
        }
    }

    // Merge props data for every configuration
    let config_names: Vec<String> = configurations.keys().cloned().collect();
    for config_name in config_names {
        if let Some(config_entry) = configurations.get_mut(&config_name) {
            apply_props(config_entry, Some(&config_name));
        }
    }

    details.configurations = Some(configurations);
    Some(details)
}

/// Parse a Visual Studio 2005/2008 .vcproj file.
pub fn parse_vcproj(full_path: &str, _sln_dir: &str) -> Option<ProjectDetails> {
    let proj_dir = get_directory(full_path);
    let content = fs::read_to_string(full_path).ok()?;
    let content = strip_xml_comments(&content);

    let mut details = ProjectDetails::default();
    let mut configurations: HashMap<String, ConfigEntry> = HashMap::new();

    // Parse configurations: <Configuration Name="Debug|Win32" ...>
    let re_cfg = Regex::new(r#"<Configuration\s+Name="([^"]+)""#).unwrap();
    for caps in re_cfg.captures_iter(&content) {
        let cfg_name = &caps[1];
        configurations.insert(
            cfg_name.to_string(),
            ConfigEntry {
                files: Vec::new(),
                defines: String::new(),
                include_dirs: Vec::new(),
                inline_expansion: None,
            },
        );
    }

    // Collect source/header files from <File RelativePath="...">
    let re_file = Regex::new(r#"<File\s+RelativePath="([^"]+)"(.*?)</File>"#).unwrap();
    let re_excluded =
        Regex::new(r#"<FileConfiguration\s+Name="([^"]+)"[^>]*ExcludedFromBuild="([^"]+)""#)
            .unwrap();
    let re_excluded_rev =
        Regex::new(r#"<FileConfiguration\s+ExcludedFromBuild="([^"]+)"[^>]*Name="([^"]+)""#)
            .unwrap();

    for caps in re_file.captures_iter(&content) {
        let file_path = &caps[1];
        let inner = &caps[2];
        let ext = file_path
            .rfind('.')
            .map(|pos| &file_path[pos + 1..])
            .unwrap_or("");
        let tag = match ext {
            "cpp" | "c" | "cc" | "cxx" => Some("ClCompile"),
            "h" | "hpp" | "hxx" => Some("ClInclude"),
            _ => None,
        };

        if let Some(tag) = tag {
            let mut excluded: HashSet<String> = HashSet::new();
            for exc_caps in re_excluded.captures_iter(inner) {
                if &exc_caps[2] == "true" {
                    excluded.insert(exc_caps[1].to_string());
                }
            }
            for exc_caps in re_excluded_rev.captures_iter(inner) {
                if &exc_caps[1] == "true" {
                    excluded.insert(exc_caps[2].to_string());
                }
            }

            for (config_name, data) in configurations.iter_mut() {
                if !excluded.contains(config_name) {
                    data.files.push(FileEntry {
                        path: file_path.to_string(),
                        file_type: tag.to_string(),
                    });
                }
            }
        }
    }

    // Extract defines and include dirs from VCCLCompilerTool
    let re_cfg_block = Regex::new(r"<Configuration(.*?)</Configuration>").unwrap();
    let re_cfg_name = Regex::new(r#"Name="([^"]+)""#).unwrap();
    let re_tool = Regex::new(r#"<Tool\s+Name="VCCLCompilerTool"\s+(.*?)/?>"#).unwrap();
    let re_tool2 = Regex::new(r#"<Tool\s+(.*?)Name="VCCLCompilerTool"\s+(.*?)/?>"#).unwrap();

    for cfg_caps in re_cfg_block.captures_iter(&content) {
        let cfg_block = &cfg_caps[1];
        let cfg_name = re_cfg_name.captures(cfg_block).map(|c| c[1].to_string());
        if let Some(cfg_name) = cfg_name {
            if let Some(config_entry) = configurations.get_mut(&cfg_name) {
                let tool_attrs = re_tool
                    .captures(cfg_block)
                    .map(|c| c[1].to_string())
                    .or_else(|| {
                        re_tool2
                            .captures(cfg_block)
                            .map(|c| format!("{}{}", &c[1], &c[2]))
                    });

                if let Some(attrs) = tool_attrs {
                    let re_pp = Regex::new(r#"PreprocessorDefinitions="([^"]*)""#).unwrap();
                    if let Some(pp_caps) = re_pp.captures(&attrs) {
                        let pp = pp_caps[1].replace(';', "");
                        config_entry.defines.push_str(&pp);
                    }

                    let re_inc = Regex::new(r#"AdditionalIncludeDirectories="([^"]*)""#).unwrap();
                    if let Some(inc_caps) = re_inc.captures(&attrs) {
                        for dir in inc_caps[1].split(';') {
                            let dir = dir.trim();
                            if !dir.is_empty() && !dir.contains("$(Inherit)") {
                                let dir = if !dir.contains(':')
                                    && !dir.starts_with('\\')
                                    && !dir.starts_with('/')
                                {
                                    format!("{}{}", proj_dir, dir)
                                } else {
                                    dir.to_string()
                                };
                                config_entry.include_dirs.push(dir);
                            }
                        }
                    }
                }
            }
        }
    }

    details.configurations = Some(configurations);
    Some(details)
}

/// Parse dependencies from a .vcxproj file.
pub fn parse_vcxproj_deps(full_path: &str) -> Vec<String> {
    let content = match fs::read_to_string(full_path) {
        Ok(c) => c,
        Err(_) => return Vec::new(),
    };

    let re = Regex::new(r#"<ProjectReference\s+Include="([^"]+)""#).unwrap();
    re.captures_iter(&content)
        .map(|caps| caps[1].to_string())
        .collect()
}
