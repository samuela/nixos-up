import os
import re
import subprocess
import sys
import time
from getpass import getpass
from math import sqrt
from pathlib import Path

import psutil
import requests

if os.geteuid() != 0:
  sys.exit("nixos-up must be run as root!")

nixos_version = os.environ["NIXOS_VERSION"][:5]
print(f"Detected NixOS version {nixos_version}")

if subprocess.run(["mountpoint", "/mnt"]).returncode == 0:
  sys.exit("Something is already mounted at /mnt!")

sys_block = Path("/sys/block/")
disks = [p.name for p in sys_block.iterdir() if (p / "device").is_dir()]

def disk_size_kb(disk: str) -> int:
  # Linux reports sizes in 512 byte units, as opposed to 1K units.
  with (sys_block / disk / "size").open() as f:
    return int(f.readline().strip()) / 2

# Vendor and model are not always present. See https://github.com/samuela/nixos-up/issues/2 and https://github.com/samuela/nixos-up/issues/6.
def maybe_read_first_line(path: Path) -> str:
  if path.is_file():
    with path.open() as f:
      return f.readline().strip()
  return ""

print("\nDetected the following disks:\n")
for diskno, name in enumerate(disks, start=1):
  vendor = maybe_read_first_line(sys_block / name / "device" / "vendor")
  model = maybe_read_first_line(sys_block / name / "device" / "model")
  size_gb = float(disk_size_kb(name)) / 1024 / 1024
  print(f"{diskno}: /dev/{name:12} {vendor:12} {model:32} {size_gb:.3f} Gb total")
print()

def ask_disk() -> int:
  sel = input(f"Which disk number would you like to install onto (1-{len(disks)})? ")
  try:
    ix = int(sel)
    if 1 <= ix <= len(disks):
      # We subtract to maintain 0-based indexing.
      return ix - 1
    else:
      print(f"Input must be between 1 and {len(disks)}.\n")
      return ask_disk()
  except ValueError:
    print(f"Input must be an integer.\n")
    return ask_disk()

selected_disk = ask_disk()
print()

def ask_graphical() -> bool:
  sel = input("""Will this be a desktop/graphical install? Ie, do you have a
    monitor (y) or is this a server (n)? [Yn] """).lower()

  if sel == "" or sel == "y":
    return True
  elif sel == "n":
    return False
  else:
    print("Input must be 'y' (yes) or 'n' (no).\n")
    return ask_graphical()

graphical = ask_graphical()
print()

def ask_username() -> str:
  sel = input("What would you like your username to be? ")
  if re.fullmatch(r"^[a-z_][a-z0-9_-]*[\$]?$", sel):
    return sel
  else:
    print("""Usernames must begin with a lower case letter or an underscore,
    followed by lower case letters, digits, underscores, or dashes. They can end
    with a dollar sign.\n""")
    return ask_username()

username = ask_username()
print()

def ask_password() -> str:
  pw1 = getpass("User password? ")
  pw2 = getpass("And confirm: ")

  if pw1 == pw2:
    return pw1
  else:
    print("Hmm, those passwords don't match. Try again...\n")
    return ask_password()

password = ask_password()
print()

selected_disk_name = disks[selected_disk]
print(f"Proceeding will entail repartitioning and formatting /dev/{selected_disk_name}.\n")
print(f"!!! ALL DATA ON /dev/{selected_disk_name} WILL BE LOST !!!\n")

def ask_proceed():
  sel = input("Are you sure you'd like to proceed? If so, please type 'yes' in full, otherwise Ctrl-C: ")
  if sel == "yes":
    return
  else:
    return ask_proceed()

ask_proceed()
print()

print("Ok, will begin installing in 10 seconds. Press Ctrl-C to cancel.\n")
sys.stdout.flush()
time.sleep(10)

def run(args):
  print(f">>> {' '.join(args)}")
  subprocess.run(args, check=True)

### Partitioning
# Whether or not we are on a (U)EFI system
efi = Path("/sys/firmware/efi").is_dir()
if efi:
  print("Detected EFI/UEFI boot. Proceeding with a GPT partition scheme...")
  # See https://nixos.org/manual/nixos/stable/index.html#sec-installation-partitioning-UEFI
  # Create GPT partition table.
  run(["parted", f"/dev/{selected_disk_name}", "--", "mklabel", "gpt"])
  # Create boot partition with first 512MiB.
  run(["parted", f"/dev/{selected_disk_name}", "--", "mkpart", "ESP", "fat32", "1MiB", "512MiB"])
  # Set the partition as bootable
  run(["parted", f"/dev/{selected_disk_name}", "--", "set", "1", "esp", "on"])
  # Create root partition after the boot partition.
  run(["parted", f"/dev/{selected_disk_name}", "--", "mkpart", "primary", "512MiB", "100%"])
