#!/usr/bin/env bash
#
# fetch-geolite.sh: download the MaxMind GeoLite2 Country database into the
# user's Application Support directory, where GeoLocator.defaultDatabaseURL()
# finds it. GeoLite2's license forbids redistributing the database, so it is
# fetched on demand with the user's own (free) license key instead of being
# bundled or committed.
#
# Usage: fetch-geolite.sh <license-key>
# Get a free key at https://www.maxmind.com/en/geolite2/signup
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "usage: $0 <maxmind-license-key>" >&2
    exit 2
fi

key="$1"
dest="${MACPERF_GEOLITE_DIR:-$HOME/Library/Application Support/MacPerformanceMonitor}"
url="https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=${key}&suffix=tar.gz"

mkdir -p "$dest"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Downloading GeoLite2-Country..."
curl -fsSL "$url" -o "$work/geolite.tar.gz"

tar -xzf "$work/geolite.tar.gz" -C "$work"
mmdb="$(find "$work" -name 'GeoLite2-Country.mmdb' -type f | head -n 1)"
if [[ -z "$mmdb" ]]; then
    echo "error: archive contained no GeoLite2-Country.mmdb" >&2
    exit 1
fi

mv "$mmdb" "$dest/GeoLite2-Country.mmdb"
echo "Installed $(du -h "$dest/GeoLite2-Country.mmdb" | cut -f1) at $dest/GeoLite2-Country.mmdb"
