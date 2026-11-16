#!/bin/sh
# Install hook for minecraft-java. Runs as uid 1000 in /data.
# In: GSS_VAR_FLAVOUR (vanilla|paper|forge|neoforge), GSS_VAR_VERSION (e.g. 1.21.4 or "latest"),
#     GSS_VAR_FORGE_VERSION / GSS_VAR_NEOFORGE_VERSION (a build from the panel's list, or "recommended").
# Out: the server in the current folder, every download verified against the upstream checksum, and gss-launch.args:
#      the arguments `start` passes to java after the memory flags ("-jar server.jar", or Forge's argument file).
#   vanilla:  piston-meta version manifest → version JSON → downloads.server (url + sha1) → server.jar
#   paper:    fill.papermc.io v3 → latest build of the version → downloads."server:default" (url + sha256) → server.jar
#   forge:    promotions_slim.json ("recommended") → maven.minecraftforge.net installer (+ .sha256) → --installServer
#   neoforge: maven.neoforged.net version list ("recommended") → installer (+ .sha256) → --installServer
# Needs only curl and the POSIX tools; JSON is read with grep/sed so the hook doesn't depend on jq being in the image.
# Prints one line per step.
set -eu

FLAVOUR="${GSS_VAR_FLAVOUR:-paper}"
VERSION="${GSS_VAR_VERSION:-latest}"
FORGE_VERSION="${GSS_VAR_FORGE_VERSION:-recommended}"
NEOFORGE_VERSION="${GSS_VAR_NEOFORGE_VERSION:-recommended}"
MANIFEST_URL="${GSS_MOJANG_MANIFEST_URL:-https://piston-meta.mojang.com/mc/game/version_manifest_v2.json}"
PAPER_API="${GSS_PAPER_API_URL:-https://fill.papermc.io/v3}"
FORGE_MAVEN="${GSS_FORGE_MAVEN_URL:-https://maven.minecraftforge.net}"
FORGE_PROMOTIONS="${GSS_FORGE_PROMOTIONS_URL:-https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json}"
NEOFORGE_MAVEN="${GSS_NEOFORGE_MAVEN_URL:-https://maven.neoforged.net/releases}"
NEOFORGE_API="${GSS_NEOFORGE_API_URL:-https://maven.neoforged.net/api/maven/versions/releases}"
JAR="server.jar"
LAUNCH="gss-launch.args"
INSTALLER="gss-installer.jar"

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

# Refuse anything but the characters versions use: the values end up in URLs and file paths.
check_version() {
  case "$2" in
    "" | *[!0-9A-Za-z._+-]*) die "The $1 \"$2\" is not valid. Pick one from the list, or \"$3\"." ;;
  esac
}

check_version "Minecraft version" "$VERSION" "latest"
check_version "Forge version" "$FORGE_VERSION" "recommended"
check_version "NeoForge version" "$NEOFORGE_VERSION" "recommended"

# Download $1 to file $4 (default $JAR), check it against checksum $3 computed by command $2 (sha1sum or sha256sum).
download() {
  url="$1"
  tool="$2"
  expected="$3"
  target="${4:-$JAR}"
  fetch -o "$target.part" "$url" || die "Downloading $url failed."
  actual="$("$tool" "$target.part" | cut -d ' ' -f 1)"
  if [ "$actual" != "$expected" ]; then
    rm -f "$target.part"
    die "The downloaded jar is corrupt: its checksum is $actual, upstream says $expected."
  fi
  mv -f "$target.part" "$target"
  echo "Saved $target ($(wc -c < "$target") bytes), checksum verified."
}

# What `start` runs after the memory flags: java -XX:... $(cat gss-launch.args) nogui.
write_launch() {
  printf '%s\n' "$*" > "$LAUNCH"
}

# The Minecraft version to install: $VERSION, with "latest" looked up.
resolve_minecraft() {
  if [ "$VERSION" = "latest" ]; then
    version="$(latest_release)"
    [ -n "$version" ] || die "Could not read the latest release from $MANIFEST_URL."
    printf '%s' "$version"
  else
    printf '%s' "$VERSION"
  fi
}

