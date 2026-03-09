{
  description = "Grasp — a Lisp that grasps the G-machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      hsPkgs = pkgs.haskell.packages.ghc98;

      mkdocsPython = pkgs.python3.withPackages (ps: [
        ps.mkdocs
        ps.mkdocs-material
        ps.pymdown-extensions
      ]);
    in
    {
      devShells.${system}.default = hsPkgs.shellFor {
        packages = p: [ ];
        nativeBuildInputs = [
          hsPkgs.cabal-install
          pkgs.overmind
          pkgs.tmux
          pkgs.poppler-utils
        ];
      };

      apps.${system}.mkdoc = {
        type = "app";
        program = toString (pkgs.writeShellScript "mkdoc" ''
          cd "$(git rev-parse --show-toplevel)"
          ${mkdocsPython}/bin/mkdocs build
        '');
      };
    };
}
