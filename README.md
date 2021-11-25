# nixos-up

nixos-up is a dead-simple install wizard for NixOS. It's the fastest way to get from ISO to working installation.

From the NixOS installation USB/CD:

```
sudo nix-shell https://github.com/samuela/nixos-up/archive/main.tar.gz
```

You can check out a video demonstrating the process here: https://youtu.be/f7DzbiRD99Q.

## Development

In this directory run `servefile --tar --compression gzip --port 12345 .`. Then, while that's running `nix-shell -p ngrok --run "ngrok http 12345"`.

Now in your VM/device, run

```
nix-collect-garbage && sudo nix-shell http://blah-blah-blah.ngrok.io/nixos-up.tar.gz
```

You may need `sudo umount --lazy /mnt` periodically as well.