# Escape a version for grep's basic regular expressions: only "." is special there among the characters
# check_version allows ("+" is literal in a BRE).
quote_re() {
  printf '%s' "$1" | sed 's/\./\\./g'
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

# Download the installer at $1 (checked against its .sha256 file), run it with --installServer, and point
# $LAUNCH at what it installed: the argument file of Forge 1.17+ and NeoForge, or the universal jar of older Forge.
# $2 is the installed version as it appears in jar names, $3 the loader's name for messages and $4 the folder below
# libraries/ its own files go to (net/minecraftforge/forge): only its argument file is used, never one another loader
# with the same version number left behind.
run_installer() {
  url="$1"
  full="$2"
  name="$3"
  library="libraries/$4/$full"
  sha256="$(fetch "$url.sha256" 2>/dev/null | cut -c 1-64)" || sha256=""
  case "$sha256" in
    *[!0-9a-f]* | "") die "$name $full has no server installer at $url (very old versions don't)." ;;
  esac
  echo "Downloading the $name $full installer..."
  download "$url" sha256sum "$sha256" "$INSTALLER"
  echo "Running the $name installer (it downloads Minecraft and the libraries; this takes a minute)..."
  if ! java -jar "$INSTALLER" --installServer > gss-installer.log 2>&1; then
    tail -n 20 gss-installer.log >&2
    die "The $name installer failed (full output in gss-installer.log)."
  fi
  rm -f "$INSTALLER" "$INSTALLER.log" gss-installer.log
  # The installer's own launch scripts would start the server with other memory flags than the panel's.
  rm -f run.sh run.bat user_jvm_args.txt
  if [ -f "$library/unix_args.txt" ]; then
    write_launch "@$library/unix_args.txt"
  else
    # Only Forge for Minecraft 1.16 and older installs a runnable jar instead; NeoForge always has the argument file.
    jar=""
    for candidate in "forge-$full-shim.jar" "forge-$full.jar" "forge-$full-universal.jar"; do
      if [ "$name" = "Forge" ] && [ -f "$candidate" ]; then
        jar="$candidate"
        break
      fi
    done
    [ -n "$jar" ] || die "The $name installer finished, but left neither an argument file nor a server jar to start."
    write_launch "-jar $jar"
  fi
  echo "Installed $name $full; it starts with $(cat "$LAUNCH")."
}

install_forge() {
  minecraft="$(resolve_minecraft)"
  build="$FORGE_VERSION"
  if [ "$build" = "recommended" ] || [ "$build" = "latest" ]; then
    echo "Looking up Forge's recommended build for Minecraft $minecraft..."
    promotions="$(fetch "$FORGE_PROMOTIONS")" || die "Could not read Forge's builds from $FORGE_PROMOTIONS."
    pick() {
      printf '%s' "$promotions" | grep -o "\"$(quote_re "$1")-$2\" *: *\"[^\"]*\"" | head -n 1 | sed 's/.*: *"//; s/"$//'
    }
    if [ "$VERSION" = "latest" ] && [ -z "$(pick "$minecraft" latest)" ]; then
      # Forge may not have the newest release yet: fall back to the newest version it has.
      newest="$(printf '%s' "$promotions" | grep -o '"[0-9][0-9A-Za-z._-]*-latest"' | tr -d '"' | sed 's/-latest$//' | sort -V | tail -n 1)"
      [ -n "$newest" ] || die "Could not read Forge's builds from $FORGE_PROMOTIONS."
      echo "Forge has no build for $minecraft yet, using its newest version $newest instead."
      minecraft="$newest"
    fi
    found="$(pick "$minecraft" recommended)"
    [ -n "$found" ] || found="$(pick "$minecraft" latest)"
    [ -n "$found" ] || die "Forge has no build for Minecraft $minecraft. Pick another Minecraft version."
    # Old builds carry a suffix in their full version (1.7.10-10.13.4.1614-1.7.10): take it from the maven list.
    full="$(fetch "$FORGE_MAVEN/api/maven/versions/releases/net/minecraftforge/forge" | grep -o "\"$(quote_re "$minecraft-$found")\(-[^\"]*\)\?\"" | head -n 1 | tr -d '"')" || full=""
    [ -n "$full" ] || full="$minecraft-$found"
  else
    # The panel's list holds full versions (1.21.4-54.1.0); they start with the Minecraft version they are for.
    full="$build"
    if [ "$VERSION" != "latest" ]; then
      case "$full" in
        "$minecraft"-*) ;;
        *) die "Forge $full isn't for Minecraft $minecraft. Pick a Forge version from the list again." ;;
      esac
    fi
  fi
  run_installer "$FORGE_MAVEN/net/minecraftforge/forge/$full/forge-$full-installer.jar" "$full" "Forge" "net/minecraftforge/forge"
}

