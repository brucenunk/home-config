# Home Manager configuration

See `README.md` for the repository layout.

- Put reusable features in `flake-modules/features/`, with implementation and
  export together. Discovery makes a feature available; it does not enable it.
  Select features and set Wampa-specific values in `hosts/wampa.nix`.
- Edit managed sources, not generated or deployed files. For Emacs, edit
  `config/emacs/my-emacs.org` rather than its tangled output.
- To check the full Wampa configuration on x86_64 Linux without activating it:

  ```sh
  nix build --no-link --no-update-lock-file '.#homeConfigurations."james@wampa".activationPackage'
  ```

  Use targeted checks where appropriate. Activate only when explicitly requested.