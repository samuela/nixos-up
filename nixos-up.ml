#!/usr/bin/env nix-shell
(*
curl, mkfs.*, nixos-generate-config, nixos-install already present in the live
ISO environment.
#!nix-shell -i ocaml -p ocaml jq
*)

(* Some modules (Str and Unix) require extra #load'ing. *)
#load "str.cma";;
#load "unix.cma";;

open Printf;;
open Sys;;

(* See https://ocaml.org/learn/tutorials/error_handling.html *)
Printexc.record_backtrace true;;

(* Check that we are sudo before proceeding *)
if Unix.geteuid () <> 0 then (eprintf "nixos-up must be run as root!"; exit 1);;

(* Sys.is_directory raises an error if the path does not exist. See https://ocaml.org/api/Sys.html. *)
let isdir path = file_exists path && is_directory path;;

(* Read the first line of a file *)
let read_first_line path =
  let channel = open_in path in
  let line = input_line channel in
  close_in channel;
  line;;

(* Read whole file into a string. *)
let read_file path =
  let channel = open_in path in
  let buffer = Buffer.create 1024 in
  let rec go () =
    try Buffer.add_channel buffer channel 1024; go ()
    with End_of_file -> Buffer.contents buffer in
  go ();;

(* Write `contents` to a file at `path`. *)
let write_file path contents =
  let oc = open_out path in
  output_string oc contents;
  close_out oc;;

(* List of disk identifiers. *)
let disks = readdir "/sys/block/"
  |> Array.to_list
  |> List.filter (fun x -> isdir (sprintf "/sys/block/%s/device" x));;

(* Get the size of a disk in kilobytes. *)
let disk_size_kb disk =
  let line = read_first_line (sprintf "/sys/block/%s/size" disk) in
  (* Linux reports sizes in 512 byte units, as opposed to 1K units. *)
  int_of_string line / 2;;

print_endline "\nDetected the following disks:\n";;
List.iteri
  (fun i name ->
    let maybe_read fn =
      if file_exists fn then read_first_line fn |> String.trim else "" in
    (* Vendor and model are not always present. See https://github.com/samuela/nixos-up/issues/2 and https://github.com/samuela/nixos-up/issues/6. *)
    let vendor = maybe_read (sprintf "/sys/block/%s/device/vendor" name) in
    let model = maybe_read (sprintf "/sys/block/%s/device/model" name) in
    let size_gb = (disk_size_kb name |> float_of_int) /. 1024.0 /. 1024.0 in
    printf "%2d: /dev/%s %6s %32s %.3f Gb total \n" (i + 1) name vendor model size_gb)
  disks;;
print_endline "";;

let rec ask_disk () =
  printf "Which disk number would you like to install onto (1-%d)? " (List.length disks);
  let input = read_line () in
  try
    let ix = int_of_string input in
    (* We subtract to maintain 0-based indexing. *)
    if 1 <= ix && ix <= List.length disks then ix - 1
    else (
      printf "Input must be between 1 and %d.\n\n" (List.length disks);
      ask_disk ())
  with e ->
    printf "Input must be an integer.\n\n";
    ask_disk ();;
(* The integer index of the selected disk in `disks`. *)
let selected_disk = ask_disk ();;
print_endline "";;

let rec ask_graphical () =
  printf {|Will this be a desktop/graphical install? Ie, do you have a monitor (y)
    or is this a server (n)? [Yn] |};
  let input = read_line () in
  match String.lowercase_ascii input with
  | "" | "y" -> true
  | "n" -> false
  | _ -> (
    printf "Input must be 'y' (yes) or 'n' (no).\n\n";
    ask_graphical ());;
let graphical = ask_graphical ();;
print_endline "";;

let rec ask_username () =
  printf "What would you like your username to be? ";
  let input = read_line () in
  let regex = Str.regexp "^[a-z_][a-z0-9_-]*[\\$]?$" in
  if Str.string_match regex input 0
    then input
    else (
      printf {|Usernames must begin with a lower case letter or an underscore,
    followed by lower case letters, digits, underscores, or dashes. They can end
    with a dollar sign.|};
      (* Can't put these in the {|...|} because they get interpreted literally. *)
      printf "\n\n";
      ask_username ());;
let username = ask_username ();;
print_endline "";;

(* Read a secret (eg password) from stdin without echoing as well. *)
let read_line_secret () =
  let tios = Unix.tcgetattr Unix.stdin in
  tios.c_echo <- false;
  Unix.tcsetattr Unix.stdin TCSANOW tios;

  let line = read_line () in

  let tios = Unix.tcgetattr Unix.stdin in
  tios.c_echo <- true;
  Unix.tcsetattr Unix.stdin TCSANOW tios;

  line;;

let rec ask_password () =
  printf "User password? ";
  let input1 = read_line_secret () in
  print_endline "";

  printf "And confirm: ";
  let input2 = read_line_secret () in
  print_endline "";

  if input1 = input2
    then input1
    else (
      printf "Hmm, those passwords don't match. Try again...\n\n";
      ask_password ());;
let password = ask_password ();;
print_endline "";;

let selected_disk_name = List.nth disks selected_disk;;
printf "Proceeding will entail repartitioning and formatting /dev/%s.\n" selected_disk_name;;
printf "!!! ALL DATA ON /dev/%s WILL BE LOST !!!\n\n" selected_disk_name;;

let rec ask_proceed () =
  printf "Are you sure you'd like to proceed? If so, please type 'yes' in full, otherwise Ctrl-C: ";
  let input = read_line () in
  if input = "yes" then () else ask_proceed ();;
ask_proceed ();;
print_endline "";;

printf "Ok, will begin installing in 10 seconds. Press Ctrl-C to cancel.\n\n";;
flush Stdlib.stdout;;
Unix.sleep 10;;

(* Run command `str` and fail with `CommandFailure` if it returns a non-zero exit code. *)
exception CommandFailure of string
let run str =
  printf ">>> %s\n" str; flush Stdlib.stdout;
  let retcode = Sys.command str in
  if retcode = 0 then () else raise (CommandFailure str);;

(* Run command `str` and return the first line of stdout *)
let run_first_line_stdout str =
  let channel = Unix.open_process_in str in
  let res = input_line channel in
  close_in channel;
  res;;

(* Partition *)
let efi = isdir "/sys/firmware/efi";;
if efi then (
  print_endline "Detected EFI/UEFI boot. Proceeding with a GPT partition scheme...";
  (* See https://nixos.org/manual/nixos/stable/index.html#sec-installation-partitioning-UEFI *)
  (* Create GPT partition table. *)
  run (sprintf "parted /dev/%s -- mklabel gpt" selected_disk_name);
  (* Create boot partition with first 512MiB. *)
  run (sprintf "parted /dev/%s -- mkpart ESP fat32 1MiB 512MiB" selected_disk_name);
  (* Set the partition as bootable *)
  run (sprintf "parted /dev/%s -- set 1 esp on" selected_disk_name);
  (* Create root partition after the boot partition. *)
  run (sprintf "parted /dev/%s -- mkpart primary 512MiB 100%%" selected_disk_name))
else (
  print_endline "Did not detect an EFI/UEFI boot. Proceeding with a legacy MBR partitioning scheme...";
  run (sprintf "parted /dev/%s -- mklabel msdos" selected_disk_name);
  run (sprintf "parted /dev/%s -- mkpart primary 1MiB 100%%" selected_disk_name));;

(* Formatting *)

(* Somehow ocaml's standard library doesn't include a built-in for starts_with... *)
let string_starts_with str prefix = String.length str >= String.length prefix && String.sub str 0 (String.length prefix) = prefix;;

(* Different linux device drivers have different partition naming conventions. *)
let partition_name disk partition =
  if string_starts_with disk "sd" then (sprintf "%s%d" disk partition)
  (* See https://github.com/samuela/nixos-up/issues/7. *)
  else if string_starts_with disk "nvme" then (sprintf "%sp%d" disk partition)
  else (
    print_endline "Warning: this type of device driver has not been thoroughly tested with nixos-up, and its partition naming scheme may differ from what we expect. Please open an issue at https://github.com/samuela/nixos-up/issues.";
    sprintf "%s%d" disk partition);;

if efi then (
  (* EFI: The first partition is boot and the second is the root partition. *)
  run (sprintf "mkfs.fat -F 32 -n boot /dev/%s" (partition_name selected_disk_name 1));
  run (sprintf "mkfs.ext4 -L nixos /dev/%s" (partition_name selected_disk_name 2)))
else
  (* MBR: The first partition is the root partition and there's no boot partition. *)
  run (sprintf "mkfs.ext4 -L nixos /dev/%s" (partition_name selected_disk_name 1));;

(* Mounting *)
(* Sometimes when switching between BIOS/UEFI, we need to force the kernel to
refresh its block index. Otherwise we get "special device does not exist"
errors. The answer here https://askubuntu.com/questions/334022/mount-error-special-device-does-not-exist
suggests `blockdev --rereadpt` but that doesn't seem to always work. *)
(* run (sprintf "blockdev --rereadpt /dev/%s" selected_disk_name);; *)
run "mount /dev/disk/by-label/nixos /mnt";;
if efi then (
  run "mkdir -p /mnt/boot";
  run "mount /dev/disk/by-label/boot /mnt/boot");;

(* Generate config. *)
run "nixos-generate-config --root /mnt";;

let config_path = "/mnt/etc/nixos/configuration.nix";;
let config = ref (read_file config_path);;

(* nixos-up banner *)
config := {|
################################################################################
# █▄░█ █ ▀▄▀ █▀█ █▀ ▄▄ █░█ █▀█
# █░▀█ █ █░█ █▄█ ▄█ ░░ █▄█ █▀▀
#
# 🚀 This NixOS installation brought to you by nixos-up! 🚀
# Please consider supporting the project (https://github.com/samuela/nixos-up)
# and the NixOS Foundation (https://opencollective.com/nixos)!
################################################################################

|} ^ !config;;

(* Non-EFI systems require boot.loader.grub.device to be specified. *)
if (not efi) then (
  config := Str.global_replace
    (Str.regexp_string "boot.loader.grub.version = 2;")
    (sprintf "boot.loader.grub.version = 2;\n  boot.loader.grub.device = \"/dev/%s\";\n" selected_disk_name)
    !config);;

(* Declarative user management *)
(* Using `passwordFile` is a little bit more secure than `hashedPassword` since
it avoids putting hashed passwords into the world-readable nix store. See
https://discourse.nixos.org/t/introducing-nixos-up-a-dead-simple-installer-for-nixos/12350/11?u=samuela *)
let hashed_password = run_first_line_stdout (sprintf "mkpasswd --method=sha-512 %s" password) in
  let password_file_path = sprintf "/mnt/etc/passwordFile-%s" username in
  write_file password_file_path hashed_password;
  Unix.chmod password_file_path 0o600;;

config := Str.global_replace
  (* We do our best here to match against the commented out users block. *)
  (Str.regexp " *# Define a user account\\..*\n\\( *# .*\n\\)+")
  (String.concat "\n" [
    "  users.mutableUsers = false;";
    sprintf "  users.users.%s = {" username;
    "    isNormalUser = true;";
    {|    extraGroups = [ "wheel" "networkmanager" ];|};
    sprintf {|    passwordFile = "/etc/passwordFile-%s";|} username;
    "  };";
    "";
    {|  # Disable password-based login for root.|};
    {|  users.users.root.hashedPassword = "!";|};
    ""
  ])
  !config;;

(* Graphical environment *)
if graphical then (
  (* For some reason this produces an error: "You cannot use networking.networkmanager with networking.wireless." *)
  (* config := Str.global_replace
    (Str.regexp_string {|# networking.wireless.enable = true;|})
    "networking.wireless.enable = true;"
    !config; *)
  config := Str.global_replace
    (Str.regexp_string {|# services.printing.enable = true;|})
    "services.printing.enable = true;"
    !config;
  config := Str.global_replace
    (Str.regexp_string {|# sound.enable = true;|})
    "sound.enable = true;"
    !config;
  config := Str.global_replace
    (Str.regexp_string {|# hardware.pulseaudio.enable = true;|})
    "hardware.pulseaudio.enable = true;"
    !config;
  config := Str.global_replace
    (Str.regexp_string {|# services.xserver.libinput.enable = true;|})
    "services.xserver.libinput.enable = true;"
    !config;
  (* See https://nixos.wiki/wiki/GNOME. *)
  config := Str.global_replace
    (Str.regexp_string {|# services.xserver.enable = true;|})
    "services.xserver.enable = true;\n  services.xserver.displayManager.gdm.enable = true;\n  services.xserver.desktopManager.gnome3.enable = true;"
    !config;
);;

(* home-manager installation and swap *)

(* See https://github.com/nix-community/home-manager/blob/master/home-manager/install.nix. *)
let home_manager_config = sprintf {|
{ config, pkgs, ... }:
{
  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
  # Home Manager needs a bit of information about you and the
  # paths it should manage.
  home.username = "%s";
  home.homeDirectory = "/home/%s";

  # This value determines the Home Manager release that your
  # configuration is compatible with. This helps avoid breakage
  # when a new Home Manager release introduces backwards
  # incompatible changes.
  #
  # You can update Home Manager without changing this value. See
  # the Home Manager release notes for a list of state version
  # changes in each release.
  home.stateVersion = "21.05";
}
|} username username;;
run (sprintf "mkdir -p /mnt/home/%s/.config/nixpkgs/" username);;
write_file (sprintf "/mnt/home/%s/.config/nixpkgs/home.nix" username) home_manager_config;;

let ram_kb =
  (* Should be of the form "MemTotal:         981872 kB" *)
  let raw_line = read_first_line "/proc/meminfo" in
  (* OCaml's regex parsing is weak. There's no \s or \d available. *)
  let regex = Str.regexp "MemTotal:[ ]+\\([0-9]+\\) kB" in
  let raw = Str.replace_first regex "\\1" raw_line in
  int_of_string raw;;
printf "Detected %d kb of RAM...\n" ram_kb;;

(* The Ubuntu guidelines say max(1GB, sqrt(RAM)) for swap on computers not
utilizing hibernation. In the case of hibernation, max(1GB, RAM + sqrt(RAM)).
See https://help.ubuntu.com/community/SwapFaq. *)
let swap_kb =
  let sqrt_ram_kb = ram_kb |> float_of_int |> sqrt |> int_of_float in
  max sqrt_ram_kb (1024 * 1024);;
let hibernation_swap_kb = ram_kb + swap_kb;;
config :=
  let swap_mb = swap_kb / 1024 in
  let hibernation_swap_mb = hibernation_swap_kb / 1024 in
  Str.global_replace
    (* We do our best here to match against the commented out  block. *)
    (Str.regexp " *# environment.systemPackages = .*\n\\( *# .*\n\\)+")
    (String.concat "\n" [
      "  environment.systemPackages = with pkgs; [ home-manager ];";
      sprintf {|
  # Configure swap file. Sizes are in megabytes. Default swap is
  # max(1GB, sqrt(RAM)) = %d. If you want to use hibernation with this device
  # (eg suspending a laptop), then it's recommended that you use
  # RAM + max(1GB, sqrt(RAM)) = %d.|} swap_mb hibernation_swap_mb;
      sprintf {|  swapDevices = [ { device = "/swapfile"; size = %d; } ];|} swap_mb;
      ""
    ])
    !config;;

(* Timezone *)
let timezone = run_first_line_stdout "curl --silent --fail ipinfo.io | jq -r .timezone";;
printf "Detected timezone as %s...\n" timezone;;
config := Str.global_replace
    (Str.regexp "# time.timeZone = .*")
    (sprintf {|time.timeZone = "%s";|} timezone)
    !config;

(* Write the new config file back out *)
write_file config_path !config;;

(* See https://github.com/samuela/nixos-up/issues/11 *)
run "nix-build '<nixpkgs/nixos>' -A config.system.build.toplevel -I nixos-config=/mnt/etc/nixos/configuration.nix";;
run "nixos-install --no-root-passwd";;

print_endline {|
================================================================================
            Welcome to the NixOS community! We're happy to have you!

Getting started:

  * Your system configuration lives in `/etc/nixos/configuration.nix`. You can
    edit that file, run `sudo nixos-rebuild switch`, and you're all set!
  * home-manager is the way to go for installing user applications, and managing
    your user environment. You can run `home-manager edit` and
    `home-manager switch` to get going. Check out the manual for more info
    (https://rycee.gitlab.io/home-manager/).
  * nix-shell is your friend. `nix-shell -p curl jq` drops you right into a
    shell with all of your favorite programs.
  * The NixOS community hangs out at https://discourse.nixos.org/. Feel free to
    stop by with any questions or comments!
  * The NixOS manual (https://nixos.org/manual/nixos/stable/) and unofficial
    user Wiki (https://nixos.wiki/) are great resources if you get stuck!
  * NixOS is only made possible because of contributions from users like you.
    Please consider contributing to the NixOS Foundation to further its
    development at https://opencollective.com/nixos!

To get started with your new installation: `sudo shutdown now`, remove the live
USB/CD device, and reboot your system!
================================================================================
|};
