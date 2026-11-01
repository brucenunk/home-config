# Remote files with TRAMP-RPC

Use `C-x C-f` with `/rpc:user@host:/path/to/repository/`. Dired and Magit then
use that connection. RPC is the shared default; `/-:host:/path/` selects it
with TRAMP's default-method syntax. Plain `/host:/path/` is not valid in the
configured syntax. Explicit `/sshx:user@host:/path/` is a manual alternative,
not automatic fallback.

Remote envrc importing is disabled: the pinned envrc exporter does not use
remote file handling. RPC's independent direnv loader is also disabled so it
does not change remote Git/environment selection. RPC's optional Magit handlers
are disabled; normal Magit remains available.

## Managed Linux hosts

Install the pinned server on the remote, either directly as
`pkgs.tramp-rpc-server` using `inputs.home-config.overlays.tramp-rpc`, or with
the standalone module:

```nix
imports = [ inputs.home-config.modules.homeManager.tramp-rpc-server ];
```

The module supports x86_64 and aarch64 Linux and does not install Emacs.
On the Emacs client:

```nix
{
  imports = [ inputs.home-config.modules.homeManager.emacs ];

  brucenunk.homeManager.emacs.trampRpc.managedServers = [
    {
      host = "remote.example";
      remoteBinaryPath = "/home/remote-user/.nix-profile/bin/tramp-rpc-server";
      user = "remote-user";
    }
  ];
}
```

Host and optional user are exact matches. Use the TRAMP host spelling, including
`#port` if present. Omit `user` to match all users; do not mix that with specific
users for the same host. The binary path must exist on the **remote**: do not
interpolate the client's Nix store path. Prefer a stable profile path rather
than relying on noninteractive SSH's PATH.

Upstream passes this path unquoted to a shell, so only ASCII letters, digits
and `_ . / + @ = -` are allowed after the leading slash. Whitespace and shell
metacharacters are rejected.

Managed connections never acquire or copy a replacement binary. Activate the
remote generation before connecting; coordinate client/server input revisions
when updating. Missing or incompatible executables are connection failures.
Restart Emacs after client activation to load the generated connection settings.

## Unmanaged hosts and updates

For other hosts, Emacs attempts to copy a bundled Linux release server into
`~/.cache/emacs/tramp-rpc`. No remote Rust toolchain is required; compilation
is disabled even after a download failure.

**Known limitation:** TRAMP can copy the bundled server's Nix store symlink
rather than executable bytes. Hosts without that store path cannot run it.
Use the managed-host route above; it avoids copying but does not fix automatic
deployment to unmanaged hosts.

When updating, change the upstream input and release version/asset hashes in
`pkgs/tramp-rpc-server.nix` together. The version assertion checks packaging
within one revision, not agreement between deployed machines. Build success
does not establish a live connection or remote performance.
