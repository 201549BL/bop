#!/bin/bash
set -euo pipefail

: "${SRCROOT:?}" "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}" "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
helper_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
resource_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
helper="$helper_dir/spotify_player"
license="$resource_dir/SpotifyPlayer-LICENSE.txt"

# Incremental builds may still contain the helper from the Web Player experiment.
/bin/rm -f -- "$helper_dir/bop-arc-spotify" "$resource_dir/spogo-LICENSE.txt"

if [[ ${BOP_BUNDLE_SPOTIFY_PLAYER:-NO} != YES ]]; then
    /bin/rm -f -- "$helper" "$license"
    exit 0
fi

stage_dir="$SRCROOT/.build/spotify-player/staged"
read -r revision _ < "$SRCROOT/Tools/SpotifyPlayer/source.lock"
if ! [[ -x "$stage_dir/spotify_player" && -f "$stage_dir/LICENSE" && -r "$stage_dir/source-revision" &&
        $(<"$stage_dir/source-revision") == "$revision" ]]; then
    printf 'error: Run bash Tools/SpotifyPlayer/build.sh --native (or --stage for a universal build) to stage the required Spotify helper.\n' >&2
    exit 1
fi

if [[ -n ${ARCHS:-} ]]; then
    read -r -a architectures <<< "$ARCHS"
    for architecture in "${architectures[@]}"; do
        if ! /usr/bin/lipo "$stage_dir/spotify_player" -verify_arch "$architecture"; then
            printf 'error: The Spotify helper does not support %s. Stage both architectures for a universal build.\n' "$architecture" >&2
            exit 1
        fi
    done
fi

mkdir -p -- "$helper_dir" "$resource_dir"
/usr/bin/install -m 755 "$stage_dir/spotify_player" "$helper"
/usr/bin/install -m 644 "$stage_dir/LICENSE" "$license"

if [[ ${CODE_SIGNING_ALLOWED:-YES} != NO ]]; then
    identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
    if [[ $identity == - ]]; then
        /usr/bin/codesign --force --sign - "$helper"
    else
        timestamp=--timestamp=none
        if [[ ${CONFIGURATION:-} == Release ]]; then timestamp=--timestamp; fi
        /usr/bin/codesign --force --sign "$identity" --options runtime "$timestamp" "$helper"
    fi
    /usr/bin/codesign --verify --strict "$helper"
fi
