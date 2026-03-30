use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectInfo {
    pub name: String,
    pub path: String,
    #[serde(rename = "fullPath")]
    pub full_path: String,
    pub guid: String,
    #[serde(rename = "typeGuid")]
    pub type_guid: String,
    pub dependencies: Vec<String>,
    pub details: ProjectDetails,
    #[serde(rename = "slnDeps", skip_serializing_if = "Option::is_none")]
    pub sln_deps: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectDetails {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub configurations: Option<HashMap<String, ConfigEntry>>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ConfigEntry {
    pub files: Vec<FileEntry>,
    #[serde(default)]
    pub defines: String,
    #[serde(default)]
    pub include_dirs: Vec<String>,
    #[serde(rename = "inlineExpansion", skip_serializing_if = "Option::is_none")]
    pub inline_expansion: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntry {
    pub path: String,
    #[serde(rename = "type")]
    pub file_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Solution {
    #[serde(rename = "rootDir")]
    pub root_dir: String,
    pub projects: HashMap<String, ProjectInfo>,
    pub globals: HashMap<String, String>,
    pub configurations: Vec<String>,
    /// maps { [solution_config] = { [proj_guid] = project_config } }
    #[serde(rename = "configMap")]
    pub config_map: HashMap<String, HashMap<String, String>>,
}
