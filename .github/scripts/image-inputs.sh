#!/bin/bash
#####################################
# Ionnet GSS image inputs           #
#####################################
# Works out what an image is built from and whether the published image was built from exactly that, so CI only
# rebuilds (and hosts only re-download) an image whose inputs changed.
# The same file is in ionnet-gss and ionnet-gss-games (.github/scripts/image-inputs.sh). Keep both copies identical.
#
#   image-inputs.sh hash-files FILE...
#     Prints one sha256 over the files' paths (as given) and contents.
#   image-inputs.sh check --image REF --dockerfile FILE --files HASH [--arg KEY=value]... [--force]
#     Resolves every image FILE builds FROM to its linux/amd64 digest (global ARG defaults and the --arg values filled
#     in), hashes those with HASH and the args, and compares the result with the labels of the published REF.
#     Prints {"build": bool, "reason": "...", "inputs": "<sha256>", "labels": "key=value\n..."} on stdout and one line
#     for people on stderr. The labels go on the new image so the next check can compare against it.
#
# Registries are read anonymously, so only public images work. Needs bash 4.4+, curl, jq and sha256sum.
# IMAGE_INPUTS_CACHE: a folder to keep registry tokens in across calls (default: a temporary one per call).
set -euo pipefail

LABEL="dev.ionnet.gss.inputs"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json"
CACHE="${IMAGE_INPUTS_CACHE:-}"
if [[ -z "$CACHE" ]]; then
  CACHE="$(mktemp -d)"
  trap 'rm -rf "$CACHE"' EXIT
fi

fail() {
  echo "::error::$*" >&2
  exit 1
}

# Splits reference $1 into HOST, REPO and TAG (the caller's variables). Docker Hub is the default registry, a digest
# reference keeps its digest as TAG.
split_ref() {
  local REF="${1%%@*}" FIRST="${1%%/*}"
  if [[ "$REF" == */* && ( "$FIRST" == *.* || "$FIRST" == *:* || "$FIRST" == localhost ) ]]; then
    HOST="$FIRST"
    REPO="${REF#*/}"
  else
    HOST="registry-1.docker.io"
    REPO="$REF"
    [[ "$REPO" == */* ]] || REPO="library/$REPO"
  fi
  TAG="latest"
  if [[ "${REPO##*/}" == *:* ]]; then
    TAG="${REPO##*:}"
    REPO="${REPO%:*}"
  fi
  if [[ "$1" == *@* ]]; then
    TAG="${1#*@}"
  fi
}

# Prints the URL scheme for registry $1: plain http only for a local test registry (localhost:<port>).
scheme() {
  if [[ "$1" == localhost:* ]]; then
    echo "http"
  else
    echo "https"
  fi
}

# Prints an anonymous pull token for repository $2 on registry $1 (empty when the registry gives none).
token() {
  local FILE="$CACHE/token-${1//[^A-Za-z0-9.-]/_}-${2//[^A-Za-z0-9.-]/_}" CHALLENGE REALM SERVICE
  if [[ ! -f "$FILE" ]]; then
    # Example: www-authenticate: Bearer realm="https://ghcr.io/token",service="ghcr.io",scope="repository:user/image:pull"
    CHALLENGE="$(curl -sS --retry 3 --retry-all-errors --retry-delay 1 -o /dev/null -D - "$(scheme "$1")://$1/v2/" 2>/dev/null | tr -d '\r' | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *[Bb]earer //p' || true)"
    REALM="$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<< "$CHALLENGE")"
    SERVICE="$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<< "$CHALLENGE")"
    if [[ -n "$REALM" ]]; then
      { curl -sS --retry 3 --retry-all-errors --retry-delay 1 -G "$REALM" --data-urlencode "service=$SERVICE" --data-urlencode "scope=repository:$2:pull" | jq -r '.token // .access_token // ""'; } > "$FILE" 2>/dev/null || : > "$FILE"
    else
      : > "$FILE"
    fi
  fi
  cat "$FILE"
}

# GETs <scheme>://$1/v2/$2/$3 into file $4 (following blob redirects) and prints the HTTP status (000: no connection).
get() {
  local TOKEN HEADERS=(-H "Accept: $ACCEPT")
  TOKEN="$(token "$1" "$2")"
  if [[ -n "$TOKEN" ]]; then
    HEADERS+=(-H "Authorization: Bearer $TOKEN")
  fi
  curl -sSL --retry 3 --retry-all-errors --retry-delay 1 -o "$4" -w '%{http_code}' "${HEADERS[@]}" "$(scheme "$1")://$1/v2/$2/$3" 2>/dev/null || true
}

# Prints the digest of reference $1's linux/amd64 image manifest and keeps that manifest as $CACHE/<hex>.json.
# Prints nothing when the image doesn't exist or isn't public; stops on any other registry error.
resolve() {
  local HOST REPO TAG OUT="$CACHE/manifest.$BASHPID" CODE DIGEST
  split_ref "$1"
  CODE="$(get "$HOST" "$REPO" "manifests/$TAG" "$OUT")"
  case "$CODE" in
    200) ;;
    401|403|404) return 0 ;;
    *) fail "Could not read $1 from $HOST (HTTP $CODE)." ;;
  esac
  if jq -e 'has("manifests")' "$OUT" > /dev/null; then # An index: one manifest per platform
    DIGEST="$(jq -r 'first(.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest) // empty' "$OUT")"
    [[ -n "$DIGEST" ]] || fail "$1 has no linux/amd64 image."
    CODE="$(get "$HOST" "$REPO" "manifests/$DIGEST" "$OUT")"
    [[ "$CODE" == "200" ]] || fail "Could not read the linux/amd64 manifest of $1 (HTTP $CODE)."
  else # A single-platform image
    DIGEST="sha256:$(sha256sum "$OUT" | cut -d " " -f 1)"
  fi
  mv "$OUT" "$CACHE/${DIGEST#sha256:}.json"
  echo "$DIGEST"
}

