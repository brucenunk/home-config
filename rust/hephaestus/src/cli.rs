const USAGE: &str = "usage:\n  hephaestus allocate <owner/repo> [branch] [--base <ref>] [--fetch]\n  hephaestus resume <owner/repo>/<worktree> <branch>\n  hephaestus release [worktree]\n";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CommandKind {
    Allocate(AllocateArgs),
    Resume(ResumeArgs),
    Release(ReleaseArgs),
    Help,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AllocateArgs {
    pub(crate) slug: String,
    pub(crate) branch: Option<String>,
    pub(crate) base_ref: Option<String>,
    pub(crate) fetch: bool,
    pub(crate) branch_supplied: bool,
    pub(crate) help_requested: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResumeArgs {
    pub(crate) worktree_ref: String,
    pub(crate) branch: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ReleaseArgs {
    pub(crate) worktree: Option<String>,
}

pub(crate) fn usage_text() -> &'static str {
    USAGE
}

pub(crate) fn parse_command(argv: &[String]) -> Result<CommandKind, String> {
    let Some(cmd) = argv.first().map(String::as_str) else {
        return Err(usage_text().trim_end().to_string());
    };

    match cmd {
        "allocate" => parse_allocate(&argv[1..]).map(CommandKind::Allocate),
        "resume" => parse_resume(&argv[1..]).map(CommandKind::Resume),
        "release" => parse_release(&argv[1..]).map(CommandKind::Release),
        "--help" | "-h" | "help" => Ok(CommandKind::Help),
        other => Err(format!("unknown command: {other}")),
    }
}

fn parse_allocate(args: &[String]) -> Result<AllocateArgs, String> {
    if args.is_empty() {
        return Err(usage_text().trim_end().to_string());
    }

    let slug = args[0].clone();
    let mut index = 1usize;
    let mut branch = None;
    let mut branch_supplied = false;

    if let Some(value) = args.get(index)
        && !value.starts_with("--")
    {
        branch = Some(value.clone());
        branch_supplied = true;
        index += 1;
    }

    let mut base_ref = None;
    let mut fetch = false;
    let mut help_requested = false;

    while let Some(arg) = args.get(index) {
        match arg.as_str() {
            "--base" => {
                let Some(value) = args.get(index + 1) else {
                    return Err("missing value for --base".to_string());
                };
                base_ref = Some(value.clone());
                index += 2;
            }
            "--fetch" => {
                fetch = true;
                index += 1;
            }
            "--help" | "-h" => {
                help_requested = true;
                break;
            }
            other => return Err(format!("unknown option: {other}")),
        }
    }

    Ok(AllocateArgs {
        slug,
        branch,
        base_ref,
        fetch,
        branch_supplied,
        help_requested,
    })
}

fn parse_resume(args: &[String]) -> Result<ResumeArgs, String> {
    if args.len() != 2 {
        return Err(usage_text().trim_end().to_string());
    }

    Ok(ResumeArgs {
        worktree_ref: args[0].clone(),
        branch: args[1].clone(),
    })
}

fn parse_release(args: &[String]) -> Result<ReleaseArgs, String> {
    if args.len() > 1 {
        return Err(usage_text().trim_end().to_string());
    }

    Ok(ReleaseArgs {
        worktree: args.first().cloned(),
    })
}

#[cfg(test)]
mod tests {
    use super::{AllocateArgs, parse_allocate};

    #[test]
    fn allocate_help_short_circuits_trailing_args() {
        let parsed = parse_allocate(&[
            "TestOwner/testrepo".to_string(),
            "--help".to_string(),
            "--bogus".to_string(),
        ])
        .expect("help parses");

        assert_eq!(
            parsed,
            AllocateArgs {
                slug: "TestOwner/testrepo".to_string(),
                branch: None,
                base_ref: None,
                fetch: false,
                branch_supplied: false,
                help_requested: true,
            }
        );
    }
}
