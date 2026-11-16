#!/bin/bash
# Plans a run of the Images workflow: checks every variant of every game image (or only $GAME's) with
# image-inputs.sh and lists the ones whose inputs changed.
# Env: REGISTRY (e.g. ghcr.io/ionnet-dev), GAME (optional game folder), FORCE ("true": build without comparing),
# GITHUB_OUTPUT (gets builds=<matrix JSON> and names=<image names JSON>), GITHUB_STEP_SUMMARY (optional).
# Run from the repository root.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
IMAGE_INPUTS_CACHE="$(mktemp -d)"
export IMAGE_INPUTS_CACHE
trap 'rm -rf "$IMAGE_INPUTS_CACHE"' EXIT

if [[ -n "${GAME:-}" ]]; then
  [[ -f "$GAME/image/image.yml" ]] || { echo "::error::$GAME has no image/image.yml"; exit 1; }
  GAMES=("$GAME")
else
  GAMES=()
  for FILE in ./*/image/image.yml; do
    [[ -f "$FILE" ]] && GAMES+=("$(cut -d / -f 2 <<< "$FILE")")
  done
fi

BUILDS="[]"
SUMMARY="| Image | Result |"$'\n'"| --- | --- |"
for DIR in "${GAMES[@]}"; do
  YML="$DIR/image/image.yml"
  # Every file of image/ except image.yml (its build args are an input of each variant on their own).
  mapfile -d "" FILES < <(cd "$DIR/image" && find . -type f ! -path ./image.yml -print0 | LC_ALL=C sort -z)
  FILES_HASH="$(cd "$DIR/image" && "$SCRIPTS/image-inputs.sh" hash-files "${FILES[@]}")"
  NAME="$(yq -r '.name' "$YML")"
  COUNT="$(yq '.variants | length' "$YML")"
  for ((I = 0; I < COUNT; I++)); do
    TAG="$(yq -r ".variants[$I].tag" "$YML")"
    mapfile -t ARGS < <(yq -r ".variants[$I].args // {} | to_entries | .[] | .key + \"=\" + (.value | tostring)" "$YML")
    OPTIONS=()
    for ARG in "${ARGS[@]}"; do
      OPTIONS+=(--arg "$ARG")
    done
    if [[ "${FORCE:-false}" == "true" ]]; then
      OPTIONS+=(--force)
    fi
    RESULT="$("$SCRIPTS/image-inputs.sh" check --image "$REGISTRY/$NAME:$TAG" --dockerfile "$DIR/image/Dockerfile" --files "$FILES_HASH" "${OPTIONS[@]}")"
    SUMMARY+=$'\n'"| \`$NAME:$TAG\` | $(jq -r '.reason + (if .build then ", building" else ", skipped" end)' <<< "$RESULT") |"
    if [[ "$(jq -r '.build' <<< "$RESULT")" == "true" ]]; then
      BUILDS="$(jq -c --arg dir "$DIR" --arg name "$NAME" --arg tag "$TAG" --arg args "$(printf '%s\n' "${ARGS[@]}")" --argjson result "$RESULT" \
        '. + [{dir: $dir, name: $name, tag: $tag, args: ($args | rtrimstr("\n")), labels: $result.labels}]' <<< "$BUILDS")"
    fi
  done
done

echo "builds=$BUILDS" >> "$GITHUB_OUTPUT"
echo "names=$(jq -c '[.[].name] | unique' <<< "$BUILDS")" >> "$GITHUB_OUTPUT"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
fi
echo "To build: $(jq -r 'if length == 0 then "nothing" else map(.name + ":" + .tag) | join(", ") end' <<< "$BUILDS")"