else:
  print("Did not detect an EFI/UEFI boot. Proceeding with a legacy MBR partitioning scheme...")
  run(["parted", f"/dev/{selected_disk_name}", "--", "mklabel", "msdos"])
  run(["parted", f"/dev/{selected_disk_name}", "--", "mkpart", "primary", "1MiB", "100%"])

### Formatting
# Different linux device drivers have different partition naming conventions.
def partition_name(disk: str, partition: int) -> str:
  if disk.startswith("sd"):
    return f"{disk}{partition}"
  elif disk.startswith("nvme"):
    return f"{disk}p{partition}"
  else:
    print("Warning: this type of device driver has not been thoroughly tested with nixos-up, and its partition naming scheme may differ from what we expect. Please open an issue at https://github.com/samuela/nixos-up/issues.")
    return f"{disk}{partition}"

def wait_for_partitions():
  for _ in range(10):
    if Path(f"/dev/{partition_name(selected_disk_name, 1)}").exists():
      return
    else:
      time.sleep(1)
  print(f"WARNING: Waited for /dev/{partition_name(selected_disk_name, 1)} to show up but it never did. Things may break.")

wait_for_partitions()

if efi:
  # EFI: The first partition is boot and the second is the root partition.
  # This occasionally fails with "unable to open /dev/"
  run(["mkfs.fat", "-F", "32", "-n", "boot", f"/dev/{partition_name(selected_disk_name, 1)}"])
  run(["mkfs.ext4", "-L", "nixos", f"/dev/{partition_name(selected_disk_name, 2)}"])
else:
  # MBR: The first partition is the root partition and there's no boot partition.
  run(["mkfs.ext4", "-L", "nixos", f"/dev/{partition_name(selected_disk_name, 1)}"])

### Mounting
# Sometimes when switching between BIOS/UEFI, we need to force the kernel to
# refresh its block index. Otherwise we get "special device does not exist"
# errors. The answer here https://askubuntu.com/questions/334022/mount-error-special-device-does-not-exist
# suggests `blockdev --rereadpt` but that doesn't seem to always work.
def refresh_block_index():
  for _ in range(10):
    try:
      run(["blockdev", "--rereadpt", f"/dev/{selected_disk_name}"])
      # Sometimes it takes a second for re-reading the partition table to take.
      time.sleep(1)
      if Path("/dev/disk/by-label/nixos").exists():
        return
    except subprocess.CalledProcessError:
      # blockdev failed, likely due to "ioctl error on BLKRRPART: Device or resource busy"
      pass
  print(f"WARNING: Failed to re-read the block index on /dev/{selected_disk_name}. Things may break.")

refresh_block_index()

# This occasionally fails with "/dev/disk/by-label/nixos does not exist".
run(["mount", "/dev/disk/by-label/nixos", "/mnt"])
if efi:
  run(["mkdir", "-p", "/mnt/boot"])
  run(["mount", "/dev/disk/by-label/boot", "/mnt/boot"])

### Generate config
run(["nixos-generate-config", "--root", "/mnt"])

config_path = "/mnt/etc/nixos/configuration.nix"
with open(config_path, "r") as f:
  config = f.read()

# nixos-up banner
config = """\
################################################################################
# █▄░█ █ ▀▄▀ █▀█ █▀ ▄▄ █░█ █▀█
# █░▀█ █ █░█ █▄█ ▄█ ░░ █▄█ █▀▀
#
# 🚀 This NixOS installation brought to you by nixos-up! 🚀
# Please consider supporting the project (https://github.com/samuela/nixos-up)
# and the NixOS Foundation (https://opencollective.com/nixos)!
################################################################################

""" + config

# home-manager
config = re.sub(r"({ config(, lib)?, pkgs, \.\.\. }):\s+{", f"""\
\\1:

let
  home-manager = fetchTarball "https://github.com/nix-community/home-manager/archive/release-{nixos_version}.tar.gz";
in
{{
  # Your home-manager configuration! Check out https://rycee.gitlab.io/home-manager/ for all possible options.
  home-manager.users.{username} = {{ pkgs, ... }}: {{
    home.packages = with pkgs; [ hello ];
    home.stateVersion = "{nixos_version}";
    programs.starship.enable = true;
  }};
""", config)
config = re.sub(r"imports =\s*\[", """imports = [ "${home-manager}/nixos" \n""", config)