# The start of the NeoForge versions for Minecraft $1: 1.21.1 → "21.1.", 1.21 → "21.0.", 26.1 → "26.1.0.",
# 26.1.2 → "26.1.2.". Minecraft 1.20.1 has its own artifact (net.neoforged:forge, "1.20.1-47.1.x").
neoforge_prefix() {
  case "$1" in
    1.20.1) printf '1.20.1-' ;;
    1.*.*) printf '%s.' "${1#1.}" ;;
    1.*) printf '%s.0.' "${1#1.}" ;;
    *.*.*) printf '%s.' "$1" ;;
    *) printf '%s.0.' "$1" ;;
  esac
}

install_neoforge() {
  minecraft="$(resolve_minecraft)"
  build="$NEOFORGE_VERSION"
  # One version per line. Fails when the list can't be fetched (a pipeline would only report its last command).
  list() {
    answer="$(fetch "$NEOFORGE_API/net/neoforged/$1")" || return 1
    printf '%s' "$answer" | sed 's/^[^[]*\[//' | grep -o '"[^"]*"' | tr -d '"'
  }
  if [ "$build" = "recommended" ] || [ "$build" = "latest" ]; then
    echo "Looking up NeoForge's newest stable build for Minecraft $minecraft..."
    artifact="neoforge"
    [ "$minecraft" = "1.20.1" ] && artifact="forge"
    versions="$(list "$artifact")" || die "Could not read NeoForge's versions from $NEOFORGE_API."
    prefix="$(quote_re "$(neoforge_prefix "$minecraft")")"
    matching="$(printf '%s\n' "$versions" | grep "^$prefix[0-9]" || true)"
    if [ -z "$matching" ] && [ "$VERSION" = "latest" ] && [ "$artifact" = "neoforge" ]; then
      # NeoForge may not have the newest release yet: fall back to its newest version.
      matching="$(printf '%s\n' "$versions" | grep '^[0-9]' | grep -v -- '-alpha\|+' || true)"
      echo "NeoForge has no build for $minecraft yet, using its newest version instead."
    fi
    [ -n "$matching" ] || die "NeoForge has no build for Minecraft $minecraft. Pick another Minecraft version."
    # Stable builds have no suffix; a version with only betas gets its newest beta.
    stable="$(printf '%s\n' "$matching" | grep -v -- '-' || true)"
    full="$(printf '%s\n' "${stable:-$matching}" | sort -V | tail -n 1)"
  else
    # The panel's list (Prism Launcher's index) names the 1.20.1 builds without their prefix: 47.1.106.
    full="$build"
    case "$full" in
      47.*) full="1.20.1-$full" ;;
    esac
    artifact="neoforge"
    case "$full" in
      1.20.1-*) artifact="forge" ;;
    esac
    if [ "$VERSION" != "latest" ]; then
      case "$full" in
        "$(neoforge_prefix "$minecraft")"*) ;;
        *) die "NeoForge $build isn't for Minecraft $minecraft. Pick a NeoForge version from the list again." ;;
      esac
    fi
  fi
  run_installer "$NEOFORGE_MAVEN/net/neoforged/$artifact/$full/$artifact-$full-installer.jar" "$full" "NeoForge" "net/neoforged/$artifact"
}

case "$FLAVOUR" in
  vanilla) install_vanilla ;;
  paper) install_paper ;;
  forge) install_forge ;;
  neoforge) install_neoforge ;;
  *) die "Unknown server software \"$FLAVOUR\". Use vanilla, paper, forge or neoforge." ;;
esac
if [ "$FLAVOUR" = "vanilla" ] || [ "$FLAVOUR" = "paper" ]; then
  write_launch "-jar $JAR"
fi
