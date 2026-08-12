use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use tempfile::TempDir;

struct Sandbox {
    _tempdir: TempDir,
    home: PathBuf,
    repo_root: PathBuf,
    primary: PathBuf,
    slot_a: PathBuf,
    slot_b: PathBuf,
    scratch: PathBuf,
    seed: PathBuf,
}

impl Sandbox {
    fn new() -> Self {
        let tempdir = TempDir::new().expect("tempdir");
        let home = tempdir.path().join("home");
        let work_root = home.join("work");
        let repo_root = work_root.join("TestOwner").join("testrepo");
        let primary = repo_root.join("main");
        let slot_a = repo_root.join("a");
        let slot_b = repo_root.join("b");
        let scratch = repo_root.join("0scratch");
        let origin = tempdir.path().join("origin.git");
        let seed = tempdir.path().join("seed");

        std::fs::create_dir_all(&repo_root).expect("repo root");

        run_ok(
            tempdir.path(),
            [
                "git",
                "init",
                "--bare",
                "--initial-branch=main",
                origin.to_str().unwrap(),
            ],
        );
        run_ok(
            tempdir.path(),
            [
                "git",
                "init",
                "--initial-branch=main",
                seed.to_str().unwrap(),
            ],
        );
        configure_git_user(&seed);
        std::fs::write(seed.join("README.md"), "hello\n").expect("seed file");
        run_ok(&seed, ["git", "add", "README.md"]);
        run_ok(&seed, ["git", "commit", "-m", "initial"]);
        run_ok(
            &seed,
            ["git", "remote", "add", "origin", origin.to_str().unwrap()],
        );
        run_ok(&seed, ["git", "push", "-u", "origin", "main"]);

        run_ok(
            tempdir.path(),
            [
                "git",
                "clone",
                origin.to_str().unwrap(),
                primary.to_str().unwrap(),
            ],
        );
        configure_git_user(&primary);
        run_ok(&primary, ["git", "remote", "set-head", "origin", "-a"]);
        run_ok(
            &primary,
            [
                "git",
                "worktree",
                "add",
                "--detach",
                slot_a.to_str().unwrap(),
                "HEAD",
            ],
        );
        run_ok(
            &primary,
            [
                "git",
                "worktree",
                "add",
                "--detach",
                slot_b.to_str().unwrap(),
                "HEAD",
            ],
        );
        run_ok(
            &primary,
            [
                "git",
                "worktree",
                "add",
                "--detach",
                scratch.to_str().unwrap(),
                "HEAD",
            ],
        );

        Self {
            _tempdir: tempdir,
            home,
            repo_root,
            primary,
            slot_a,
            slot_b,
            scratch,
            seed,
        }
    }

    fn hephaestus(&self, current_dir: &Path, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_hephaestus"))
            .current_dir(current_dir)
            .env("HOME", &self.home)
            .env("USER", "jamesl")
            .args(args)
            .output()
            .expect("run hephaestus")
    }

    fn create_local_branch(&self, branch: &str) {
        run_ok(&self.primary, ["git", "branch", branch, "origin/main"]);
    }

    fn create_remote_only_branch(&self, branch: &str) {
        run_ok(&self.seed, ["git", "switch", "-c", branch, "main"]);
        run_ok(&self.seed, ["git", "push", "-u", "origin", branch]);
        run_ok(&self.seed, ["git", "switch", "main"]);
        run_ok(&self.seed, ["git", "branch", "-D", branch]);
    }

    fn switch_slot_to_new_branch(&self, slot: &Path, branch: &str) {
        run_ok(slot, ["git", "switch", "-c", branch, "origin/main"]);
    }
}

