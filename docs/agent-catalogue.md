# Machine catalogue

Configure `brucenunk.homeManager.machines` and import `agent-catalogue` wherever
Emacs session launching is used. A non-empty inventory needs exactly one
`isLocal = true` record. Git maintenance uses only that record's repositories;
it is not a launcher selection preference.

```nix
brucenunk.homeManager.machines = {
  laptop = {
    isLocal = true;
    repositories."example/project" = {
      path = "/Users/example/work/example/project/main";
      defaultBranch = "main";
    };
  };
  builder = {
    directory = "/rpc:builder.example:~/work/";
    repositories."example/project" = {
      path = "/srv/git/project.git";
      defaultBranch = "master";
    };
  };
};
```

Repository paths are absolute machine-local paths accepted by `git -C`, not
TRAMP paths. Ordinary, linked and bare repositories are supported. Remote
records require an explicit browsing `directory`; local defaults to `~/work/`.
Connections are relative to the machine running Emacs, so each host needs its
own local/remote composition. Private connection details belong downstream.

Optional model inventories should share their Nix value with Pi's `models`.
The local record inherits Pi's provider/model default when configured; remote
records do not. Explicit `defaultModel = null` selects the first model.
Launchers leave Pi defaults alone unless a task overrides them.

## Reload after activation

The module generates trusted executable configuration at
`~/.config/emacs/agent-catalogue.el`, setting `my/agent-machines`. After
activating inventory changes, run **`M-x my/agent-catalogue-reload`** or restart
Emacs. Launchers use the loaded inventory, not the file on disk. Reload clears
old choices first; a missing file cannot silently retain them.

A missing catalogue does not prevent Emacs startup, but launching reports it.
Syntax/evaluation errors are ordinary load errors. Loading inventory does not
probe hosts or establish readiness. See [agent-session.md](agent-session.md)
for launch commands and [activation.md](activation.md) for deployment.
