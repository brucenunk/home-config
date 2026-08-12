use std::env;
use std::ffi::{CStr, OsStr};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};
use time::UtcOffset;
use time::macros::format_description;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorktreeInfo {
    pub(crate) path: PathBuf,
    pub(crate) branch: Option<String>,
    pub(crate) detached: bool,
}

pub(crate) fn find_primary_worktree(repo_root: &Path) -> Result<PathBuf, String> {
    let entries = fs::read_dir(repo_root)
        .map_err(|err| format!("failed to read repo root {}: {err}", repo_root.display()))?;

    for entry in entries {
        let entry = entry.map_err(|err| format!("failed to read repo root entry: {err}"))?;
        let child = entry.path();
        if !child.is_dir() || !child.join(".git").is_dir() {
            continue;
        }
        if git_status(&child, ["rev-parse", "--show-toplevel"]).is_ok() {
            return canonical_dir(&child).map_err(|_| {
                format!(
                    "failed to canonicalize primary worktree: {}",
                    child.display()
                )
            });
        }
    }

    Err(format!(
        "could not find primary worktree for {}",
        repo_root.display()
    ))
}

pub(crate) fn find_attached_worktree_for_branch(
    repo_root: &Path,
    primary: &Path,
    branch_name: &str,
) -> Result<Option<PathBuf>, String> {
    for worktree in list_worktrees(primary)? {
        if !is_child_worktree(repo_root, primary, &worktree.path) {
            continue;
        }
        if worktree.detached {
            continue;
        }
        if worktree.branch.as_deref() == Some(branch_name) {
            return Ok(Some(worktree.path));
        }
    }

    Ok(None)
}

pub(crate) fn first_detached_candidate(
    repo_root: &Path,
    primary: &Path,
) -> Result<Option<PathBuf>, String> {
    for worktree in list_worktrees(primary)? {
        if !is_child_worktree(repo_root, primary, &worktree.path) {
            continue;
        }
        if worktree.detached {
            return Ok(Some(worktree.path));
        }
    }

    Ok(None)
}

pub(crate) fn is_registered_worktree_path(primary: &Path, target: &Path) -> Result<bool, String> {
    Ok(list_worktrees(primary)?
        .into_iter()
        .any(|worktree| worktree.path == target))
}

pub(crate) fn is_child_worktree(repo_root: &Path, primary: &Path, worktree: &Path) -> bool {
    worktree != primary && worktree.parent() == Some(repo_root)
}

pub(crate) fn canonical_dir(path: &Path) -> io::Result<PathBuf> {
    if path.as_os_str().is_empty() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "empty path"));
    }
    let metadata = fs::metadata(path)?;
    if !metadata.is_dir() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "not a directory"));
    }
    fs::canonicalize(path)
}

pub(crate) fn current_worktree_root() -> Result<PathBuf, String> {
    let current_dir = env::current_dir()
        .map_err(|_| "current directory is not inside a linked worktree".to_string())?;
    let top = git_output(&current_dir, ["rev-parse", "--show-toplevel"])
        .map_err(|_| "current directory is not inside a linked worktree".to_string())?;
    canonical_dir(Path::new(trim_line_endings(&top)))
        .map_err(|_| "current directory is not inside a linked worktree".to_string())
}

pub(crate) fn is_detached(worktree: &Path) -> Result<bool, String> {
    Ok(trim_line_endings(&git_output(
        worktree,
        ["rev-parse", "--abbrev-ref", "HEAD"],
    )?) == "HEAD")
}

pub(crate) fn is_clean_worktree(worktree: &Path) -> Result<bool, String> {
    git_status(worktree, ["update-index", "-q", "--refresh"])?;
    if git_status(worktree, ["diff-index", "--quiet", "HEAD", "--"]).is_err() {
        return Ok(false);
    }
    if git_status(worktree, ["diff-files", "--quiet", "--"]).is_err() {
        return Ok(false);
    }
    let others = git_output(worktree, ["ls-files", "--others", "--exclude-standard"])?;
    Ok(others.trim().is_empty())
}

pub(crate) fn branch_exists_local(primary: &Path, branch_name: &str) -> Result<bool, String> {
    Ok(git_status(
        primary,
        [
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch_name}"),
        ],
    )
    .is_ok())
}

