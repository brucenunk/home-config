# Home configuration

When the user authorizes activation on Wampa, run this as `james` from the clean `main` worktree at the intended commit:

```sh
nix run --no-update-lock-file '.#homeConfigurations."james@wampa".activationPackage'
```

Successful activation does not prove that already-running applications have reloaded their configuration. Check runtime pickup separately when the change requires it.