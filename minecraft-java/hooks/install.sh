#!/bin/sh
# Install hook for minecraft-java. Runs as uid 1000 in /data.
# In: GSS_VAR_FLAVOUR (vanilla|paper), GSS_VAR_VERSION (e.g. 1.21.4 or "latest").
# Out: ./server.jar in the current folder, verified against the upstream checksum.
#   vanilla: piston-meta version manifest → version JSON → downloads.server (url + sha1)
#   paper:   fill.papermc.io v3 → latest build of the version → downloads."server:default" (url + sha256)
# Needs only curl and the POSIX tools; JSON is read with grep/sed because the images carry no jq.
# Prints one line per step.
set -eu

FLAVOUR="${GSS_VAR_FLAVOUR:-paper}"
VERSION="${GSS_VAR_VERSION:-latest}"
MANIFEST_URL="${GSS_MOJANG_MANIFEST_URL:-https://piston-meta.mojang.com/mc/game/version_manifest_v2.json}"
PAPER_API="${GSS_PAPER_API_URL:-https://fill.papermc.io/v3}"
JAR="server.jar"

die() {
  echo "$*" >&2
  exit 1
}

fetch() {
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 "$@"
}

# The first string value of "$1" in the JSON on stdin (either `"k":"v"` or `"k": "v"` spacing).
json_string() {
  grep -o "\"$1\" *: *\"[^\"]*\"" | head -n 1 | sed 's/^[^:]*: *"//; s/"$//'
}

case "$VERSION" in
  "" | *[!0-9A-Za-z._-]*) die "The Minecraft version \"$VERSION\" is not valid. Use a release like 1.21.4, or \"latest\"." ;;
esac

# Download $1 to $JAR, check it against checksum $3 computed by command $2 (sha1sum or sha256sum).
download() {
  url="$1"
  tool="$2"
  expected="$3"
  fetch -o "$JAR.part" "$url" || die "Downloading $url failed."
  actual="$("$tool" "$JAR.part" | cut -d ' ' -f 1)"
  if [ "$actual" != "$expected" ]; then
    rm -f "$JAR.part"
    die "The downloaded jar is corrupt: its checksum is $actual, upstream says $expected."
  fi
  mv -f "$JAR.part" "$JAR"
  echo "Saved $JAR ($(wc -c < "$JAR") bytes), checksum verified."
}

latest_release() {
  echo "Looking up the latest Minecraft release..." >&2
  fetch "$MANIFEST_URL" | grep -o '"latest" *: *{[^}]*}' | json_string release
}

install_vanilla() {
  version="$VERSION"
  if [ "$version" = "latest" ]; then
    version="$(latest_release)"
    [ -n "$version" ] || die "Could not read the latest release from $MANIFEST_URL."
  fi
  echo "Resolving vanilla $version..."
  # Every manifest entry holds one version: {"id": "1.21.4", "type": "release", "url": "...", ...}.
  entry_url="$(fetch "$MANIFEST_URL" | grep -o "{\"id\" *: *\"$(printf '%s' "$version" | sed 's/\./\\./g')\", *\"type\" *: *\"[a-z_]*\", *\"url\" *: *\"[^\"]*\"" | head -n 1 | sed 's/.*"url" *: *"//; s/"$//')"
  [ -n "$entry_url" ] || die "Mojang has no Minecraft version \"$version\". Use a release like 1.21.4, or \"latest\"."
  server="$(fetch "$entry_url" | grep -o '"server" *: *{[^}]*}')"
  jar_url="$(printf '%s' "$server" | json_string url)"
  sha1="$(printf '%s' "$server" | json_string sha1)"
  [ -n "$jar_url" ] && [ -n "$sha1" ] || die "Minecraft $version has no server download (very old versions don't)."
  echo "Downloading vanilla $version server jar..."
  download "$jar_url" sha1sum "$sha1"
}

install_paper() {
  version="$VERSION"
  if [ "$version" = "latest" ]; then
    version="$(latest_release)"
    [ -n "$version" ] || die "Could not read the latest release from $MANIFEST_URL."
    # Paper may not have the newest release yet: fall back to the newest version it has.
    if ! fetch -o /dev/null "$PAPER_API/projects/paper/versions/$version/builds/latest" 2>/dev/null; then
      echo "Paper has no build for $version yet, using its newest version instead."
      version="$(fetch "$PAPER_API/projects/paper" | sed 's/^[^[]*\[//' | grep -o '"[0-9][0-9.]*"' | head -n 1 | tr -d '"')"
      [ -n "$version" ] || die "Could not read Paper's version list from $PAPER_API."
    fi
  fi
  echo "Resolving latest Paper build for $version..."
  build="$(fetch "$PAPER_API/projects/paper/versions/$version/builds/latest")" || die "Paper has no build for Minecraft \"$version\". Use a release like 1.21.4, or \"latest\"."
  download_block="$(printf '%s' "$build" | grep -o '"server:default" *: *{.*' | head -n 1)"
  name="$(printf '%s' "$download_block" | json_string name)"
  sha256="$(printf '%s' "$download_block" | json_string sha256)"
  jar_url="$(printf '%s' "$download_block" | json_string url)"
  [ -n "$name" ] && [ -n "$sha256" ] && [ -n "$jar_url" ] || die "Paper's answer for $version has no server download."
  echo "Downloading $name..."
  download "$jar_url" sha256sum "$sha256"
}

case "$FLAVOUR" in
  vanilla) install_vanilla ;;
  paper) install_paper ;;
  *) die "Unknown server software \"$FLAVOUR\". Use vanilla or paper." ;;
esac
