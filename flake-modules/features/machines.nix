{ config, lib, ... }:

let
  gitData = config.flake.lib.git;
  piData = config.flake.lib.pi;
  localName = machines: lib.attrNames (lib.filterAttrs (_: machine: machine.isLocal) machines);
  projectModels =
    machine:
    map (
      model:
      model
      // {
        defaultThinking =
          if builtins.elem "medium" model.thinkingLevels then
            "medium"
          else if builtins.elem "off" model.thinkingLevels then
            "off"
          else
            "";
      }
    ) (piData.projectModels machine.models);
  defaultModel =
    machine:
    let
      models = projectModels machine;
    in
    if machine.defaultModel != null then
      machine.defaultModel
    else if models != [ ] then
      (builtins.head models).name
    else
      "";
  homeManagerModule =
    {
      config,
      lib,
      options,
      ...
    }:
    let
      machines = config.brucenunk.homeManager.machines;
      defaultsFile =
        if options.brucenunk.homeManager ? pi then
          config.brucenunk.homeManager.pi.settingsDefaults
        else
          null;
      defaults = if defaultsFile == null then { } else builtins.fromJSON (builtins.readFile defaultsFile);
      piDefault =
        if
          builtins.isAttrs defaults
          && builtins.isString (defaults.defaultProvider or null)
          && builtins.isString (defaults.defaultModel or null)
          && defaults.defaultProvider != ""
          && defaults.defaultModel != ""
        then
          "${defaults.defaultProvider}/${defaults.defaultModel}"
        else
          null;
    in
    {
      # All inventory consumers share these declarations, including when the
      # data-only module is also imported explicitly by a host.
      key = "brucenunk.homeManager.machines";
      options.brucenunk.homeManager.machines = lib.mkOption {
        default = { };
        description = "Shared machine inventory for Git, Emacs agents, and transitional Herdsman configuration.";
        type = lib.types.attrsOf (
          lib.types.submodule (
            { config, ... }: {
              options = {
                defaultModel = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = if config.isLocal then piDefault else null;
                  description = "Exact provider/model default. The local record inherits Pi's Nix settings default; null selects the first catalogue model.";
                };
                directory = lib.mkOption {
                  type = lib.types.addCheck (lib.types.strMatching "(/|~/).*") (
                    value: builtins.match "[^[:cntrl:]]+" value != null
                  );
                  default = if config.isLocal then "~/work/" else "";
                  description = "Emacs browsing directory, including a TRAMP connection for remote machines. Set remote directories explicitly, preferably with RPC.";
                };
                isLocal = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "This record describes the host being configured. Used by local consumers, never a capture selection default.";
                };
                models = piData.modelsOption;
                repositories = gitData.repositoryOptions.repositories;
              };
            }
          )
        );
      };
      config.assertions = [
        {
          assertion = machines == { } || builtins.length (localName machines) == 1;
          message = "A non-empty machine inventory must have exactly one isLocal record.";
        }
        {
          assertion =
            !(machines ? local)
            && lib.all (
              name:
              name != "" && builtins.stringLength name <= 4096 && builtins.match "[^[:cntrl:]]+" name != null
            ) (lib.attrNames machines);
          message = "Machine names must be non-empty, at most 4096 bytes, contain no controls, and not use the reserved name local.";
        }
      ]
      ++ lib.mapAttrsToList (name: machine: {
        assertion =
          machine.defaultModel == null
          || builtins.elem machine.defaultModel (map (model: model.name) (projectModels machine));
        message = "Machine defaultModel for ${name} must be a model in that machine's catalogue.";
      }) machines
      ++ lib.mapAttrsToList (
        name: machine:
        let
          references = map (model: model.name) (projectModels machine);
          providers = lib.unique (map (reference: builtins.head (lib.splitString "/" reference)) references);
        in
        {
          assertion =
            lib.all (
              reference:
              builtins.stringLength reference <= 4096
              && builtins.match "[^/[:space:][:cntrl:]]+/[^[:space:][:cntrl:]]+" reference != null
            ) references
            && builtins.length references == builtins.length (lib.unique (map lib.toLower references))
            && builtins.length providers == builtins.length (lib.unique (map lib.toLower providers));
          message = "Machine ${name} model references must be bounded provider/model hints without whitespace or controls; Pi requires case-insensitive uniqueness and consistent provider spelling.";
        }
      ) machines;
    };
in
{
  flake.lib.machines = { inherit localName projectModels defaultModel; };
  flake.modules.homeManager.machines = homeManagerModule;
}
