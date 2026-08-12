mod cli;
mod commands;
mod git;

use std::env;
use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};

pub struct Context {
    pub home_dir: PathBuf,
}

impl Context {
    pub fn from_environment() -> Result<Self, String> {
        let home_dir = env::var_os("HOME")
            .map(PathBuf::from)
            .ok_or_else(|| "HOME is not set".to_string())?;
        Ok(Self { home_dir })
    }

    fn work_root(&self) -> PathBuf {
        self.home_dir.join("work")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunOutput {
    pub stdout: Option<String>,
    pub stderr: Option<String>,
}

impl RunOutput {
    pub(crate) fn stdout_only(line: impl Into<String>) -> Self {
        Self {
            stdout: Some(line.into()),
            stderr: None,
        }
    }

    pub(crate) fn stdout_with_stderr(stdout: impl Into<String>, stderr: impl Into<String>) -> Self {
        Self {
            stdout: Some(stdout.into()),
            stderr: Some(stderr.into()),
        }
    }

    pub(crate) fn stderr_only(line: impl Into<String>) -> Self {
        Self {
            stdout: None,
            stderr: Some(line.into()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AllocateRequest {
    pub slug: String,
    pub branch: Option<String>,
    pub base_ref: Option<String>,
    pub fetch: bool,
    pub branch_supplied: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeRequest {
    pub worktree_ref: String,
    pub branch: String,
}

pub fn usage_text() -> &'static str {
    cli::usage_text()
}

pub fn allocate(context: &Context, request: &AllocateRequest) -> Result<PathBuf, String> {
    commands::allocate_path(context, request)
}

pub fn resume(context: &Context, request: &ResumeRequest) -> Result<PathBuf, String> {
    commands::resume_path(context, request)
}

pub fn run<I, S>(context: &Context, args: I) -> Result<RunOutput, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let argv: Vec<String> = args
        .into_iter()
        .map(|value| value.as_ref().to_string_lossy().into_owned())
        .collect();
    let command = cli::parse_command(&argv)?;
    commands::dispatch(context, command)
}

pub fn exit_code_for_result(result: &Result<RunOutput, String>) -> i32 {
    if result.is_ok() { 0 } else { 1 }
}

pub fn as_os_string_vec(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

pub fn worktree_suffix(path: &Path) -> Option<String> {
    path.file_name()
        .map(|value| value.to_string_lossy().into_owned())
}
