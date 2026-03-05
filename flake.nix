{
  description = "ghc-lisp — a dynamic Lisp on GHC's runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hsPkgs = pkgs.haskell.packages.ghc98;
    in
    {
      devShells.${system}.default = hsPkgs.shellFor {
        packages = p: [ ];
        nativeBuildInputs = [
          hsPkgs.cabal-install
          pkgs.overmind
          pkgs.tmux
        ];
      };
    };
}
