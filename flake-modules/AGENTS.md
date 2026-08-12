# Dendritic Feature Modules

- Read `docs/dendritic-modules.md` before adding, moving, or splitting a module.
- Put ordinary capabilities in `features/<capability>.nix` with registration and
  implementation co-located.
- Recursive discovery registers features but never activates them.
- Keep host selection and machine composition in top-level `hosts/`.
- Prefer native typed options. Add a custom typed option only for a real
  interface between reusable mechanics and a host or downstream module.
- Keep public features independent of downstream private policy, endpoints,
  identities, repository inventory, and transport assumptions.
