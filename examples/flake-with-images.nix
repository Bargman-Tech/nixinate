{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nixinate = {
      url = "github:DarthPJB/nixinate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixinate, disko }: {
    # Deploy scripts
    apps = nixinate.lib.genDeploy.x86_64-linux self;

    # Image packages
    packages = nixinate.lib.genImages.x86_64-linux self;

    nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        disko.nixosModules.disko
        nixinate.nixosModules.image-gen
        {
          _module.args.nixinate = {
            host = "10.0.0.1";
            sshUser = "deploy";
            images = {
              raw = {
                enable = true;
                imageSize = "20G";
                espSize = "1024M";
                swapSize = "8G";
              };
              installer.enable = true;
            };
          };
        }
      ];
    };
  };
}