# Non-EFI systems require boot.loader.grub.device to be specified.
if not efi:
  config = config.replace("boot.loader.grub.version = 2;", f"boot.loader.grub.version = 2;\n  boot.loader.grub.device = \"/dev/{selected_disk_name}\";\n")

# Declarative user management
# Using `hashedPasswordFile` is a little bit more secure than `hashedPassword` since
# it avoids putting hashed passwords into the world-readable nix store. See
# https://discourse.nixos.org/t/introducing-nixos-up-a-dead-simple-installer-for-nixos/12350/11?u=samuela *)
hashed_password = subprocess.run(["mkpasswd", "--method=sha-512", password], check=True, capture_output=True, text=True).stdout.strip()
password_file_path = f"/mnt/etc/passwordFile-{username}"
with open(password_file_path, "w") as f:
  f.write(hashed_password)
os.chmod(password_file_path, 600)

# We do our best here to match against the commented out users block.
config = re.sub(r" *# Define a user account\..*\n( *# .*\n)+", "\n".join([
  "  users.mutableUsers = false;",
  f"  users.users.{username} = {{",
  "    isNormalUser = true;",
  "    extraGroups = [ \"wheel\" \"networkmanager\" ];",
  f"    hashedPasswordFile = \"/etc/hashedPasswordFile-{username}\";",
  "  };",
  "",
  "  # Disable password-based login for root.",
  "  users.users.root.hashedPassword = \"!\";",
  ""
]), config)

# Graphical environment
if graphical:
  config = config.replace("# services.printing.enable = true;", "services.printing.enable = true;")
  config = config.replace("# sound.enable = true;", "sound.enable = true;")
  config = config.replace("# hardware.pulseaudio.enable = true;", "hardware.pulseaudio.enable = true;")
  config = config.replace("# services.xserver.libinput.enable = true;", "services.xserver.libinput.enable = true;")
  # See https://nixos.wiki/wiki/GNOME.
  config = config.replace("# services.xserver.enable = true;", "services.xserver.enable = true;\n  services.xserver.desktopManager.gnome.enable = true;")

ram_bytes = psutil.virtual_memory().total
print(f"Detected {(ram_bytes / 1024 / 1024 / 1024):.3f} Gb of RAM...")

# The Ubuntu guidelines say max(1GB, sqrt(RAM)) for swap on computers not
# utilizing hibernation. In the case of hibernation, max(1GB, RAM + sqrt(RAM)).
# See https://help.ubuntu.com/community/SwapFaq.
swap_bytes = max(int(sqrt(ram_bytes)), 1024 * 1024 * 1024)
swap_mb = int(swap_bytes / 1024 / 1024)
hibernation_swap_bytes = swap_bytes + ram_bytes
hibernation_swap_mb = int(hibernation_swap_bytes / 1024 / 1024)

# Match against the end of the file. Note that because we're not using re.MULTILINE here $ matches the end of the file.
config = re.sub(r"\}\s*$", "\n".join([
  f"  # Configure swap file. Sizes are in megabytes. Default swap is",
  f"  # max(1GB, sqrt(RAM)) = {swap_mb}. If you want to use hibernation with",
  f"  # this device, then it's recommended that you use",
  f"  # RAM + max(1GB, sqrt(RAM)) = {hibernation_swap_mb:.3f}.",
  f"  swapDevices = [ {{ device = \"/swapfile\"; size = {swap_mb}; }} ];",
  "}",
  ""
]), config)

# Timezone
timezone = requests.get("http://ipinfo.io").json()["timezone"]
print(f"Detected timezone as {timezone}...")
config = re.sub(r"# time\.timeZone = .*$", f"time.timeZone = \"{timezone}\";", config, flags=re.MULTILINE)

with open(config_path, "w") as f:
  f.write(config)

# Finally do the install!
run(["nixos-install", "--no-root-passwd"])

print("""
================================================================================
            Welcome to the NixOS community! We're happy to have you!

Getting started:

  * Your system configuration lives in `/etc/nixos/configuration.nix`. You can
    edit that file, run `sudo nixos-rebuild switch`, and you're all set!
  * home-manager is the way to go for installing user applications, and managing
    your user environment. Edit the home-manager section in
    `/etc/nixos/configuration.nix` and then `home-manager switch` to get going.
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
""")