pub(crate) fn branch_exists_origin_remote(
    primary: &Path,
    branch_name: &str,
) -> Result<bool, String> {
    Ok(git_status(
        primary,
        [
            "show-ref",
            "--verify",
            "--quiet",
            &format!("refs/remotes/origin/{branch_name}"),
        ],
    )
    .is_ok())
}

pub(crate) fn current_branch_name(worktree: &Path) -> Result<String, String> {
    Ok(trim_line_endings(&git_output(
        worktree,
        ["rev-parse", "--abbrev-ref", "HEAD"],
    )?)
    .to_string())
}

pub(crate) fn default_branch_name(primary: &Path) -> Result<String, String> {
    let symbolic_ref = git_output(
        primary,
        ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
    )?;
    let value = trim_line_endings(&symbolic_ref);
    value
        .strip_prefix("refs/remotes/origin/")
        .map(ToString::to_string)
        .ok_or_else(|| format!("unexpected origin/HEAD symbolic ref: {value}"))
}

pub(crate) fn resolve_base_ref(primary: &Path) -> Result<String, String> {
    let branch_name = default_branch_name(primary)?;
    if branch_name.is_empty() {
        return Err(format!(
            "could not determine default base ref for {}",
            primary.display()
        ));
    }
    Ok(format!("origin/{branch_name}"))
}

pub(crate) fn verify_base_ref(primary: &Path, base_ref: &str) -> Result<(), String> {
    git_status(
        primary,
        [
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("{base_ref}^{{commit}}"),
        ],
    )
    .map_err(|_| format!("base ref not found: {base_ref}"))
}

pub(crate) fn maybe_fetch(primary: &Path, do_fetch: bool) -> Result<(), String> {
    if !do_fetch {
        return Ok(());
    }

    git_status(primary, ["fetch", "--prune", "origin"])
        .map_err(|err| format!("failed to fetch origin in {}: {err}", primary.display()))
}

pub(crate) fn origin_branch_exists_live(primary: &Path, branch_name: &str) -> Result<bool, String> {
    let output = git_command(
        primary,
        ["ls-remote", "--exit-code", "--heads", "origin", branch_name],
    )?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(2) => Ok(false),
        _ => Err(format!(
            "failed to query origin for branch {} in {}: {}",
            branch_name,
            primary.display(),
            trim_line_endings(&combined_output(&output))
        )),
    }
}

pub(crate) fn fetch_origin_branch(primary: &Path, branch_name: &str) -> Result<(), String> {
    git_status(
        primary,
        [
            "fetch",
            "origin",
            &format!("refs/heads/{branch_name}:refs/remotes/origin/{branch_name}"),
        ],
    )
    .map_err(|err| {
        format!(
            "failed to fetch branch {} from origin in {}: {err}",
            branch_name,
            primary.display()
        )
    })
}

pub(crate) fn generated_explore_branch(primary: &Path) -> Result<String, String> {
    let user_name = match sanitize_branch_component(&current_user_name()) {
        value if value.is_empty() => "user".to_string(),
        value => value,
    };

    for _ in 0..20 {
        let timestamp = branch_timestamp();
        let suffix = format!("{}-{}", std::process::id(), randomish_suffix());
        let candidate = format!("{user_name}-E{timestamp}-{suffix}");
        if !branch_exists_local(primary, &candidate)?
            && !branch_exists_origin_remote(primary, &candidate)?
        {
            return Ok(candidate);
        }
    }

    Err("failed to generate a unique exploration branch name".to_string())
}

pub(crate) fn checkout_existing_branch(worktree: &Path, branch_name: &str) -> Result<(), String> {
    git_status(worktree, ["switch", branch_name]).map_err(|err| {
        format!(
            "failed to switch {} to branch {}: {err}",
            worktree.display(),
            branch_name
        )
    })
}

pub(crate) fn checkout_origin_remote_branch(
    worktree: &Path,
    branch_name: &str,
) -> Result<(), String> {
    git_status(
        worktree,
        [
            "switch",
            "--track",
            "-c",
            branch_name,
            &format!("origin/{branch_name}"),
        ],
    )
    .map_err(|err| {
        format!(
            "failed to create tracking branch {} from origin/{} in {}: {err}",
            branch_name,
            branch_name,
            worktree.display()
        )
    })
}

pub(crate) fn create_branch_from_base(
    worktree: &Path,
    branch_name: &str,
    base_ref: &str,
) -> Result<(), String> {
    git_status(worktree, ["switch", "-c", branch_name, base_ref]).map_err(|err| {
        format!(
            "failed to create branch {} from {} in {}: {err}",
            branch_name,
            base_ref,
            worktree.display()
        )
    })
}

