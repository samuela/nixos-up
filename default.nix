{pkgs ? import <nixpkgs> {}} :

pkgs.mkShell {
  name = "nixos-up";
  buildInputs = with pkgs; [ ocaml jq ];
  shellHook = "exec ocaml ${./nixos-up.ml}";
}
