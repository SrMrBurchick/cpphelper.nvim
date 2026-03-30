pub fn get_file_extension(path: &str) -> &str {
    match path.rfind('.') {
        Some(pos) => &path[pos..],
        None => "",
    }
}

pub fn get_directory(filepath: &str) -> &str {
    match filepath.rfind(|c| c == '\\' || c == '/') {
        Some(pos) => &filepath[..=pos],
        None => "",
    }
}

/// Normalize a Windows path by resolving all ".." and "." segments.
pub fn normalize_path(path: &str) -> String {
    // Unify separators to backslash
    let path = path.replace('/', "\\");
    let (drive, rest) = if path.len() >= 2 && path.as_bytes()[1] == b':' {
        (&path[..2], &path[2..])
    } else {
        ("", path.as_str())
    };

    let mut parts: Vec<&str> = Vec::new();
    for part in rest.split('\\') {
        if part == ".." {
            parts.pop();
        } else if !part.is_empty() && part != "." {
            parts.push(part);
        }
    }

    let mut result = String::from(drive);
    if !parts.is_empty() {
        result.push('\\');
        result.push_str(&parts.join("\\"));
    }
    // Preserve trailing separator if original had one
    if path.ends_with('\\') {
        result.push('\\');
    }
    result
}

pub fn to_forward_slashes(path: &str) -> String {
    path.replace('\\', "/")
}

pub fn trim_quotes(s: &str) -> &str {
    let trimmed = s.trim();
    if trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2 {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    }
}
