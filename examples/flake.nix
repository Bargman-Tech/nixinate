{
  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0";
    nixinate = {
      url = "github:Bargman-Tech/nixinate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixinate }: {
    apps = nixinate.lib.genDeploy.x86_64-linux self;

    nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        {
          _module.args.nixinate = {
            host = "10.0.0.1";
            sshUser = "deploy";
          };
        }
      ];
    };
  };
}
