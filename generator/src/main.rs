mod compile_commands;
mod paths;
mod project;
mod sln;
mod solution;

use solution::Solution;
use std::fs;
use std::path::Path;

fn usage() -> ! {
    eprintln!("Usage:");
    eprintln!("  generator load <path-to-sln> <output-dir>");
    eprintln!("  generator compile-commands <solution-config> <solution-json> <output-path>");
    eprintln!();
    eprintln!("Commands:");
    eprintln!("  load              Parse a .sln or .slnx file and write solution JSON + cache");
    eprintln!("  compile-commands  Generate compile_commands.json from cached solution data");
    std::process::exit(1);
}

fn cmd_load(sln_path: &str, output_dir: &str) {
    eprintln!("Loading Solution");

    let ext = paths::get_file_extension(sln_path);
    if ext != ".sln" && ext != ".slnx" {
        eprintln!("Unsupported file type: {}", ext);
        std::process::exit(1);
    }

    let solution = if ext == ".slnx" {
        match sln::parse_slnx(sln_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Failed to parse solution: {}", e);
                std::process::exit(1);
            }
        }
    } else {
        match sln::parse_sln(sln_path) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("Failed to parse solution: {}", e);
                std::process::exit(1);
            }
        }
    };

    // Create cache directory
    let cache_dir = Path::new(output_dir);
    if !cache_dir.exists() {
        eprintln!("Creating cache: {:?}", cache_dir);
        if let Err(e) = fs::create_dir_all(&cache_dir) {
            eprintln!("Failed to create cache directory: {}", e);
            std::process::exit(1);
        }
    }

    // Write helper.json cache
    let cache_path = cache_dir.join("helper.json");
    match serde_json::to_string_pretty(&solution) {
        Ok(json) => {
            if let Err(e) = fs::write(&cache_path, &json) {
                eprintln!("Failed to write cache: {}", e);
                std::process::exit(1);
            }
            eprintln!("Writing file: {:?}", cache_path);
        }
        Err(e) => {
            eprintln!("Failed to serialize solution: {}", e);
            std::process::exit(1);
        }
    }

    eprintln!("Solution loaded successfully");
}

fn cmd_compile_commands(target_config: &str, solution_json_path: &str, output_path: &str) {
    eprintln!("Generating compile_commands.json");

    let content = match fs::read_to_string(solution_json_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("Failed to read solution JSON: {}", e);
            std::process::exit(1);
        }
    };

    let solution: Solution = match serde_json::from_str(&content) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Failed to parse solution JSON: {}", e);
            std::process::exit(1);
        }
    };

    let target = if target_config.is_empty() || target_config == "all" {
        None
    } else {
        Some(target_config)
    };

    match compile_commands::generate_compile_commands(&solution, target, output_path) {
        Ok(count) => {
            eprintln!("Generated {} compile commands", count);
        }
        Err(e) => {
            eprintln!("Failed to generate compile commands: {}", e);
            std::process::exit(1);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        usage();
    }

    match args[1].as_str() {
        "load" => {
            if args.len() < 4 {
                eprintln!("Usage: generator load <path-to-sln> <output-dir>");
                std::process::exit(1);
            }
            cmd_load(&args[2], &args[3]);
        }
        "compile-commands" => {
            if args.len() < 5 {
                eprintln!("Usage: generator compile-commands <solution-config> <solution-json> <output-path>");
                std::process::exit(1);
            }
            cmd_compile_commands(&args[2], &args[3], &args[4]);
        }
        _ => usage(),
    }
}
