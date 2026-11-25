{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  asar,
  autoPatchelfHook,
  makeWrapper,
  wrapGAppsHook3,

  # Shared libraries the bundled Electron and native modules link against.
  alsa-lib,
  at-spi2-core,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libcap_ng,
  libdrm,
  libgbm,
  libseccomp,
  libuuid,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  libxtst,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,

  # Libraries Chromium/Electron dlopen() at runtime.
  libGL,
  libayatana-appindicator,
  libnotify,
  libpulseaudio,
  libsecret,
  libva,
  libxscrnsaver,
  vulkan-loader,
  wayland,

  # Helper programs the app shells out to.
  bubblewrap,
  gjs,
  openssh,
  procps,
  socat,
  trash-cli,
  xdg-utils,

  # Cowork (local VM) support.
  OVMF,
  qemu_kvm,
  virtiofsd,

  # Run Cowork VMs with nixpkgs' qemu, OVMF and virtiofsd. This patches
  # hardcoded /usr paths inside app.asar; the build fails if upstream changes them.
  withCowork ? false,
  # Install the GNOME Shell search provider (pulls in gjs).
  withGnomeSearchProvider ? true,
  # Chromium --password-store backend (e.g. "gnome-libsecret", "kwallet6", "basic").
  # null: KWallet on KDE (chosen by the app), libsecret everywhere else.
  passwordStore ? null,
  # Extra flags appended to every invocation, e.g. "--no-sandbox".
  commandLineArgs ? "",
}:

let
  sources = lib.importJSON ./sources.json;

  debArch =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "claude-desktop: unsupported system ${stdenv.hostPlatform.system}");

  qemuBinary = if stdenv.hostPlatform.isAarch64 then "qemu-system-aarch64" else "qemu-system-x86_64";

  runtimeDependencies = [
    libGL
    libayatana-appindicator
    libnotify
    libpulseaudio
    libsecret
    libva
    libxscrnsaver
    pipewire
    systemd
    vulkan-loader
    wayland
  ];

  runtimePath = [
    bubblewrap
    glib # gio
    openssh
    socat
    trash-cli
    xdg-utils
  ]
  ++ lib.optionals withCowork [
    qemu_kvm
    virtiofsd
  ];

  # Arguments for makeShellWrapper. Strings are passed literally into the
  # generated script, so ${VAR} references there expand at launch time.
  wrapperArgs = [
    "--suffix"
    "PATH"
    ":"
    (lib.makeBinPath runtimePath)
    "--add-flags"
    "\${NIXOS_OZONE_WL:+\${WAYLAND_DISPLAY:+--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime=true}}"
  ]
  ++ (
    if passwordStore == null then
      # Chromium only picks libsecret on desktops it recognises (GNOME, XFCE, ...)
      # and otherwise keeps the sign-in token in plaintext, which the app refuses
      # to persist. The app selects KWallet itself on KDE. Later flags win, so an
      # explicit --password-store in commandLineArgs or "$@" still overrides this.
      [
        "--run"
        ''case "''${XDG_CURRENT_DESKTOP-}" in *KDE*) claudePasswordStore= ;; *) claudePasswordStore=--password-store=gnome-libsecret ;; esac''
        "--add-flags"
        "\${claudePasswordStore}"
      ]
    else
      [
        "--add-flags"
        (lib.escapeShellArg "--password-store=${passwordStore}")
      ]
  )
  ++ lib.optionals (commandLineArgs != "") [
    "--add-flags"
    commandLineArgs
  ];
