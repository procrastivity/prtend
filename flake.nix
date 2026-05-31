{
  description = "prtend — Claude Code plugin to tend your PRs";
  inputs.nixpkgs.url     = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = nixpkgs.legacyPackages.${system}; in {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.bash
            pkgs.jq
            pkgs.gh
            pkgs.glab
            pkgs.git
            pkgs.shellcheck
            pkgs.pre-commit
          ];
        };
      });
}
