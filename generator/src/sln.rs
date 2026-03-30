use crate::paths::{get_directory, trim_quotes};
use crate::project;
use crate::solution::{ProjectDetails, ProjectInfo, Solution};
use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};

pub fn parse_sln(path: &str) -> Result<Solution, String> {
    let root_dir = get_directory(path).to_string();
    let mut solution = Solution {
        root_dir: root_dir.clone(),
        ..Default::default()
    };

    let file = fs::File::open(path).map_err(|e| format!("Failed to open {}: {}", path, e))?;
    let reader = BufReader::new(file);

    let mut current_project_guid: Option<String> = None;
    let mut in_config_section = false;
    let mut in_proj_config_section = false;

    for line_result in reader.lines() {
        let line = line_result.map_err(|e| format!("Read error: {}", e))?;

        // Match Project line: Project("{TYPE_GUID}") = "name", "path", "{PROJ_GUID}"
        let proj_re = regex::Regex::new(
            r#"^Project\("\{([^}]+)\}"\)\s*=\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,\s*"\{([^}]+)\}""#,
        )
        .unwrap();

        if let Some(caps) = proj_re.captures(&line) {
            let type_guid = caps[1].to_string();
            let name = caps[2].to_string();
            let proj_path = caps[3].to_string();
            let proj_guid = caps[4].to_string();

            eprintln!("Parsing: {}, name: {}", type_guid, name);

            current_project_guid = Some(proj_guid.clone());
            let project_path = format!("{}{}", root_dir, proj_path);

            let mut project = ProjectInfo {
                name,
                path: proj_path.clone(),
                full_path: project_path.clone(),
                guid: proj_guid.clone(),
                type_guid,
                dependencies: Vec::new(),
                details: ProjectDetails::default(),
                sln_deps: None,
            };

            if proj_path.ends_with(".vcxproj") {
                project.dependencies = project::parse_vcxproj_deps(&project_path);
                project.details =
                    project::parse_vcxproj(&project_path, &root_dir).unwrap_or_default();
                eprintln!("Read project: {}", project_path);
            } else if proj_path.ends_with(".vcproj") {
                project.details =
                    project::parse_vcproj(&project_path, &root_dir).unwrap_or_default();
                eprintln!("Read project: {}", project_path);
            }

            solution.projects.insert(proj_guid, project);
        }

        // Match project dependency line: {GUID} = {GUID}
        let dep_re = regex::Regex::new(r#"^\s*\{([^}]+)\}\s*=\s*\{[^}]+\}\s*$"#).unwrap();
        if let Some(caps) = dep_re.captures(&line) {
            if let Some(ref guid) = current_project_guid {
                let dep_guid = caps[1].to_string();
                if let Some(proj) = solution.projects.get_mut(guid) {
                    proj.sln_deps = Some(dep_guid);
                }
            }
        }

        if line.starts_with("EndProject") {
            current_project_guid = None;
        }

        // Parse global key-value
        let global_re = regex::Regex::new(r#"^\s*(\w+)\s*=\s*(.+)$"#).unwrap();
        if let Some(caps) = global_re.captures(&line) {
            let key = caps[1].to_string();
            let val = trim_quotes(caps[2].trim());
            solution.globals.insert(key, val.to_string());
        }

        if line.contains("GlobalSection(SolutionConfigurationPlatforms) = preSolution") {
            in_config_section = true;
        } else if line.contains("GlobalSection(ProjectConfigurationPlatforms) = postSolution") {
            in_proj_config_section = true;
        } else if (in_config_section || in_proj_config_section) && line.contains("EndGlobalSection")
        {
            in_config_section = false;
            in_proj_config_section = false;
        }

        if in_config_section && !line.contains("GlobalSection(SolutionConfigurationPlatforms)") {
            let config = line.trim().split('=').next().map(|s| s.trim().to_string());
            if let Some(config) = config {
                if !config.is_empty() {
                    solution.configurations.push(config);
                }
            }
        }

        if in_proj_config_section {
            let cfg_re =
                regex::Regex::new(r#"^\s*(\{[^}]+\})\.([^.=]+\|[^.=]+)\.ActiveCfg\s*=\s*(.+)\s*$"#)
                    .unwrap();
            if let Some(caps) = cfg_re.captures(&line) {
                let guid = caps[1].to_string();
                let sln_cfg = caps[2].to_string();
                let proj_cfg = caps[3].trim().to_string();

                solution
                    .config_map
                    .entry(sln_cfg)
                    .or_insert_with(HashMap::new)
                    .insert(guid, proj_cfg);
            }
        }
    }

    Ok(solution)
}

pub fn parse_slnx(path: &str) -> Result<Solution, String> {
    let root_dir = get_directory(path).to_string();
    let mut solution = Solution {
        root_dir: root_dir.clone(),
        ..Default::default()
    };

    let content =
        fs::read_to_string(path).map_err(|e| format!("Failed to open {}: {}", path, e))?;

    // Extract <Project> elements, supporting both minimal (Path only) and full formats
    let re_proj_self = Regex::new(r#"<Project\s+[^>]*?Path="([^"]*)"[^>]*/>"#).unwrap();
    let re_proj_block =
        Regex::new(r#"<Project\s+[^>]*?Path="([^"]*)"[^>]*>([\s\S]*?)</Project>"#).unwrap();

    // Extract optional attributes
    let re_name = Regex::new(r#"Name="([^"]*)""#).unwrap();
    let re_guid = Regex::new(r#"Guid="\{([^}]*)\}""#).unwrap();
    let re_type = Regex::new(r#"ProjectType="([^"]*)""#).unwrap();

    for proj_re in [&re_proj_self, &re_proj_block] {
        for caps in proj_re.captures_iter(&content) {
            let tag_or_inner = &caps[0];
            let proj_path = caps[1].to_string();

            let name = re_name
                .captures(tag_or_inner)
                .map(|c| c[1].to_string())
                .unwrap_or_else(|| {
                    // Derive name from path: strip directory and extension
                    let filename = proj_path
                        .rsplit(|c| c == '/' || c == '\\')
                        .next()
                        .unwrap_or(&proj_path);
                    match filename.rfind('.') {
                        Some(pos) => filename[..pos].to_string(),
                        None => filename.to_string(),
                    }
                });

            let proj_type = re_type
                .captures(tag_or_inner)
                .map(|c| c[1].to_string())
                .unwrap_or_else(|| String::from("Cpp"));

            let proj_guid = re_guid
                .captures(tag_or_inner)
                .map(|c| c[1].to_string())
                .unwrap_or_else(|| name.clone());

            eprintln!("Parsing slnx project: {}, name: {}", proj_type, name);

            let project_path = format!("{}{}", root_dir, proj_path);

            let mut project = ProjectInfo {
                name,
                path: proj_path.clone(),
                full_path: project_path.clone(),
                guid: proj_guid.clone(),
                type_guid: proj_type,
                dependencies: Vec::new(),
                details: ProjectDetails::default(),
                sln_deps: None,
            };

            if proj_path.ends_with(".vcxproj") {
                project.dependencies = project::parse_vcxproj_deps(&project_path);
                project.details =
                    project::parse_vcxproj(&project_path, &root_dir).unwrap_or_default();
                eprintln!("Read project: {}", project_path);
            } else if proj_path.ends_with(".vcproj") {
                project.details =
                    project::parse_vcproj(&project_path, &root_dir).unwrap_or_default();
                eprintln!("Read project: {}", project_path);
            }

            // Parse <ProjectDependency> entries for block-form projects
            if tag_or_inner.contains("</Project>") {
                let re_dep =
                    Regex::new(r#"<ProjectDependency\s+[^>]*?Guid="([^"]*)"[^>]*/?>"#).unwrap();
                for dep_caps in re_dep.captures_iter(tag_or_inner) {
                    let dep_guid = dep_caps[1].to_string();
                    project.dependencies.push(dep_guid);
                }
            }

            solution.projects.insert(proj_guid, project);
        }
    }

    // Match <Platform Name="..." />
    let re_platform = Regex::new(r#"<Platform\s+Name="([^"]*)"[^>]*/?>"#).unwrap();
    for caps in re_platform.captures_iter(&content) {
        let config = caps[1].to_string();
        if !solution.configurations.contains(&config) {
            solution.configurations.push(config);
        }
    }

    // Match <ProjectConfiguration ...>...</ProjectConfiguration> if present
    let re_proj_cfg = Regex::new(
        r#"<ProjectConfiguration\s+[^>]*?Project="([^"]*)"[^>]*?Name="([^"]*)"[^>]*>[\s\S]*?</ProjectConfiguration>"#,
    ).unwrap();
    for caps in re_proj_cfg.captures_iter(&content) {
        let guid = caps[1].to_string();
        let config = caps[2].to_string();
        let proj_cfg = config.clone();
        solution
            .config_map
            .entry(config)
            .or_insert_with(HashMap::new)
            .insert(guid, proj_cfg);
    }

    let re_proj_cfg_inline =
        Regex::new(r#"<ProjectConfiguration\s+[^>]*?Project="([^"]*)"[^>]*?Name="([^"]*)"[^>]*/>"#)
            .unwrap();
    for caps in re_proj_cfg_inline.captures_iter(&content) {
        let guid = caps[1].to_string();
        let config = caps[2].to_string();
        let proj_cfg = config.clone();
        if !solution.config_map.contains_key(&config) {
            solution
                .config_map
                .entry(config)
                .or_insert_with(HashMap::new)
                .insert(guid, proj_cfg);
        }
    }

    Ok(solution)
}