#[test]
fn allocate_returns_existing_attached_worktree_and_refuses_default_branch() {
    let sandbox = Sandbox::new();
    sandbox.switch_slot_to_new_branch(&sandbox.slot_b, "feature");

    let output = sandbox.hephaestus(
        &sandbox.repo_root,
        &["allocate", "TestOwner/testrepo", "feature"],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), canonical_display(&sandbox.slot_b));

    let refusal = sandbox.hephaestus(
        &sandbox.repo_root,
        &["allocate", "TestOwner/testrepo", "main"],
    );
    assert!(!refusal.status.success());
    assert!(
        stderr(&refusal).contains("refusing to allocate") && stderr(&refusal).contains("main"),
        "{}",
        stderr(&refusal)
    );
}

#[test]
fn allocate_probes_origin_for_remote_only_branch() {
    let sandbox = Sandbox::new();
    sandbox.create_remote_only_branch("remote-only");

    let output = sandbox.hephaestus(
        &sandbox.repo_root,
        &["allocate", "TestOwner/testrepo", "remote-only"],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    let allocated = PathBuf::from(stdout(&output));
    assert_eq!(
        git_stdout(&allocated, ["rev-parse", "--abbrev-ref", "HEAD"]),
        "remote-only"
    );
}

#[test]
fn allocate_rejects_absolute_and_traversal_slugs() {
    let sandbox = Sandbox::new();

    for slug in ["/tmp/repo", "../testrepo", "TestOwner/../testrepo"] {
        let output = sandbox.hephaestus(&sandbox.repo_root, &["allocate", slug]);
        assert!(!output.status.success());
        assert!(
            stderr(&output).contains("invalid repo slug"),
            "slug {slug}: {}",
            stderr(&output)
        );
    }
}

#[test]
fn allocate_rejects_symlink_to_deeper_managed_directory() {
    let sandbox = Sandbox::new();
    let alias_owner = sandbox.home.join("work").join("AliasOwner");
    std::fs::create_dir(&alias_owner).expect("alias owner");
    std::os::unix::fs::symlink(&sandbox.primary, alias_owner.join("repo")).expect("repo symlink");

    let output = sandbox.hephaestus(&sandbox.repo_root, &["allocate", "AliasOwner/repo"]);
    assert!(!output.status.success());
    assert!(
        stderr(&output).contains("repo is not a direct owner/repo child"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn release_rejects_git_worktree_outside_managed_root() {
    let sandbox = Sandbox::new();

    let output = sandbox.hephaestus(
        &sandbox.repo_root,
        &["release", sandbox.seed.to_str().unwrap()],
    );
    assert!(!output.status.success());
    assert!(
        stderr(&output).contains("refusing to manage worktree outside"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn resume_is_exact_slot_and_fails_when_branch_is_attached_elsewhere() {
    let sandbox = Sandbox::new();
    sandbox.create_local_branch("feature");

    let first = sandbox.hephaestus(
        &sandbox.repo_root,
        &["resume", "TestOwner/testrepo/a", "feature"],
    );
    assert!(first.status.success(), "{}", stderr(&first));
    assert_eq!(stdout(&first), canonical_display(&sandbox.slot_a));
    assert_eq!(
        git_stdout(&sandbox.slot_a, ["rev-parse", "--abbrev-ref", "HEAD"]),
        "feature"
    );

    let second = sandbox.hephaestus(
        &sandbox.repo_root,
        &["resume", "TestOwner/testrepo/b", "feature"],
    );
    assert!(!second.status.success());
    assert!(
        stderr(&second).contains("requested branch is already attached in another worktree")
            && stderr(&second).contains(&canonical_display(&sandbox.slot_a)),
        "{}",
        stderr(&second)
    );
}

#[test]
fn release_detaches_clean_worktree_and_refuses_dirty_worktree() {
    let sandbox = Sandbox::new();
    sandbox.switch_slot_to_new_branch(&sandbox.slot_a, "feature");

    let released = sandbox.hephaestus(
        &sandbox.repo_root,
        &["release", sandbox.slot_a.to_str().unwrap()],
    );
    assert!(released.status.success(), "{}", stderr(&released));
    assert_eq!(stdout(&released), canonical_display(&sandbox.slot_a));
    assert_eq!(
        git_stdout(&sandbox.slot_a, ["rev-parse", "--abbrev-ref", "HEAD"]),
        "HEAD"
    );

    run_ok(&sandbox.slot_a, ["git", "switch", "feature"]);
    std::fs::write(sandbox.slot_a.join("README.md"), "dirty\n").expect("dirty file");
    let refusal = sandbox.hephaestus(
        &sandbox.repo_root,
        &["release", sandbox.slot_a.to_str().unwrap()],
    );
    assert!(!refusal.status.success());
    assert!(
        stderr(&refusal).contains("refusing to release dirty worktree"),
        "{}",
        stderr(&refusal)
    );
}

#[test]
fn dirty_detached_candidate_blocks_allocate() {
    let sandbox = Sandbox::new();
    for worktree in [&sandbox.slot_a, &sandbox.slot_b, &sandbox.scratch] {
        std::fs::write(worktree.join("README.md"), "dirty detached\n").expect("dirty file");
    }

    let output = sandbox.hephaestus(
        &sandbox.repo_root,
        &["allocate", "TestOwner/testrepo", "new-branch"],
    );
    assert!(!output.status.success());
    assert!(
        stderr(&output).contains("detached worktree is dirty and blocks allocation"),
        "{}",
        stderr(&output)
    );
}

#[test]
fn allocate_can_use_non_single_letter_child_worktree() {
    let sandbox = Sandbox::new();
    sandbox.switch_slot_to_new_branch(&sandbox.slot_a, "busy-a");
    sandbox.switch_slot_to_new_branch(&sandbox.slot_b, "busy-b");

    let output = sandbox.hephaestus(
        &sandbox.repo_root,
        &["allocate", "TestOwner/testrepo", "new-branch"],
    );
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), canonical_display(&sandbox.scratch));
    assert_eq!(
        git_stdout(&sandbox.scratch, ["rev-parse", "--abbrev-ref", "HEAD"]),
        "new-branch"
    );
}

#[test]
fn release_from_current_directory_uses_worktree_root() {
    let sandbox = Sandbox::new();
    sandbox.switch_slot_to_new_branch(&sandbox.slot_a, "feature");
    let nested = sandbox.slot_a.join("nested");
    std::fs::create_dir_all(&nested).expect("nested dir");

    let output = sandbox.hephaestus(&nested, &["release"]);
    assert!(output.status.success(), "{}", stderr(&output));
    assert_eq!(stdout(&output), canonical_display(&sandbox.slot_a));
}

fn configure_git_user(repo: &Path) {
    run_ok(repo, ["git", "config", "user.name", "Test User"]);
    run_ok(repo, ["git", "config", "user.email", "test@example.com"]);
}

fn run_ok<I, S>(current_dir: &Path, args: I)
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let parts: Vec<std::ffi::OsString> = args
        .into_iter()
        .map(|value| value.as_ref().to_os_string())
        .collect();
    let (program, rest) = parts.split_first().expect("program");
    let output = Command::new(program)
        .current_dir(current_dir)
        .env("GIT_AUTHOR_NAME", "Test User")
        .env("GIT_AUTHOR_EMAIL", "test@example.com")
        .env("GIT_COMMITTER_NAME", "Test User")
        .env("GIT_COMMITTER_EMAIL", "test@example.com")
        .args(rest)
        .output()
        .expect("run command");
    assert!(output.status.success(), "{}", stderr(&output));
}

fn git_stdout<I, S>(current_dir: &Path, args: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<std::ffi::OsStr>,
{
    let mut iter = args.into_iter();
    let output = Command::new("git")
        .current_dir(current_dir)
        .args(iter.by_ref())
        .output()
        .expect("run git");
    assert!(output.status.success(), "{}", stderr(&output));
    stdout(&output)
}

fn canonical_display(path: &Path) -> String {
    std::fs::canonicalize(path)
        .expect("canonical path")
        .display()
        .to_string()
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr)
        .trim_end_matches(['\r', '\n'])
        .to_string()
}
