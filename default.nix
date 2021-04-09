{pkgs ? import <nixpkgs> {}} :

pkgs.mkShell {
  name = "nixos-up";
  buildInputs = with pkgs; [ ocaml jq ];
  shellHook = ''
    ocaml ${./nixos-up.ml}
    exit $?
  '';
}
