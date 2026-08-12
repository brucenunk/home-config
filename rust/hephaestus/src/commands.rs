use crate::cli::{AllocateArgs, CommandKind, ReleaseArgs, ResumeArgs, usage_text};
use crate::git::{
    branch_exists_local, branch_exists_origin_remote, canonical_dir, checkout_existing_branch,
    checkout_origin_remote_branch, create_branch_from_base, current_branch_name,
    current_worktree_root, default_branch_name, detach_worktree, fetch_origin_branch,
    find_attached_worktree_for_branch, find_primary_worktree, first_detached_candidate,
    generated_explore_branch, git_output, is_child_worktree, is_clean_worktree, is_detached,
    is_registered_worktree_path, maybe_fetch, origin_branch_exists_live, resolve_base_ref,
    verify_base_ref,
};
use crate::{AllocateRequest, Context, ResumeRequest, RunOutput};
use std::fs::{File, OpenOptions};
#[cfg(any(target_os = "macos", target_os = "ios"))]
use std::os::fd::AsRawFd;
use std::path::{Component, Path, PathBuf};

#[derive(Debug)]
struct RepoLock {
    _file: File,
}

impl RepoLock {
    fn acquire(repo_root: &Path) -> Result<Self, String> {
        let lock_file = repo_root.join(".hephaestus.lock");
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&lock_file)
            .map_err(|err| format!("failed to open repo lock {}: {err}", lock_file.display()))?;

        try_lock_exclusive(&file).map_err(|_| {
            format!(
                "repo is locked by another hephaestus operation: {}",
                repo_root.display()
            )
        })?;

        Ok(Self { _file: file })
    }
}

#[cfg(any(target_os = "macos", target_os = "ios"))]
fn try_lock_exclusive(file: &File) -> std::io::Result<()> {
    let result = unsafe { libc::lockf(file.as_raw_fd(), libc::F_TLOCK, 0) };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn try_lock_exclusive(file: &File) -> std::io::Result<()> {
    fs2::FileExt::try_lock_exclusive(file)
}

pub(crate) fn dispatch(context: &Context, command: CommandKind) -> Result<RunOutput, String> {
    match command {
        CommandKind::Allocate(args) => {
            if args.help_requested {
                return Ok(RunOutput::stderr_only(usage_text().trim_end()));
            }
            cmd_allocate(context, args)
        }
        CommandKind::Resume(args) => cmd_resume(context, args),
        CommandKind::Release(args) => cmd_release(context, args),
        CommandKind::Help => Ok(RunOutput::stderr_only(usage_text().trim_end())),
    }
}

pub(crate) fn allocate_path(
    context: &Context,
    request: &AllocateRequest,
) -> Result<PathBuf, String> {
    let output = cmd_allocate(
        context,
        AllocateArgs {
            slug: request.slug.clone(),
            branch: request.branch.clone(),
            base_ref: request.base_ref.clone(),
            fetch: request.fetch,
            branch_supplied: request.branch_supplied,
            help_requested: false,
        },
    )?;
    output_path(output)
}

pub(crate) fn resume_path(context: &Context, request: &ResumeRequest) -> Result<PathBuf, String> {
    let output = cmd_resume(
        context,
        ResumeArgs {
            worktree_ref: request.worktree_ref.clone(),
            branch: request.branch.clone(),
        },
    )?;
    output_path(output)
}

fn output_path(output: RunOutput) -> Result<PathBuf, String> {
    let stdout = output
        .stdout
        .ok_or_else(|| "missing hephaestus stdout path".to_string())?;
    let line = stdout
        .lines()
        .next()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "missing hephaestus stdout path".to_string())?;
    Ok(PathBuf::from(line))
}

