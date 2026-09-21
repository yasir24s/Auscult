#!/bin/bash
# Generate every app-icon asset for both targets from one vector source.
#
# The mark is a pulse trace with radiating "listening" arcs -- auscultation,
# which is what the project is named after. Two variants share it:
#   host  = trace on a dark field; the trace itself is the sound source
#   agent = trace running through a device on a light field; the device is
#           the thing being listened to
#
# iOS and macOS icons have opposite geometry rules, which is why $VARIANT
# exists at all:
#   iOS   -- full bleed, NO rounded corners (the system masks), NO alpha
#            channel (App Store validation rejects it outright)
#   macOS -- nothing is masked, so the squircle and its ~10% margin have to
#            be drawn here or the icon looks oversized in the Dock
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/Icons"
mkdir -p "$OUT"
command -v rsvg-convert >/dev/null || { echo "need rsvg-convert: brew install librsvg" >&2; exit 1; }

# --- vector source -----------------------------------------------------------
emit_svg () {  # $1 = host|agent   $2 = ios|macos
  local kind="$1" platform="$2"
  local clip
  if [ "$platform" = "macos" ]; then
    clip='<rect x="100" y="100" width="824" height="824" rx="185" ry="185"/>'
  else
    clip='<rect x="0" y="0" width="1024" height="1024"/>'
  fi

  local grad body
  if [ "$kind" = "host" ]; then
    grad='<stop offset="0" stop-color="#0B2038"/><stop offset="0.55" stop-color="#0D5C74"/><stop offset="1" stop-color="#0FA3A8"/>'
    body='
    <g fill="none" stroke="#8FF5DC" stroke-linecap="round">
      <circle cx="512" cy="512" r="150" stroke-width="16" opacity="0.13"/>
      <circle cx="512" cy="512" r="250" stroke-width="16" opacity="0.10"/>
      <circle cx="512" cy="512" r="350" stroke-width="16" opacity="0.07"/>
    </g>
    <path d="M 128 512 H 318 l 46 -40 l 40 80 l 58 -224 l 74 372 l 54 -188 l 40 0 H 896"
          fill="none" stroke="url(#pulse)" stroke-width="46"
          stroke-linecap="round" stroke-linejoin="round"/>'
  else
    grad='<stop offset="0" stop-color="#5EF2C4"/><stop offset="0.55" stop-color="#1FBFA8"/><stop offset="1" stop-color="#0D7C8C"/>'
    body='
    <g fill="none" stroke="#04303A" stroke-linecap="round">
      <circle cx="512" cy="512" r="290" stroke-width="18" opacity="0.13"/>
      <circle cx="512" cy="512" r="380" stroke-width="18" opacity="0.09"/>
    </g>
    <rect x="330" y="182" width="364" height="660" rx="74" ry="74" fill="#0B2038"/>
    <rect x="330" y="182" width="364" height="660" rx="74" ry="74"
          fill="none" stroke="#7BF7D0" stroke-width="10" opacity="0.30"/>
    <rect x="462" y="228" width="100" height="18" rx="9" fill="#5EF2C4" opacity="0.35"/>
    <path d="M 96 512 H 300 l 44 -38 l 38 76 l 56 -212 l 70 352 l 52 -178 l 38 0 H 928"
          fill="none" stroke="url(#pulse)" stroke-width="44"
          stroke-linecap="round" stroke-linejoin="round"/>'
  fi

  cat <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">$grad</linearGradient>
    <linearGradient id="pulse" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#7BF7D0"/><stop offset="0.5" stop-color="#5EF2C4"/><stop offset="1" stop-color="#A8FBE4"/>
    </linearGradient>
    <clipPath id="field">$clip</clipPath>
  </defs>
  <g clip-path="url(#field)">
    <rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>$body
  </g>
</svg>
SVG
}

# --- alpha stripping ---------------------------------------------------------
# App Store validation rejects an app icon that merely *has* an alpha channel,
# even one that is opaque everywhere. rsvg-convert always writes RGBA, and
# neither sips nor iconutil can drop the channel. Redrawing through a
# CGBitmapContext with noneSkipLast makes ImageIO emit a 24-bit PNG.
strip_alpha () {
  /usr/bin/swift - "$1" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!); exit(1)
}
let w = img.width, h = img.height
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    FileHandle.standardError.write("cannot make context\n".data(using: .utf8)!); exit(1)
}
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
guard let flat = ctx.makeImage(),
      let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write("cannot write \(path)\n".data(using: .utf8)!); exit(1)
}
CGImageDestinationAddImage(dst, flat, nil)
guard CGImageDestinationFinalize(dst) else {
    FileHandle.standardError.write("finalize failed\n".data(using: .utf8)!); exit(1)
}
SWIFT
}

# --- iOS agent: asset catalog ------------------------------------------------
ICONSET="$ROOT/Agent/AuscultAgent/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET"
emit_svg agent ios > "$OUT/agent-ios.svg"
rsvg-convert -w 1024 -h 1024 "$OUT/agent-ios.svg" -o "$ICONSET/icon-1024.png"
strip_alpha "$ICONSET/icon-1024.png"
cat > "$ICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$ROOT/Agent/AuscultAgent/Assets.xcassets/Contents.json" <<'JSON'
{ "info" : { "author" : "xcode", "version" : 1 } }
JSON

# --- macOS host: .icns -------------------------------------------------------
emit_svg host macos > "$OUT/host-macos.svg"
STAGE="$(mktemp -d)/Auscult.iconset"; mkdir -p "$STAGE"
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
    base="${spec%%:*}"; scale="${spec##*:}"; px=$((base * scale))
    name="icon_${base}x${base}"; [ "$scale" = 2 ] && name="${name}@2x"
    rsvg-convert -w "$px" -h "$px" "$OUT/host-macos.svg" -o "$STAGE/${name}.png"
done
iconutil -c icns "$STAGE" -o "$ROOT/Resources/Auscult.icns"
rm -rf "$(dirname "$STAGE")"

# Keep a full-bleed 1024 of the host mark too: App Store Connect and the
# README both want a square version with no margin.
emit_svg host ios > "$OUT/host-ios.svg"
rsvg-convert -w 1024 -h 1024 "$OUT/host-ios.svg" -o "$OUT/host-1024.png"
strip_alpha "$OUT/host-1024.png"

echo "Wrote:"
echo "  $ICONSET/icon-1024.png"
echo "  $ROOT/Resources/Auscult.icns"
echo "  $OUT/host-1024.png"
