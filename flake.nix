{
    description = "json rpc 2.0 library over tcp";

    inputs = {
        nixpkgs.url = "https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz";
        flake-utils.url = "github:numtide/flake-utils";

        zig = {
            url = "github:mitchellh/zig-overlay";
            inputs = {
                nixpkgs.follows = "nixpkgs";
                flake-utils.follows = "flake-utils";
            };
        };
    };

    outputs = 
        {self, nixpkgs, flake-utils, zig, ...}:
            flake-utils.lib.eachDefaultSystem (
                system:
                let
                    pkgs = nixpkgs.legacyPackages.${system};
                in
                {
                    devShells.default = pkgs.mkShell {
                        packages = [ zig.packages.${system}.master ];
                        shellHook = ''
                            $SHELL
                        '';
                    };
                }
            );
}
