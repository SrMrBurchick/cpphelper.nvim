use crate::paths::{normalize_path, to_forward_slashes};
use crate::solution::{ConfigEntry, Solution};
use serde::Serialize;
use std::fs;

#[derive(Debug, Serialize)]
pub struct CompileCommand {
    pub directory: String,
    pub command: String,
    pub file: String,
}

fn build_command(file_path: &str, config_data: &ConfigEntry, headers: &[String]) -> String {
    let mut cmd = String::from("cl.exe /c /EHsc ");

    if let Some(ref inline) = config_data.inline_expansion {
        cmd.push_str(inline);
        cmd.push(' ');
    }

    let defines = &config_data.defines;
    for define in defines.split(';') {
        if !define.is_empty() && !define.contains('%') && !define.contains('$') {
            cmd.push_str("/D");
            cmd.push_str(define);
            cmd.push(' ');
        }
    }

    for inc in &config_data.include_dirs {
        cmd.push_str(&format!(
            "/I\"{}\" ",
            to_forward_slashes(&normalize_path(inc))
        ));
    }

    for hdr in headers {
        cmd.push_str(&format!("/FI\"{}\" ", to_forward_slashes(hdr)));
    }

    cmd.push_str(&format!("\"{}\"", to_forward_slashes(file_path)));
    cmd
}

pub fn generate_compile_commands(
    solution: &Solution,
    target_solution_config: Option<&str>,
    output_path: &str,
) -> Result<usize, String> {
    let mut db: Vec<CompileCommand> = Vec::new();

    for project in solution.projects.values() {
        let configurations = match &project.details.configurations {
            Some(c) => c,
            None => continue,
        };

        // Resolve the project-specific config name from the solution config map
        let resolved_config = if let Some(tsc) = target_solution_config {
            solution
                .config_map
                .get(tsc)
                .and_then(|guid_map| guid_map.get(&project.guid))
                .map(|s| s.as_str())
                .unwrap_or(tsc)
        } else {
            ""
        };

        let proj_dir = crate::paths::get_directory(&project.full_path);

        for (config_name, config_data) in configurations {
            if !resolved_config.is_empty() && config_name != resolved_config {
                continue;
            }

            eprintln!("Parsing project: {} config: {}", project.name, config_name);

            // Collect header files for forced includes
            let headers: Vec<String> = config_data
                .files
                .iter()
                .filter(|f| f.file_type == "ClInclude")
                .map(|f| {
                    let abs_hdr = if !f.path.contains(':')
                        && !f.path.starts_with('\\')
                        && !f.path.starts_with('/')
                    {
                        format!("{}{}", proj_dir, f.path)
                    } else {
                        f.path.clone()
                    };
                    normalize_path(&abs_hdr)
                })
                .collect();

            for file in &config_data.files {
                if file.file_type == "ClCompile" {
                    let abs_path = if !file.path.contains(':')
                        && !file.path.starts_with('\\')
                        && !file.path.starts_with('/')
                    {
                        format!("{}{}", proj_dir, file.path)
                    } else {
                        file.path.clone()
                    };

                    let norm_path = normalize_path(&abs_path);
                    let norm_dir = normalize_path(proj_dir);
                    let fwd_path = to_forward_slashes(&norm_path);
                    let fwd_dir = to_forward_slashes(&norm_dir);

                    db.push(CompileCommand {
                        directory: fwd_dir,
                        command: build_command(&norm_path, config_data, &headers),
                        file: fwd_path,
                    });
                }
            }
        }
    }

    let count = db.len();
    let json = serde_json::to_string_pretty(&db)
        .map_err(|e| format!("JSON serialization error: {}", e))?;
    fs::write(output_path, json).map_err(|e| format!("Failed to write {}: {}", output_path, e))?;

    eprintln!(
        "Generated: {} for {} ({} entries)",
        output_path,
        target_solution_config.unwrap_or("all"),
        count
    );

    Ok(count)
}
