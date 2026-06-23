{
  description = "Nixinate your systems";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = { self, nixpkgs, ... }:
    let
      # some basic carte-blance tooling to handle valid archtectures.
      version = builtins.substring 0 8 self.lastModifiedDate;
      # this is still better than flake-utils, long game wins.
      forSystems = systems: f:
        nixpkgs.lib.genAttrs systems
        (system: f system nixpkgs.legacyPackages.${system});
      #  If you need to shim in your alien-nixpkgs-overlays override flakeExposed in the input nixpkgs follows packageset; not here. 
      forAllSystems = forSystems nixpkgs.lib.systems.flakeExposed;
      nixpkgsFor = forAllSystems (system: pkgs: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; });
    in rec
    {
      lib.genDeploy = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateApps);
      overlays.default = final: prev:
        let
          hasNg = final.lib.hasAttr "nixos-rebuild-ng" prev;
          rebuildCandidate = if hasNg then prev.nixos-rebuild-ng else prev.nixos-rebuild;
        in {
        nixinate = {
          nix = prev.pkgs.writeShellScriptBin "nix"
            ''${final.nixVersions.latest}/bin/nix --experimental-features "nix-command flakes" "$@"''; #TODO: appropriately allow passing of nix-version per-machine
          nixos-rebuild = rebuildCandidate.override { inherit (final) nix; };
        };
        generateApps = flake:
          let
            machines = builtins.attrNames flake.nixosConfigurations;
            validMachines = final.lib.remove "" (final.lib.forEach machines (x: final.lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}" ));
            mkDeployScript = { machine }: let
              inherit (final.lib) getExe getExe' optionalString concatStringsSep escapeShellArg elem;
              nix = "${getExe final.nix}";
              nixos-rebuild = "${getExe final.nixos-rebuild}";
              openssh = "${getExe final.openssh} ${sshVerbosity} -p ${port} -t ${safe_target_host}";
              lolcat_cmd = "${getExe final.lolcat} -p 3 -F 0.02";
              figlet_cmd = "${getExe final.figlet}";
              sem = "${getExe' final.parallel "sem"} --will-cite --line-buffer";
              semCleanup = "${getExe' final.parallel "sem"} --will-cite";
              stdbuf = "${getExe' final.coreutils "stdbuf"}";
              safe_flake = escapeShellArg flake;
              safe_parallel = escapeShellArg "${getExe' final.parallel "sem"}";
              buildersOption = "--option builders ''";
              parameters = flake.nixosConfigurations.${machine}._module.args.nixinate;
              targetSystem = flake.nixosConfigurations.${machine}.config.nixpkgs.hostPlatform.system;
              deployerSystem = final.system;
              isCrossArch = deployerSystem != targetSystem;
              # Normalize hermetic config: bool (backward compat) or set (tool selection)
              rawHermetic = parameters.hermetic or true;
              hermeticConfig =
                if isCrossArch then { enable = false; }
                else if builtins.isBool rawHermetic then { enable = rawHermetic; }
                else if builtins.isAttrs rawHermetic then rawHermetic // { enable = rawHermetic.enable or true; }
                else builtins.abort "nixinate.hermetic must be a bool or a set with optional enable, nixos-rebuild, and nix fields";
              hermeticEnabled = hermeticConfig.enable;
              # User-selected hermetic payload packages (fall back to deployer's if not specified)
              hermeticNixosRebuild = if hermeticConfig ? nixos-rebuild then hermeticConfig.nixos-rebuild else final.nixos-rebuild;
              hermeticNix = if hermeticConfig ? nix then hermeticConfig.nix else final.nix;
              safe_nixos_rebuild = escapeShellArg "${getExe hermeticNixosRebuild}";
              safe_nix = escapeShellArg "${getExe hermeticNix}";
              user = if (parameters ? sshUser && parameters.sshUser != null) then parameters.sshUser else (builtins.abort "sshUser must be set in _module.args.nixinate");
              host = if parameters ? host then parameters.host else builtins.abort "host must be set in _module.args.nixinate";
              isDebug = parameters ? debug && parameters.debug;
              debug = if isDebug then "set -x; export DEBUG=true;" else "";
              verboseFlag = if isDebug then "--verbose" else "";
              sshVerbosity = if isDebug then "-vvv" else "";
              where = if parameters ? buildOn then (if elem parameters.buildOn ["local" "remote"] then parameters.buildOn else builtins.abort "_module.args.nixinate.buildOn must be 'local' or 'remote'") else "local";
              nixOptionsList = if parameters ? nixOptions then (if builtins.isList parameters.nixOptions then (if builtins.all builtins.isString parameters.nixOptions then parameters.nixOptions else builtins.abort "_module.args.nixinate.nixOptions must be a list of strings") else builtins.abort "_module.args.nixinate.nixOptions must be a list") else [];
              port = toString (parameters.port or 22);
              target = "${flake}#${machine}";
              target_host = "${user}@${host}";
              ssh_uri = "ssh://${target_host}";
              safe_target = escapeShellArg target;
              safe_target_host = escapeShellArg target_host;
              safe_ssh_uri = escapeShellArg ssh_uri;
              system_toplevel = escapeShellArg "${flake}#nixosConfigurations.${machine}.config.system.build.toplevel";
               logFile = "/tmp/deploy-${machine}.log";
               ssh_options = "NIX_SSHOPTS=\"${optionalString isDebug "${sshVerbosity} "} -p ${port}\"";
              hermeticOpensshCmd = ''sudo ${safe_nix} store realise ${safe_nixos_rebuild} ${safe_parallel} && sudo ${stdbuf} -oL ${sem} --id "nixinate-${machine}" --semaphore-timeout 60 --fg "${safe_nixos_rebuild} ${nixOptions} $sw --flake ${safe_target}"'';
              nonHermeticOpensshCmd = ''sudo ${sem} --id "nixinate-${machine}" --semaphore-timeout 60 --fg "${safe_nixos_rebuild} ${nixOptions} $sw --flake ${safe_target}"'';
              remote = if where == "remote" then true else if where == "local" then false else builtins.abort "_module.args.nixinate.buildOn is not either 'local' or 'remote'";
              substituteOnTarget = parameters.substituteOnTarget or false;
              nixOptions = concatStringsSep " " nixOptionsList;
               header = ''
                   set -e
                   sw=''${1:-test}
                   echo "Deploying nixosConfigurations.${machine} from ${flake}" | ${lolcat_cmd}
                   echo "SSH Target: ${user}@${host}" | ${lolcat_cmd}
                   echo ${if port != 22 then "SSH Port: ${port}" else ""} | ${lolcat_cmd}
                   ${optionalString isCrossArch ''echo "Cross-architecture deployment detected (deployer: ${deployerSystem}, target: ${targetSystem}), disabling hermetic activation due to cross-arch policy." | ${lolcat_cmd}''}
                   echo "Rebuild Command:"
                    echo "${where} build : mode $sw  ${if hermeticEnabled then "hermetic active" else ""}" | ${figlet_cmd} | ${lolcat_cmd}
                 '';

            remoteCopy = if remote then ''
               echo "=== [COPY START] $(date) Sending flake to ${machine} via nix copy ==="
               ( ${debug} ${ssh_options} ${nix} ${verboseFlag} ${nixOptions} copy ${safe_flake} --to ${safe_ssh_uri} )
               echo "=== [COPY END]   $(date) ==="
            '' else "";

           hermeticActivation = if hermeticEnabled then ''
              echo "=== [CLOSE COPY START] $(date) Hermetic closure copy start ==="
                ( ${debug} ${ssh_options} ${nix} ${verboseFlag} ${nixOptions} copy --derivation ${safe_nixos_rebuild} --derivation ${safe_parallel} --derivation ${safe_nix} --to ${safe_ssh_uri} )
              echo "=== [CLOSE COPY END]   $(date) ==="
              echo "=== [ACTIVATION START] $(date) Activating configuration hermetically on ${machine} via ssh ==="
                ( ${debug} ${openssh} ${hermeticOpensshCmd} )
              echo "=== [ACTIVATION END]   $(date) ==="
           '' else ''
              echo "Activating configuration non-hermetically on ${machine} via ssh:"
                ( ${openssh} ${nonHermeticOpensshCmd} )
            '';

              activation = if remote then remoteCopy + hermeticActivation else ''
                echo "=== [PRE-COPY START] $(date) Pre-copying system closure to ${machine} ==="
                echo "Building and copying system closure to remote store (visible progress):"
                 ( ${debug} ${ssh_options} ${nix} ${verboseFlag} ${nixOptions} copy "$(${nix} build --print-out-paths --no-link ${system_toplevel})" --to ${safe_ssh_uri} )
                echo "=== [PRE-COPY END]   $(date) ==="
                echo "=== [DEPLOY START] $(date) Activating ${machine} via nixos-rebuild ==="
                echo "Running nixos-rebuild $sw on remote (closure already transferred):"
                 ( ${debug} ${ssh_options} ${stdbuf} -oL ${safe_nixos_rebuild} ${nixOptions} "$sw" --flake ${safe_target} --target-host ${safe_target_host} --sudo ${optionalString substituteOnTarget "-s"} )
                echo "=== [DEPLOY END]   $(date) ==="
              '';
            in 
	    	final.writeShellApplication 
	    	{
	    		name = "deploy-${machine}.sh"; 
	    		meta.description = "nixinate deploy script for ${machine}";
          text = ''
main() {
  # Override TMPDIR to keep SSH control socket paths under the 108-byte
  # Unix domain socket limit. nixos-rebuild-ng creates its temp directory
  # at import time based on TMPDIR, and nested nix-shell temp paths
  # produce socket paths that exceed the limit.
  export TMPDIR="/tmp"
  # --- Deployment lock (atomic mkdir) ---
  # TODO(nixinate): Replace with sem --semaphore when GNU Parallel
  # supports a hold-without-command semaphore mode. The --fg path
  # calls setpgrp(0,0) which puts nixos-rebuild/ssh in a background
  # process group, causing SIGTTIN on ssh -t terminal access.
  _lockdir="/tmp/nixinate-${machine}.lock"
  _lock_timeout=60
  _lock_waited=0
  while ! mkdir "$_lockdir" 2>/dev/null; do
    if [ -f "$_lockdir/pid" ]; then
      _lock_pid=$(cat "$_lockdir/pid" 2>/dev/null)
      if [ -n "$_lock_pid" ] && ! kill -0 "$_lock_pid" 2>/dev/null; then
        echo "Removing stale deployment lock (PID $_lock_pid died)" >&2
        rm -rf "$_lockdir" 2>/dev/null
        continue
      fi
    fi
    sleep 0.5
    _lock_waited=$((_lock_waited + 1))
    if [ $_lock_waited -ge $((_lock_timeout * 2)) ]; then
      echo "WARNING: Could not acquire deployment lock after $_lock_timeout s, forcing through" >&2
      rm -rf "$_lockdir" 2>/dev/null
      mkdir "$_lockdir" 2>/dev/null || true
      break
    fi
  done
  echo $$ > "$_lockdir/pid"
  trap 'rm -rf "$_lockdir" 2>/dev/null' EXIT INT TERM HUP
'' + header + activation + ''
}
main "$@" 2>&1 | tee ${logFile}
'';
          runtimeInputs = with final; [ figlet lolcat coreutils ];
	     	};
          in
          nixpkgs.lib.genAttrs
            validMachines (x:
            {
                type = "app";
                meta = {
                  description = "Deployment Application for $x";
                };
                program = nixpkgs.lib.getExe (mkDeployScript { machine = x; });
              });
        };
    };
}
