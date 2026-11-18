#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
build_dir="$root/.build/spotify-player"
source_dir="$build_dir/sources"
stage_dir="$build_dir/staged"
# v0.25.2 with the upstream fix for the default ncspot OAuth callback (#1115).
read -r revision archive_sha256 < "$root/Tools/SpotifyPlayer/source.lock"
archive="$source_dir/$revision.tar.gz"
source="$source_dir/spotify-player-$revision"

case ${1:-} in
    --stage) targets=(aarch64-apple-darwin x86_64-apple-darwin) ;;
    --native) targets=(native) ;;
    *) printf 'Usage: %s --stage|--native\n' "$0" >&2; exit 1 ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
    printf 'Install Rust and Cargo before building the Spotify helper.\n' >&2
    exit 1
fi

mkdir -p "$source_dir" "$stage_dir"
if [[ ! -f "$archive" ]]; then
    /usr/bin/curl -fLSs "https://codeload.github.com/aome510/spotify-player/tar.gz/$revision" -o "$archive.download"
    printf '%s  %s\n' "$archive_sha256" "$archive.download" | /usr/bin/shasum -a 256 -c -
    /bin/mv "$archive.download" "$archive"
else
    printf '%s  %s\n' "$archive_sha256" "$archive" | /usr/bin/shasum -a 256 -c -
fi
if [[ ! -f "$source/Cargo.lock" ]]; then
    /usr/bin/tar -xzf "$archive" -C "$source_dir"
fi

build=(cargo build --locked --release --package spotify_player --no-default-features --features rustls-tls
    --manifest-path "$source/Cargo.toml" --target-dir "$build_dir/target")
binaries=()
for target in "${targets[@]}"; do
    if [[ "$target" == native ]]; then
        "${build[@]}"
        binaries+=("$build_dir/target/release/spotify_player")
    else
        "${build[@]}" --target "$target"
        binaries+=("$build_dir/target/$target/release/spotify_player")
    fi
done

staged_binary="$stage_dir/spotify_player.new"
if [[ ${#binaries[@]} == 2 ]]; then
    /usr/bin/lipo -create "${binaries[@]}" -output "$staged_binary"
else
    /usr/bin/install -m 755 "${binaries[0]}" "$staged_binary"
fi
/usr/bin/install -m 644 "$source/LICENSE" "$stage_dir/LICENSE"
/bin/mv "$staged_binary" "$stage_dir/spotify_player"
printf '%s\n' "$revision" > "$stage_dir/source-revision"