in
stdenv.mkDerivation {
  pname = "claude-desktop";
  inherit (sources) version;

  src = fetchurl { inherit (sources.${debArch}) url hash; };

  nativeBuildInputs = [
    dpkg
    asar
    autoPatchelfHook
    makeWrapper
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-core
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libcap_ng
    libdrm
    libgbm
    libseccomp
    libuuid
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    libxtst
    nspr
    nss
    pango
    pipewire
    stdenv.cc.cc.lib
    systemd
  ];

  runtimeDependencies = map lib.getLib runtimeDependencies;

  dontConfigure = true;
  dontBuild = true;
  dontWrapGApps = true;

  # Extract the payload only; the maintainer scripts (apt repo, AppArmor,
  # symlinks into /usr) are reimplemented below where they make sense on Nix.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
    runHook postUnpack
  '';

  # Rewrite absolute /usr paths baked into the bundled JavaScript.
  # Usage: patchAsarLiteral required|optional FROM TO
  postPatch = ''
    patchAsarLiteral() {
      local mode=$1 from=$2 to=$3 files
      files=$(grep -rlF -- "$from" app/.vite/build || true)
      if [ -z "$files" ]; then
        if [ "$mode" = required ]; then
          echo "error: $from not found in app.asar (upstream changed it; update pkgs/claude-desktop/default.nix)" >&2
          exit 1
        fi
        echo "warning: $from not found in app.asar, skipping" >&2
        return 0
      fi
      for f in $files; do
        echo "patching $from -> $to in ''${f#app/}"
        substituteInPlace "$f" --replace-fail "$from" "$to"
      done
    }

    asar extract usr/lib/claude-desktop/resources/app.asar app

    patchAsarLiteral optional '"/usr/bin/busctl"' '"${lib.getExe' systemd "busctl"}"'
    patchAsarLiteral optional '"/usr/bin/pgrep"' '"${lib.getExe' procps "pgrep"}"'
    patchAsarLiteral optional '"/usr/bin/ssh"' '"${lib.getExe' openssh "ssh"}"'
    patchAsarLiteral optional '"/usr/bin/secret-tool"' '"${lib.getExe' libsecret "secret-tool"}"'
  ''
  + lib.optionalString withCowork (
    ''
      patchAsarLiteral required '"/usr/bin/${qemuBinary}"' '"${lib.getExe' qemu_kvm qemuBinary}"'
      patchAsarLiteral required '"/usr/libexec/virtiofsd"' '"${lib.getExe virtiofsd}"'
    ''
    + (
      if stdenv.hostPlatform.isAarch64 then
        ''
          patchAsarLiteral required '"/usr/share/AAVMF/AAVMF_CODE.fd"' '"${OVMF.firmware}"'
        ''
      else
        ''
          patchAsarLiteral required '"/usr/share/OVMF/OVMF_CODE_4M.fd"' '"${OVMF.firmware}"'
          patchAsarLiteral optional '"/usr/share/OVMF/OVMF_CODE.fd"' '"${OVMF.firmware}"'
        ''
    )
  )
  + ''
    rm usr/lib/claude-desktop/resources/app.asar
    asar pack --unpack '*.node' app usr/lib/claude-desktop/resources/app.asar
    rm -r app
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin $out/share
    cp -r usr/lib/claude-desktop $out/lib/claude-desktop
    cp -r usr/share/applications usr/share/icons usr/share/pixmaps $out/share/

    # Can't be setuid in the Nix store; Chromium falls back to the
    # user-namespace sandbox, which NixOS enables by default.
    rm $out/lib/claude-desktop/chrome-sandbox

    # MIME types for .mcpb/.dxt/.skill files (postinst: write_mime_types).
    install -Dm644 $out/lib/claude-desktop/resources/linux-mime/com.anthropic.Claude.xml \
      $out/share/mime/packages/com.anthropic.Claude.xml

    # Claude Code launcher (postinst: link_ccd_launcher), when shipped.
    if [ -x $out/lib/claude-desktop/resources/bin/ccd ]; then
      ln -s $out/lib/claude-desktop/resources/bin/ccd $out/bin/ccd
    fi
  ''
  + lib.optionalString withGnomeSearchProvider ''
    # GNOME Shell search provider (postinst: write_search_provider).
    sp=$out/lib/claude-desktop/resources/gnome-search-provider
    substituteInPlace $sp/searchProvider.js \
      --replace-fail 'const EXECUTABLE = "claude-desktop";' "const EXECUTABLE = \"$out/bin/claude-desktop\";"
    install -Dm644 $sp/com.anthropic.Claude.search-provider.ini \
      -t $out/share/gnome-shell/search-providers
    install -Dm644 $sp/com.anthropic.Claude.SearchProvider.service \
      -t $out/share/dbus-1/services
    substituteInPlace $out/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service \
      --replace-fail /usr/bin/gjs ${lib.getExe gjs} \
      --replace-fail /usr/lib/claude-desktop $out/lib/claude-desktop
  ''
  + ''
    runHook postInstall
  '';

  postFixup = ''
    makeShellWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
      "''${gappsWrapperArgs[@]}" \
      ${lib.escapeShellArgs wrapperArgs}
  '';

  passthru = {
    inherit sources withCowork;
  };

  meta = {
    description = "Claude desktop app (official Linux beta, repackaged)";
    homepage = "https://claude.ai/download";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "claude-desktop";
  };
}
