{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  name = "nixos-up";
  buildInputs = with pkgs; [ python3 python3Packages.psutil python3Packages.requests ];
  shellHook = "exec python3 ${./nixos-up.py}";
}