pub(crate) fn detach_worktree(worktree: &Path) -> Result<(), String> {
    git_status(worktree, ["checkout", "--detach", "HEAD"])
        .map_err(|err| format!("failed to detach worktree {}: {err}", worktree.display()))
}

pub(crate) fn git_output<I, S>(worktree: &Path, args: I) -> Result<String, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = git_command(worktree, args)?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(trim_line_endings(&combined_output(&output)).to_string())
    }
}

fn list_worktrees(command_dir: &Path) -> Result<Vec<WorktreeInfo>, String> {
    let output = git_output(command_dir, ["worktree", "list", "--porcelain"])?;
    let mut worktrees = Vec::new();
    let mut current_path: Option<PathBuf> = None;
    let mut current_branch: Option<String> = None;
    let mut detached = false;

    let mut emit = |path: Option<PathBuf>, branch: Option<String>, detached_flag: bool| {
        if let Some(path) = path {
            worktrees.push(WorktreeInfo {
                path,
                branch,
                detached: detached_flag,
            });
        }
    };

    for raw_line in output.lines() {
        if let Some(value) = raw_line.strip_prefix("worktree ") {
            emit(current_path.take(), current_branch.take(), detached);
            current_path = Some(PathBuf::from(value));
            current_branch = None;
            detached = false;
        } else if let Some(value) = raw_line.strip_prefix("branch refs/heads/") {
            current_branch = Some(value.to_string());
        } else if raw_line == "detached" {
            detached = true;
        }
    }
    emit(current_path, current_branch, detached);

    let mut normalized = Vec::new();
    for worktree in worktrees {
        if !worktree.path.is_dir() {
            continue;
        }
        let path = canonical_dir(&worktree.path).map_err(|_| {
            format!(
                "failed to canonicalize worktree path: {}",
                worktree.path.display()
            )
        })?;
        normalized.push(WorktreeInfo {
            path,
            branch: worktree.branch,
            detached: worktree.detached,
        });
    }

    Ok(normalized)
}

fn sanitize_branch_component(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
                ch
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn current_user_name() -> String {
    current_user_name_from_system()
        .filter(|value| !value.is_empty())
        .or_else(|| env::var("USER").ok().filter(|value| !value.is_empty()))
        .or_else(|| env::var("LOGNAME").ok().filter(|value| !value.is_empty()))
        .unwrap_or_else(|| "user".to_string())
}

fn current_user_name_from_system() -> Option<String> {
    let uid = unsafe { libc::geteuid() };
    let passwd = unsafe { libc::getpwuid(uid) };
    if passwd.is_null() {
        return None;
    }

    let name = unsafe { CStr::from_ptr((*passwd).pw_name) };
    Some(name.to_string_lossy().into_owned())
}

fn branch_timestamp() -> String {
    const BRANCH_TIMESTAMP_FORMAT: &[time::format_description::FormatItem<'static>] =
        format_description!("[year][month][day]T[hour][minute][second]");

    let now = time::OffsetDateTime::now_utc();
    let now = match UtcOffset::current_local_offset() {
        Ok(offset) => now.to_offset(offset),
        Err(_) => now,
    };

    now.format(BRANCH_TIMESTAMP_FORMAT).unwrap_or_else(|_| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
            .to_string()
    })
}

fn randomish_suffix() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        % 100_000
}

fn git_command<I, S>(worktree: &Path, args: I) -> Result<Output, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let mut command = Command::new("git");
    command.arg("-c").arg("core.fsmonitor=false");
    command.arg("-C").arg(worktree);
    for arg in args {
        command.arg(arg.as_ref());
    }
    command
        .output()
        .map_err(|err| format!("failed to run git in {}: {err}", worktree.display()))
}

fn git_status<I, S>(worktree: &Path, args: I) -> Result<(), String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = git_command(worktree, args)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(trim_line_endings(&combined_output(&output)).to_string())
    }
}

fn combined_output(output: &Output) -> String {
    let mut combined = String::new();
    combined.push_str(&String::from_utf8_lossy(&output.stdout));
    combined.push_str(&String::from_utf8_lossy(&output.stderr));
    combined
}

fn trim_line_endings(value: &str) -> &str {
    value.trim_end_matches(['\r', '\n'])
}