fn cmd_allocate(context: &Context, args: AllocateArgs) -> Result<RunOutput, String> {
    let repo_root = repo_root_from_slug(context, &args.slug)?;
    let primary = find_primary_worktree(&repo_root)?;
    let _lock = RepoLock::acquire(&repo_root)?;

    if let Some(branch) = args.branch.as_deref() {
        let primary_branch = current_branch_name(&primary)?;
        let remote_default_branch = default_branch_name(&primary).ok();

        if branch == primary_branch {
            return Err(format!(
                "refusing to allocate primary worktree branch: {branch}"
            ));
        }
        if remote_default_branch.as_deref() == Some(branch) {
            return Err(format!("refusing to allocate default branch: {branch}"));
        }
        if let Some(existing) = find_attached_worktree_for_branch(&repo_root, &primary, branch)? {
            return Ok(RunOutput::stdout_only(display_path(&existing)));
        }
    }

    maybe_fetch(&primary, args.fetch)?;

    let candidate = first_detached_candidate(&repo_root, &primary)?
        .ok_or_else(|| format!("no detached worktree available for {}", args.slug))?;
    if !is_clean_worktree(&candidate)? {
        return Err(format!(
            "detached worktree is dirty and blocks allocation: {}",
            candidate.display()
        ));
    }

    let mut generated = false;
    let branch = match args.branch {
        Some(branch) => branch,
        None => {
            generated = true;
            generated_explore_branch(&primary)?
        }
    };

    if branch_exists_local(&primary, &branch)? {
        checkout_existing_branch(&candidate, &branch)?;
    } else if branch_exists_origin_remote(&primary, &branch)? {
        checkout_origin_remote_branch(&candidate, &branch)?;
    } else if args.branch_supplied && origin_branch_exists_live(&primary, &branch)? {
        fetch_origin_branch(&primary, &branch)?;
        checkout_origin_remote_branch(&candidate, &branch)?;
    } else {
        let base_ref = match args.base_ref {
            Some(base_ref) => base_ref,
            None => resolve_base_ref(&primary)?,
        };
        verify_base_ref(&primary, &base_ref)?;
        create_branch_from_base(&candidate, &branch, &base_ref)?;
    }

    if generated {
        return Ok(RunOutput::stdout_with_stderr(
            display_path(&candidate),
            format!("allocated branch: {branch}"),
        ));
    }

    Ok(RunOutput::stdout_only(display_path(&candidate)))
}

fn cmd_resume(context: &Context, args: ResumeArgs) -> Result<RunOutput, String> {
    let target = resolve_worktree_ref(context, &args.worktree_ref)?;
    let repo_root = repo_root_from_worktree_path(context, &target)?;
    let primary = find_primary_worktree(&repo_root).map_err(|_| {
        format!(
            "could not find primary worktree for repo containing {}",
            target.display()
        )
    })?;
    let _lock = RepoLock::acquire(&repo_root)?;

    if !is_child_worktree(&repo_root, &primary, &target) {
        return Err(format!(
            "refusing to resume primary worktree: {}",
            target.display()
        ));
    }
    if !is_registered_worktree_path(&primary, &target)? {
        return Err(format!(
            "refusing to resume unregistered worktree: {}",
            target.display()
        ));
    }
    if is_detached(&target)? {
        if !is_clean_worktree(&target)? {
            return Err(format!(
                "requested worktree is detached but dirty: {}",
                target.display()
            ));
        }
        if let Some(attached_elsewhere) =
            find_attached_worktree_for_branch(&repo_root, &primary, &args.branch)?
        {
            return Err(format!(
                "requested branch is already attached in another worktree: {}",
                attached_elsewhere.display()
            ));
        }
        if !branch_exists_local(&primary, &args.branch)? {
            return Err(format!("branch not found: {}", args.branch));
        }
        checkout_existing_branch(&target, &args.branch)?;
        return Ok(RunOutput::stdout_only(display_path(&target)));
    }

    let current_branch = current_branch_name(&target)?;
    if current_branch == args.branch {
        return Ok(RunOutput::stdout_only(display_path(&target)));
    }

    Err(format!(
        "requested worktree is attached to a different branch: {} (current: {})",
        target.display(),
        current_branch
    ))
}

