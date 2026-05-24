# Nixinate 🕶️

Nixinate is a tool that generates a deployment application-script for each
`nixosConfiguration` you already have in your flake, which can be ran via `nix
run`, thanks to the `apps` attribute of the [flake schema](https://zero-to-nix.com/concepts/flakes).

## Usage
To use `nixinate` in your own deployment, you will need to:

1. Add nixinate as an input;
2. Use the `lib.genDeploy` function to generate your deployment commands and add them to apps.
3. Add and configure `_module.args.nixinate` to the `nixosConfigurations` you want to deploy

Below is a documented example:

```nix
{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0"; # the nixpkgs source see below
    nixinate = { url = "github:DarthPJB/nixinate"; inputs.nixpkgs.follows = "nixpkgs"; } # import nixinate, using your own nixpkgs and nix-versions (useful for hermetic).
  };

  outputs = { self, nixpkgs, nixinate }: {
    apps = nixinate.lib.genDeploy.x86_64-linux self;  # the lib lib.genDeploy function provides the 'apps' attribute set, you can always amend this onto your own apps
    nixosConfigurations = {
      myMachine = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";  # this will work for other systems too ;)
        modules = [
          ./my-configuration.nix
          {
            _module.args.nixinate = {
              host = "staging.example.com"; # You can use an IP address here, it's just SSH ;)
              port = "2122"; # This is the SSH port, which is normally 22
              sshUser = "matthew"; # The username on the remote that recives and deploys.
              buildOn = "local"; # valid args are "local" or "remote"; remote is good for big machines, local is better for small ones.
              substituteOnTarget = true; # if buildOn is "local" then it will substitute on the target, "-s"
              hermetic = false; # if true this forces the rebuild (if done locally) to be enacted with the same Nix-version on the remote. (good for legacy upgrades)
            };
          }
          # ... other configuration ...
        ];
      };
    };
  };
}
```

Each `nixosConfiguration` you have configured will have a deployment script created in your flake.

## deployment
To deploy the machine, use `nix run .#myMachine`, you can easily see what machines are in your flake with `nix flake show`.
** DEPLOYING ONLY WITH NIX RUN WILL NOT PERSIST PAST A REBOOT **
often, we might make a deployment that despite our best testing causes the machine to be in a broken state; if the machine is remote this 
may be hard to rectify (such as using KVM or console). To ensure best practice, the default behaviour of this script is to use
`nixos-rebuild test`; you can read more about this in the [various documentation](https://wiki.nixos.org/wiki/Nixos-rebuild)

The long and short of this is that a deployment made will **not be added to the bootloader** meaning in the event you break SSHD or alike
you can simply reset the system to restore the previous configuration.

should you want to `nixos-rebuild switch` the remote system, use the following command.
`nix run .#myMachine -- switch`

as you might be able to tell, you can pass any nixos-rebuild compatible argument in the invocation.

### Using other app outputs with nixinate.

You might need to use similar library-app generators alongside nixinate; or simply want to add an output, 
this is easily accomplished by simply "amending" those to your apps output, as in the example below.

```nix
{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    secrix.url = "github:Platonic-Systems/secrix";
    nixinate.url = "github:DarthPJB/nixinate";
  };

  outputs = { self, nixpkgs, nixinate, secrix }: {
    apps.x86_64-linux = 
    { # Here we use secrix to generate a different app.
      secrix = secrix.secrix self; 
    } // (nixinate.lib.genDeploy.x86_64-linux self);
    
    nixosConfigurations = {
      myMachine = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          secrix.nixosModules.default
          ./my-configuration.nix
          {
            _module.args.nixinate = {
              host = "productionHost.example.com"; # You can use an IP address here, it's just SSH ;)
              sshUser = "C0mmander"; # The username on the remote that recives and deploys.
              buildOn = "remote"; # valid args are "local" or "remote"; remote is good for big machines, local is better for small ones.
              substituteOnTarget = true; # if buildOn is "local" then it will substitute on the target, "-s"
            };
          }
          # ... other configuration ...
        ];
      };
    };
  };
}
```

#### Example Usage and output Run

```text
[root@myMachine:/etc/nixos]# nix run .#apps.myMachine
🚀 Deploying nixosConfigurations.myMachine from /nix/store/279p8aaclmng8kc3mdmrmi6q3n76r1i7-source
👤 SSH User: matthew
🌐 SSH Host: itchy.scratchy.com
🚀 Sending flake to myMachine via nix copy:
(matthew@itchy.scratchy.com) Password:
🤞 Activating configuration on myMachine via ssh:
(matthew@itchy.scratchy.com) Password:
[sudo] password for matthew:
building the system configuration...
activating the configuration...
setting up /etc...
reloading user units for matthew...
setting up tmpfiles
Connection to itchy.scratchy.com closed.
```

# Available arguments via `_module.args.nixinate`

- `host` *`string`*

   A string representing the hostname or IP address of a machine to connect to
   via ssh.

- `sshUser` *`string`*

   A string representing the username a machine to connect to via ssh.

- `buildOn` *`"remote"`* or *`"local"`*

  - `"remote"`

    Push the flake to the remote, build and activate entirely remotely,
    returning logs via SSH.

  - `"local"`

    Build the system closure locally, copy to the remote and activate.

- `hermetic` *`bool`*

  Whether to copy Nix to the remote for usage when building and activating,
  instead of using the Nix which is already installed on the remote.

- `substituteOnTarget` *`bool`*

  Whether to fetch closures and paths from the remote, even when building
  locally. This makes sense in most cases, because the remote will have already
  built a lot of the paths from the previous deployment. However, if the remote
  has a slow upload bandwidth, this would not be a good idea to enable.

# Project Principles

* No Premature Optimization: Make it work, then optimize it later if the
  optimization is taking a lot of time to figure out now.
* KISS: Keep it simple, stupid. Unnecesary complexity should be avoided.

# Hermetic Deployments and the Future of Nixinate

## What is Hermetic Mode?

When `hermetic = true` is set in your nixinate configuration, nixinate copies a
specific version of Nix itself to the remote host before running `nixos-rebuild`.
This means the remote system uses the **same Nix version as the deployer**, not
whatever version happens to be installed on the target.

The hermetic path works as follows:

1. The flake source is copied to the remote via `nix copy`.
2. The `nixos-rebuild` and `sem` (GNU Parallel) derivations are copied to the
   remote via `nix copy --derivation`.
3. An SSH session executes `nixos-rebuild` on the remote using the copied Nix
   binary, with `--flake` pointing at the copied flake source.

This ensures the remote never evaluates or builds with an unexpected Nix version.

## Why Hermetic Matters

The original purpose of hermetic mode was to enable **deployment onto systems
that are otherwise past their deployment lifetime**. Consider a NixOS 21.11
machine that needs to be upgraded to 25.11: the remote's installed Nix may be
too old to evaluate the new flake, or may lack support for features the new
configuration depends on.

Hermetic mode solves this by decoupling the deploy target's Nix version from its
installed Nix version. The deployer brings its own Nix, ensuring consistent
evaluation regardless of what the remote already has.

## Current Status

Hermetic mode is currently **functional but secondary** to the local-build path.
The local-build path (which includes a visible pre-copy step as of this version)
is the recommended default because it provides clear progress output and is
simpler to debug.

The hermetic path does not yet include the same pre-copy visibility
enhancements. Contributions to bring the hermetic path to parity are welcome.

## Make Nixinate Great Again (MNGA)

The long-term goal is to restore hermetic mode as a first-class deployment
strategy with the following properties:

* **Fully self-contained transfers**: The deployer copies everything needed
  (Nix, nixos-rebuild, parallel, and the system closure) to the remote in a
  single visible pipeline, with progress output at every stage.
* **Legacy system support**: Deploy cleanly onto NixOS systems running versions
  as old as 21.11, or even non-NixOS systems with a minimal Nix installation.
* **Deterministic evaluation**: The remote always evaluates with the deployer's
  Nix version, eliminating environment-specific build differences.
* **Resilient transfers**: If a transfer is interrupted, resume from where it
  left off rather than restarting from scratch.

These goals align with nixinate's core principle: make deployment simple,
reliable, and observable. Patches and RFCs toward this vision are welcome.
