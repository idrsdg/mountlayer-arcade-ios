#!/bin/sh
# Copies the whole web arcade into the app bundle folder. three.js for Morning Chain is bundled so nothing comes from a CDN.
set -e
SRC="${1:-$HOME/Desktop/Oyunlar/LaunchAnything}"
DST="$(dirname "$0")/App/Web"
rm -rf "$DST"; mkdir -p "$DST"
for d in games prism space breakout race football words sabah dortiklim emberbloom; do cp -R "$SRC/$d" "$DST/$d"; done
find "$DST" -name "*.md" -delete
[ -f "$(dirname "$0")/vendor/three-r128.min.js" ] || { mkdir -p "$(dirname "$0")/vendor"; curl -sL -o "$(dirname "$0")/vendor/three-r128.min.js" https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js; }
cp "$(dirname "$0")/vendor/three-r128.min.js" "$DST/sabah/three.min.js"
sed -i '' 's|https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js|three.min.js|' "$DST/sabah/index.html"
cp "$(dirname "$0")/vendor/three-r128.min.js" "$DST/emberbloom/three.min.js"
sed -i '' 's|https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js|three.min.js|' "$DST/emberbloom/index.html"
echo "web arcade copied to $DST"