fn cmd_release(context: &Context, args: ReleaseArgs) -> Result<RunOutput, String> {
    let target = match args.worktree {
        Some(requested) => {
            let resolved = git_output(Path::new(&requested), ["rev-parse", "--show-toplevel"])
                .map_err(|_| format!("not a git worktree: {requested}"))?;
            canonical_dir(Path::new(resolved.trim_end_matches(['\r', '\n'])))
                .map_err(|_| format!("worktree not found: {requested}"))?
        }
        None => current_worktree_root()?,
    };

    if git_output(&target, ["rev-parse", "--show-toplevel"]).is_err() {
        return Err(format!("not a git worktree: {}", target.display()));
    }

    let repo_root = repo_root_from_worktree_path(context, &target)?;
    let primary = find_primary_worktree(&repo_root).map_err(|_| {
        format!(
            "could not find primary worktree for repo containing {}",
            target.display()
        )
    })?;
    let _lock = RepoLock::acquire(&repo_root)?;

    if !is_child_worktree(&repo_root, &primary, &target) {
        return Err(format!(
            "refusing to release primary worktree: {}",
            target.display()
        ));
    }
    if !is_registered_worktree_path(&primary, &target)? {
        return Err(format!(
            "refusing to release unregistered worktree: {}",
            target.display()
        ));
    }
    if is_detached(&target)? {
        return Err(format!(
            "worktree is already detached: {}",
            target.display()
        ));
    }
    if !is_clean_worktree(&target)? {
        return Err(format!(
            "refusing to release dirty worktree: {}",
            target.display()
        ));
    }

    detach_worktree(&target)?;
    Ok(RunOutput::stdout_only(display_path(&target)))
}

fn managed_work_root(context: &Context) -> Result<PathBuf, String> {
    canonical_dir(&context.work_root()).map_err(|_| {
        format!(
            "managed worktree root not found: {}",
            context.work_root().display()
        )
    })
}

fn repo_root_from_slug(context: &Context, slug: &str) -> Result<PathBuf, String> {
    let components: Vec<_> = Path::new(slug).components().collect();
    if components.len() != 2
        || !components
            .iter()
            .all(|part| matches!(part, Component::Normal(_)))
    {
        return Err(format!("invalid repo slug (expected owner/repo): {slug}"));
    }

    let managed_root = managed_work_root(context)?;
    let repo_root =
        canonical_dir(&managed_root.join(slug)).map_err(|_| format!("repo not found: {slug}"))?;
    let relative = repo_root.strip_prefix(&managed_root).map_err(|_| {
        format!(
            "refusing to allocate unmanaged repo outside {}: {}",
            managed_root.display(),
            repo_root.display()
        )
    })?;
    if relative.components().count() != 2
        || !relative
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
    {
        return Err(format!(
            "repo is not a direct owner/repo child of {}: {}",
            managed_root.display(),
            repo_root.display()
        ));
    }
    Ok(repo_root)
}

fn repo_root_from_worktree_path(context: &Context, target: &Path) -> Result<PathBuf, String> {
    let managed_root = managed_work_root(context)?;
    let normalized = canonical_dir(target)
        .map_err(|_| format!("could not resolve worktree path: {}", target.display()))?;
    let relative = normalized.strip_prefix(&managed_root).map_err(|_| {
        format!(
            "refusing to manage worktree outside {}: {}",
            managed_root.display(),
            normalized.display()
        )
    })?;
    if relative.components().count() != 3
        || !relative
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
    {
        return Err(format!(
            "worktree is not a direct owner/repo/worktree child: {}",
            normalized.display()
        ));
    }

    let repo_root = normalized
        .parent()
        .ok_or_else(|| format!("could not determine repo root for {}", normalized.display()))?;
    canonical_dir(repo_root)
        .map_err(|_| format!("could not determine repo root for {}", normalized.display()))
}

fn resolve_worktree_ref(context: &Context, reference: &str) -> Result<PathBuf, String> {
    let target = if Path::new(reference).is_absolute() {
        PathBuf::from(reference)
    } else {
        context.work_root().join(reference)
    };
    let normalized =
        canonical_dir(&target).map_err(|_| format!("worktree not found: {reference}"))?;
    let managed_root = canonical_dir(&context.work_root()).map_err(|_| {
        format!(
            "managed worktree root not found: {}",
            context.work_root().display()
        )
    })?;
    if !normalized.starts_with(&managed_root) {
        return Err(format!(
            "refusing to resume unmanaged worktree outside {}: {}",
            managed_root.display(),
            normalized.display()
        ));
    }
    Ok(normalized)
}

fn display_path(path: &Path) -> String {
    path.display().to_string()
}
