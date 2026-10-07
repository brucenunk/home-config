# TRAMP-RPC trial

The exported `emacs` Home Manager module installs TRAMP-RPC and its Magit
optimizations. Existing SSH paths and the `sshx` default are unchanged.

Use `C-x C-f` with `/rpc:user@host:/path/to/repository/` to trial the RPC
backend. Dired's directory listings and file operations use RPC automatically;
run `M-x magit-status` from that directory to exercise the Git optimizations.
Compare with `/sshx:user@host:/path/to/repository/` against the same repository.
RPC is also included in the configured envrc remote-method allowlist.

## Release-only servers

`pkgs/tramp-rpc.nix` applies the pinned upstream overlay locally for Lisp
packaging and compatible TRAMP/MessagePack dependencies. Its explicit
`serverPackages` replaces upstream's default Rust builds with hash-pinned
GitHub release archives for x86_64 and aarch64 Linux. Both are bundled even
when Emacs runs on macOS: the server runs on the remote Linux host.

Automatic deployment copies the matching bundled server over SSH into the
upstream default remote cache (`~/.cache/emacs/tramp-rpc`). Emacs uses release
identities, does not prefer builds, and has no source directory configured.
That last setting disables source compilation even if a download fails and
Cargo is installed. No remote Rust toolchain is needed either.

When updating, change the upstream input release and the package's version and
asset hashes together. The version assertion rejects mismatched Lisp and
server releases. Fetch release metadata/assets through `gh`, not `curl`.

## Verification boundaries

`nix build .#checks.aarch64-darwin.emacs-tramp-rpc` (or the x86_64 Linux check)
loads `my-emacs-remote-tests.el` alongside the real `my-emacs-remote.el` module
in isolated batch Emacs, checks bundled
Linux binary selection, retains `sshx`, and verifies Cargo cannot run after a
simulated download failure. It does not connect to a remote machine.

A live devbox trial remains necessary to verify deployment, remote envrc,
Dired, and Magit behavior and measure performance in Canva/k8s. Home Manager
build success is neither activation nor runtime-pickup evidence.

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