# Prints the labels of the published image $1 as a JSON object, or nothing when it isn't published (or isn't public).
published_labels() {
  local HOST REPO TAG DIGEST CONFIG OUT="$CACHE/config.$BASHPID" CODE
  DIGEST="$(resolve "$1")"
  [[ -n "$DIGEST" ]] || return 0
  split_ref "$1"
  CONFIG="$(jq -r '.config.digest' "$CACHE/${DIGEST#sha256:}.json")"
  CODE="$(get "$HOST" "$REPO" "blobs/$CONFIG" "$OUT")"
  [[ "$CODE" == "200" ]] || fail "Could not read the config of $1 (HTTP $CODE)."
  jq -c '.config.Labels // {}' "$OUT"
}

# Fills ${NAME}, ${NAME:-default} and $NAME in $1 from VARS (the caller's associative array).
expand() {
  local TEXT="$1" OUT="" NAME VALUE
  # shellcheck disable=SC2016 # A regular expression, not shell.
  local PATTERN='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
  while [[ "$TEXT" =~ $PATTERN ]]; do
    NAME="${BASH_REMATCH[3]:-${BASH_REMATCH[6]}}"
    VALUE="${VARS[$NAME]:-}"
    if [[ -z "$VALUE" && -n "${BASH_REMATCH[4]}" ]]; then
      VALUE="${BASH_REMATCH[5]}"
    fi
    OUT+="${BASH_REMATCH[1]}$VALUE"
    TEXT="${BASH_REMATCH[7]}"
  done
  echo "$OUT$TEXT"
}

# Prints the images Dockerfile $1 builds FROM, one per line, with the global ARG defaults and the build args (the
# other arguments, KEY=value) filled in. Earlier stages and scratch are left out.
from_refs() {
  local FILE="$1" LINE WORD NAME VALUE IMAGE STAGE SEEN_FROM=0 I
  local -a WORDS
  local -A GIVEN=() VARS=() STAGES=()
  shift
  for WORD in "$@"; do
    GIVEN["${WORD%%=*}"]="${WORD#*=}"
  done
  while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    read -r -a WORDS <<< "$LINE"
    [[ ${#WORDS[@]} -gt 0 ]] || continue
    case "${WORDS[0],,}" in
      arg) # Only ARGs before the first FROM apply to FROM lines.
        [[ "$SEEN_FROM" == 0 ]] || continue
        for WORD in "${WORDS[@]:1}"; do
          NAME="${WORD%%=*}"
          if [[ -n "${GIVEN[$NAME]+set}" ]]; then
            VARS[$NAME]="${GIVEN[$NAME]}"
          elif [[ "$WORD" == *=* ]]; then
            VALUE="${WORD#*=}"
            VALUE="${VALUE#\"}"
            VARS[$NAME]="${VALUE%\"}"
          fi
        done
        ;;
      from) # FROM [--platform=…] image [AS name]
        SEEN_FROM=1
        IMAGE=""
        STAGE=""
        for ((I = 1; I < ${#WORDS[@]}; I++)); do
          if [[ -z "$IMAGE" && "${WORDS[I]}" != --* ]]; then
            IMAGE="${WORDS[I]}"
          elif [[ -n "$IMAGE" && "${WORDS[I],,}" == "as" ]]; then
            STAGE="${WORDS[I + 1]:-}"
            break
          fi
        done
        IMAGE="$(expand "$IMAGE")"
        if [[ -n "$IMAGE" && "${IMAGE,,}" != "scratch" && -z "${STAGES[$IMAGE]+set}" ]]; then
          echo "$IMAGE"
        fi
        if [[ -n "$STAGE" ]]; then
          STAGES[$STAGE]=1
        fi
        ;;
    esac
  done < "$FILE"
}

# Prints one sha256 over the paths and contents of the files given.
hash_files() {
  local FILE
  for FILE in "$@"; do
    [[ -f "$FILE" ]] || fail "$FILE is not a file."
    printf '%s %s\n' "$(sha256sum < "$FILE" | cut -d " " -f 1)" "$FILE"
  done | LC_ALL=C sort -k 2 | sha256sum | cut -d " " -f 1
}

# Compares the inputs of an image with the published image's labels (see the usage at the top).
check() {
  local IMAGE="" DOCKERFILE="" FILES="" FORCE=0 REF DIGEST FROM="" ARGLINE INPUTS LABELS PUBLISHED BUILD=true REASON
  local -a ARGS=() CHANGES=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) IMAGE="$2"; shift 2 ;;
      --dockerfile) DOCKERFILE="$2"; shift 2 ;;
      --files) FILES="$2"; shift 2 ;;
      --arg) ARGS+=("$2"); shift 2 ;;
      --force) FORCE=1; shift ;;
      *) fail "Unknown option $1. Use --image, --dockerfile, --files, --arg or --force." ;;
    esac
  done
  [[ -n "$IMAGE" && -f "$DOCKERFILE" && -n "$FILES" ]] || fail "check needs --image, --dockerfile (an existing file) and --files."

  # The inputs: the files, the build args, and the exact image behind every FROM.
  ARGLINE="$(printf '%s\n' "${ARGS[@]}" | LC_ALL=C sort | paste -sd " " -)"
  while IFS= read -r REF; do
    DIGEST="$(resolve "$REF")"
    [[ -n "$DIGEST" ]] || fail "$REF (a FROM image of $DOCKERFILE) was not found, or is not public."
    FROM+="${FROM:+ }$REF@$DIGEST"
  done < <(from_refs "$DOCKERFILE" "${ARGS[@]}")
  [[ -n "$FROM" ]] || fail "$DOCKERFILE has no FROM image."
  INPUTS="$(printf 'files %s\nargs %s\nfrom %s\n' "$FILES" "$ARGLINE" "$FROM" | sha256sum | cut -d " " -f 1)"
  LABELS="$(printf '%s=%s\n%s.files=%s\n%s.args=%s\n%s.from=%s' "$LABEL" "$INPUTS" "$LABEL" "$FILES" "$LABEL" "$ARGLINE" "$LABEL" "$FROM")"

  PUBLISHED="$(published_labels "$IMAGE")"
  if [[ "$FORCE" == 1 ]]; then
    REASON="forced"
  elif [[ -z "$PUBLISHED" ]]; then
    REASON="not published yet"
  elif [[ "$(jq -r --arg key "$LABEL" '.[$key] // ""' <<< "$PUBLISHED")" == "$INPUTS" ]]; then
    BUILD=false
    REASON="unchanged (inputs ${INPUTS:0:12})"
  elif [[ "$(jq -r --arg key "$LABEL" '.[$key] // ""' <<< "$PUBLISHED")" == "" ]]; then
    REASON="the published image has no inputs label yet"
  else # Name what changed.
    [[ "$(jq -r --arg key "$LABEL.files" '.[$key] // ""' <<< "$PUBLISHED")" == "$FILES" ]] || CHANGES+=("files")
    [[ "$(jq -r --arg key "$LABEL.args" '.[$key] // ""' <<< "$PUBLISHED")" == "$ARGLINE" ]] || CHANGES+=("args")
    local OLD_FROM
    OLD_FROM=" $(jq -r --arg key "$LABEL.from" '.[$key] // ""' <<< "$PUBLISHED") "
    for REF in $FROM; do
      if [[ "$OLD_FROM" != *" $REF "* ]]; then
        if [[ "$OLD_FROM" == *" ${REF%@*}@"* ]]; then
          CHANGES+=("${REF%@*} (new digest)")
        else
          CHANGES+=("${REF%@*} (new FROM image)")
        fi
      fi
    done
    (( ${#CHANGES[@]} )) || CHANGES+=("FROM images")
    REASON="inputs changed: $(printf '%s, ' "${CHANGES[@]}")"
    REASON="${REASON%, }"
  fi
  if [[ "$BUILD" == true ]]; then
    echo "$IMAGE: $REASON, building" >&2
  else
    echo "$IMAGE: $REASON, skipped" >&2
  fi
  jq -nc --argjson build "$BUILD" --arg reason "$REASON" --arg inputs "$INPUTS" --arg labels "$LABELS" \
    '{build: $build, reason: $reason, inputs: $inputs, labels: $labels}'
}

case "${1:-}" in
  hash-files) shift; hash_files "$@" ;;
  check) shift; check "$@" ;;
  *) echo "Command not found: ${1:-}. Use hash-files FILE... or check --image REF --dockerfile FILE --files HASH [--arg KEY=value]... [--force]." >&2; exit 2 ;;
esac
