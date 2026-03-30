#!/bin/bash
set -euo pipefail

# Usage: generate-appcast.sh <dmg_path> <private_key> <tag> <output_path>
DMG_PATH="$1"
PRIVATE_KEY="$2"
TAG="$3"
OUTPUT="$4"

SPARKLE_BIN=$(find build/DerivedData -name "sign_update" -path "*/artifacts/*" 2>/dev/null | head -1)
echo "sign_update path: $SPARKLE_BIN"

if [ -z "$SPARKLE_BIN" ]; then
  echo "ERROR: sign_update not found"
  exit 1
fi

SIGN_OUTPUT=$("$SPARKLE_BIN" "$DMG_PATH" -s "$PRIVATE_KEY")
echo "sign_update output: $SIGN_OUTPUT"
SIGNATURE=$(echo "$SIGN_OUTPUT" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
echo "Signature: $SIGNATURE"

if [ -z "$SIGNATURE" ]; then
  echo "ERROR: Failed to generate signature"
  exit 1
fi

DMG_SIZE=$(wc -c < "$DMG_PATH" | tr -d ' ')
VERSION="${TAG#v}"
PUBDATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
DOWNLOAD_URL="https://github.com/sotthang/so-agentbar/releases/download/${TAG}/so-agentbar.dmg"

printf '<?xml version="1.0" encoding="utf-8"?>\n' > "$OUTPUT"
printf '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n' >> "$OUTPUT"
printf '  <channel>\n' >> "$OUTPUT"
printf '    <title>so-agentbar</title>\n' >> "$OUTPUT"
printf '    <link>https://sotthang.github.io/so-agentbar/appcast.xml</link>\n' >> "$OUTPUT"
printf '    <item>\n' >> "$OUTPUT"
printf '      <title>Version %s</title>\n' "$VERSION" >> "$OUTPUT"
printf '      <pubDate>%s</pubDate>\n' "$PUBDATE" >> "$OUTPUT"
printf '      <sparkle:version>%s</sparkle:version>\n' "$VERSION" >> "$OUTPUT"
printf '      <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$VERSION" >> "$OUTPUT"
printf '      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>\n' >> "$OUTPUT"
printf '      <enclosure\n' >> "$OUTPUT"
printf '        url="%s"\n' "$DOWNLOAD_URL" >> "$OUTPUT"
printf '        sparkle:edSignature="%s"\n' "$SIGNATURE" >> "$OUTPUT"
printf '        length="%s"\n' "$DMG_SIZE" >> "$OUTPUT"
printf '        type="application/x-apple-diskimage"\n' >> "$OUTPUT"
printf '      />\n' >> "$OUTPUT"
printf '    </item>\n' >> "$OUTPUT"
printf '  </channel>\n' >> "$OUTPUT"
printf '</rss>\n' >> "$OUTPUT"

echo "appcast.xml written to $OUTPUT"
cat "$OUTPUT"
