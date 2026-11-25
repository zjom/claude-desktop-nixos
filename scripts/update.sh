# Bump pkgs/claude-desktop/sources.json to the newest claude-desktop in
# Anthropic's apt repository. Run via `nix run .#update [path/to/sources.json]`.
#
# Trust chain: pinned key (keys/) -> signed InRelease -> Packages index
# sha256 -> .deb sha256 (written as the fetchurl hash).

repo="https://downloads.claude.ai/claude-desktop/apt/stable"
suite="stable"
component="main"
fingerprint="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
keyring="${KEYRING:?KEYRING must point at the pinned apt signing key}"

if [ $# -ge 1 ]; then
  sources="$1"
else
  sources="$(git rev-parse --show-toplevel)/pkgs/claude-desktop/sources.json"
fi
[ -f "$sources" ] || { echo "error: $sources not found" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -m 700 "$GNUPGHOME"

fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 "$1" -o "$2"; }

# 1. Verify InRelease against the pinned key and the expected fingerprint.
gpg --batch --quiet --dearmor -o "$work/keyring.gpg" < "$keyring"
fetch "$repo/dists/$suite/InRelease" "$work/InRelease"
gpgv --keyring "$work/keyring.gpg" --status-fd 3 --output "$work/Release" \
  "$work/InRelease" 3> "$work/gpgv.status" 2> /dev/null \
  || { echo "error: InRelease signature verification failed" >&2; exit 1; }
grep -q "^\[GNUPG:\] VALIDSIG $fingerprint " "$work/gpgv.status" \
  || { echo "error: InRelease not signed by $fingerprint" >&2; exit 1; }

# Print the SHA256 the signed Release file lists for a given index path.
release_sha256() {
  awk -v want="$1" '
    /^SHA256:/ { in_sha = 1; next }
    /^[^ ]/    { in_sha = 0 }
    in_sha && $3 == want { print $1; exit }
  ' "$work/Release"
}

# Print "version filename sha256" for the newest claude-desktop stanza.
latest_stanza() {
  awk '
    /^Package: /  { pkg = $2 }
    /^Version: /  { ver = $2 }
    /^Filename: / { file = $2 }
    /^SHA256: /   { sha = $2 }
    /^$/ { if (pkg == "claude-desktop") print ver, file, sha; pkg = ver = file = sha = "" }
    END  { if (pkg == "claude-desktop") print ver, file, sha }
  ' "$1" | sort -V -k1,1 | tail -n1
}

declare -A ver url hash
for arch in amd64 arm64; do
  index="$component/binary-$arch/Packages"
  fetch "$repo/dists/$suite/$index" "$work/Packages-$arch"

  expected=$(release_sha256 "$index")
  actual=$(sha256sum "$work/Packages-$arch" | cut -d' ' -f1)
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    echo "error: $index sha256 mismatch (Release: ${expected:-missing}, got: $actual)" >&2
    exit 1
  fi

  read -r v file sha < <(latest_stanza "$work/Packages-$arch")
  [ -n "${v:-}" ] || { echo "error: no claude-desktop package for $arch" >&2; exit 1; }
  ver[$arch]=$v
  url[$arch]="$repo/$file"
  hash[$arch]=$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$sha")
done

if [ "${ver[amd64]}" != "${ver[arm64]}" ]; then
  echo "error: amd64 (${ver[amd64]}) and arm64 (${ver[arm64]}) versions differ; not updating" >&2
  exit 1
fi

new=${ver[amd64]}
old=$(jq -r .version "$sources")
if [ "$new" = "$old" ]; then
  echo "claude-desktop is up to date ($old)"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n1)" != "$new" ]; then
  echo "error: upstream latest ($new) is older than current ($old)" >&2
  exit 1
fi

jq -n \
  --arg version "$new" \
  --arg amd64_url "${url[amd64]}" --arg amd64_hash "${hash[amd64]}" \
  --arg arm64_url "${url[arm64]}" --arg arm64_hash "${hash[arm64]}" \
  '{version: $version,
    amd64: {url: $amd64_url, hash: $amd64_hash},
    arm64: {url: $arm64_url, hash: $arm64_hash}}' > "$sources.tmp"
mv "$sources.tmp" "$sources"

echo "claude-desktop: $old -> $new"
