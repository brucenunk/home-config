# TRAMP-RPC trial

The exported `emacs` Home Manager module installs TRAMP-RPC and its Magit
optimizations. Existing SSH paths and the `sshx` default are unchanged.

Use `C-x C-f` with `/rpc:user@host:/path/to/repository/` to trial the RPC
backend. Dired's directory listings and file operations use RPC automatically;
run `M-x magit-status` from that directory to exercise the Git optimizations.
Compare with `/sshx:user@host:/path/to/repository/` against the same repository.
RPC is also included in the configured envrc remote-method allowlist.

## Release-only servers

`pkgs/tramp-rpc-server.nix` owns the shared release version and fixed hashes
for x86_64 and aarch64 Linux GitHub release archives. `pkgs/tramp-rpc.nix`
applies the pinned upstream overlay locally for Lisp packaging and compatible
TRAMP/MessagePack dependencies. Its explicit `serverPackages` replaces
upstream's default Rust builds with those releases. Both are bundled even
when Emacs runs on macOS: the server runs on the remote Linux host. Consumers
do not need the global upstream Emacs/TRAMP-RPC overlay.

For unmanaged hosts, automatic deployment attempts to copy the matching bundled
server over SSH into the upstream default remote cache
(`~/.cache/emacs/tramp-rpc`). Emacs uses release
identities, does not prefer builds, and has no source directory configured.
That last setting disables source compilation even if a download fails and
Cargo is installed. No remote Rust toolchain is needed either.

**Known trial limitation:** the final Nix Emacs package exposes bundled servers
through symlinks. TRAMP 2.8.2's copying can recreate the local store symlink on
the remote instead of transferring executable bytes. A remote without that
store path cannot run it. The managed-host route below avoids copying; it does
not repair unmanaged-host deployment.

When updating, change the upstream input release and the package's version and
asset hashes together. The version assertion rejects mismatched Lisp and
server releases. Fetch release metadata/assets through `gh`, not `curl`.

## Nix-managed Linux servers

The public overlay adds `pkgs.tramp-rpc-server` on `x86_64-linux` and
`aarch64-linux` only. It adds no server on Darwin or other architectures and
does not modify the Emacs package set. A consumer can include it in a shared
package-set definition used by both Linux and Darwin:

```nix
overlays = [ inputs.home-config.overlays.tramp-rpc ];
```

On the managed Linux remote, either install the package directly:

```nix
home.packages = [ pkgs.tramp-rpc-server ];
```

or import the standalone Home Manager feature:

```nix
imports = [ inputs.home-config.modules.homeManager.tramp-rpc-server ];
```

Importing this feature installs the native release server without enabling or
installing Emacs. It prefers `pkgs.tramp-rpc-server` when available and otherwise
uses the same pinned release expression locally; the overlay is not required.
Unsupported platforms fail with a module assertion. These are alternative
installation routes, not two required steps.

On the Emacs client, import the existing `emacs` module and configure:

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

This generates `emacs/tramp-rpc-managed-servers.json`, which the shared remote
module reads during startup. Each entry registers connection-local
`tramp-rpc-deploy-never-deploy = t` and the explicit binary path for RPC only.
The host and optional user are exact matches, not regular expressions. Use
the host spelling from the TRAMP path, including `#port` if present. Omit `user`
(or set it to `null`) to match all users on that host. Duplicate selectors and
mixing all-users with user-specific entries for the same host are rejected.
The default list is empty: unrelated hosts retain automatic deployment and
the global TRAMP method remains `sshx`.

Use an absolute path that exists on the **remote**, preferably its stable
Home Manager profile path. Do not interpolate the Darwin client's
`${pkgs.tramp-rpc-server}` or its local store path. An absolute path avoids
reliance on noninteractive SSH's PATH. The module does not infer a remote
username, home directory, or profile location.

Upstream v0.15.0 passes the path directly to the remote shell without quoting.
The option therefore accepts only ASCII letters, digits and `_ . / + @ = -`
after the leading slash. Paths containing whitespace, quotes or shell
metacharacters are rejected; use a shell-safe installation/profile path.

In managed mode, a missing or incompatible remote executable is a connection
failure, not permission to download, build, or transfer a replacement. Activate
the remote Home Manager generation before connecting and coordinate client
and remote input revisions when changing releases. The shared version assertion
guards packaging within one revision, not agreement between deployed machines.

## Verification boundaries

`nix build .#checks.aarch64-darwin.tramp-rpc-server` (or the x86_64 Linux check)
unpacks both fixed-hash archives, evaluates native selection for both Linux
architectures, checks the guarded overlay and standalone module fallback/package
preference, and verifies that the module does not enable Emacs. Foreign-platform
evaluation is not a native build or execution test.

`nix build .#checks.aarch64-darwin.emacs-tramp-rpc` (or the x86_64 Linux check)
loads `my-emacs-remote-tests.el` alongside the real `my-emacs-remote.el` module
in isolated batch Emacs, checks bundled
Linux binary selection, retains `sshx`, and verifies Cargo cannot run after a
simulated download failure. It also loads the module-generated managed-server
configuration, checks exact host/user/method scoping, and exercises upstream's
connection branch with a mocked installed or missing executable. Binary
acquisition, download, build, and copying are forbidden in those tests. It does
not connect to a remote machine. A regression test resolves another target from
a managed remote buffer to guard against buffer-local policy leakage, and Nix
evaluation checks path validation.

A public Wampa build establishes composition/build evidence without activation.
The downstream consumer owns input updates, host composition, remote activation,
and client activation under its own deployment procedure. A restarted client
and a live connection using the installed remote executable are still needed to
prove runtime pickup. A live devbox trial remains necessary to verify remote
envrc, Dired, and Magit behavior and measure performance in Canva/k8s. Home
Manager build success is neither activation nor runtime-pickup evidence.

After building the staged Wampa configuration on x86_64 Linux, the adjacent
ERT suite can also be run with the actual Home Manager Emacs package:

```sh
scratch=$(mktemp -d)
emacs_package=$(nix eval --raw '.#homeConfigurations."james@wampa".config.programs.emacs.finalPackage')
mkdir -p "$scratch/home" "$scratch/config"
HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" \
  "$emacs_package/bin/emacs" --batch -q \
  -L "$PWD/config/emacs/my-emacs-modules" \
  -l my-emacs-remote-tests -f ert-run-tests-batch-and-exit
```

This loads only the remote-access module, not `init.el`, and neither contacts
the user's Emacs server nor connects to the devbox.