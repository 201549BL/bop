#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
    printf 'Usage: bash Tools/SpotifyPlayer/check-build-paths.sh <spotify_player> [required architecture ...]\n' >&2
    exit 1
fi

helper=$1
shift
if ! architectures=$(/usr/bin/lipo "$helper" -archs 2>/dev/null); then
    printf 'error: Could not read the Mach-O architectures of the Spotify helper.\n' >&2
    exit 1
fi
read -r -a architectures <<< "$architectures"
for required_architecture in "$@"; do
    if ! /usr/bin/lipo "$helper" -verify_arch "$required_architecture" 2>/dev/null; then
        printf 'error: The Spotify helper is missing a required architecture.\n' >&2
        exit 1
    fi
done

slice_dir=$(mktemp -d -t bop-helper-paths)
trap '/bin/rm -rf -- "$slice_dir"' EXIT
status=0
for architecture in "${architectures[@]}"; do
    slice=$helper
    if [[ ${#architectures[@]} -gt 1 ]]; then
        slice="$slice_dir/slice"
        if ! /usr/bin/lipo "$helper" -thin "$architecture" -output "$slice" 2>/dev/null; then
            printf 'error: Could not extract the Spotify helper %s slice.\n' "$architecture" >&2
            exit 1
        fi
    fi
    if LC_ALL=C /usr/bin/grep -aEq '/(Users|home|var/folders)/' "$slice" 2>/dev/null; then
        printf 'error: The Spotify helper %s slice contains a local build path.\n' "$architecture" >&2
        status=1
    elif [[ $? -ne 1 ]]; then
        printf 'error: Could not scan the Spotify helper %s slice.\n' "$architecture" >&2
        exit 1
    fi
done
exit "$status"
