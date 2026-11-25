# claude-desktop-nixos

A Nix flake that packages Anthropic's **official Claude Desktop Linux beta** for NixOS
(`x86_64-linux` and `aarch64-linux`).

It repackages the signed `.deb` from Anthropic's apt repository and does not rebuild anything. The bundled
Electron is patched with `autoPatchelf`. Hardcoded `/usr` paths in the app bundle are
rewritten to Nix store paths. The Debian maintainer scripts (apt repo, AppArmor) are not run.
The parts that matter on NixOS (desktop entry, icons, MIME types, GNOME search provider) are
installed into the package instead.

> Unofficial packaging. Claude Desktop is proprietary (`meta.license = unfree`) and Linux
> support is in beta upstream.

## Try it

```sh
nix run github:zjom/claude-desktop-nixos
```

## NixOS

```nix
# flake.nix
{
  inputs.claude-desktop.url = "github:zjom/claude-desktop-nixos";
  inputs.claude-desktop.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { nixpkgs, claude-desktop, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        claude-desktop.nixosModules.default
        {
          nixpkgs.config.allowUnfreePredicate = pkg: nixpkgs.lib.getName pkg == "claude-desktop";
          programs.claude-desktop.enable = true;
        }
      ];
    };
  };
}
```

The module builds the package against your system's nixpkgs, so the unfree predicate above
(or `allowUnfree = true`) is required.

| Option | Default | Effect |
|---|---|---|
| `programs.claude-desktop.enable` | `false` | Installs the app. Enables XDG portals (file dialogs, Wayland global shortcuts) and registers the search provider's D-Bus service. |
| `programs.claude-desktop.package` | built from this flake | Package to install. |
| `programs.claude-desktop.cowork.enable` | `false` | Builds with Cowork support (see below) and loads `vhost_vsock`. |
| `programs.claude-desktop.cowork.users` | `[ ]` | Users to add to `kvm`. Only needed if your system restricts `/dev/kvm` to that group (NixOS default is world-accessible). |
| `programs.claude-desktop.keyring.enable` | `false` | Enables GNOME Keyring for window managers that lack a Secret Service provider. |

### Without the module

`overlays.default` adds `pkgs.claude-desktop`. You can also use
`claude-desktop.packages.${system}.default` directly, for example in `home.packages`.

## Package arguments

Pass these with `.override { ... }`:

| Argument | Default | |
|---|---|---|
| `withCowork` | `false` | Points Cowork at nixpkgs' `qemu_kvm`, `OVMF` and `virtiofsd`. Also available as `packages.${system}.claude-desktop-cowork`. |
| `withGnomeSearchProvider` | `true` | Installs the GNOME Shell search provider (adds `gjs` to the closure). |
| `passwordStore` | `null` | Chromium `--password-store` backend; see "Sign-in storage" below. |
| `commandLineArgs` | `""` | Extra flags for every launch, e.g. `"--no-sandbox"`. |

## Notes

- **Sign-in storage.** The sign-in token lives in the Secret Service (GNOME Keyring,
  KWallet, KeePassXC, ...). Chromium only uses libsecret on desktops it recognises. On
  everything else (niri, sway, Hyprland, ...) it falls back to plaintext and the app refuses
  to keep you signed in. The wrapper therefore passes `--password-store=gnome-libsecret`
  except on KDE, where the app picks KWallet itself. Set `passwordStore` to choose a backend
  explicitly.
- **Wayland.** With `NIXOS_OZONE_WL=1` set, the app runs natively on Wayland. Quick Entry's
  global hotkey needs a portal implementing `GlobalShortcuts` (e.g. `xdg-desktop-portal-gnome`,
  `-kde` or `-hyprland`).
- **Sandbox.** `chrome-sandbox` cannot be setuid in the Nix store, so it is removed and
  Chromium uses the user-namespace sandbox, which NixOS enables by default. If startup fails with a
  sandbox error on a hardened kernel, run with `--no-sandbox`.
- **Updates.** The app does not update itself on Linux. Update the flake input. In this repo,
  `nix run .#update` checks the signed apt repository and bumps
  `pkgs/claude-desktop/sources.json`. It verifies `InRelease` against the pinned key in
  `keys/` (fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`). A daily GitHub Action
  runs it, builds both variants and opens a PR.
- **Cowork patches** are exact string replacements in `app.asar`. If upstream moves those
  strings, the `claude-desktop-cowork` build fails loudly rather than shipping a silently
  broken Cowork. The default build only applies optional patches and keeps working.
