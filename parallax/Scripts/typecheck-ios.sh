#!/bin/bash
# Type-check the iOS-only sources against the iOS SDK. Catches API misuse on a
# machine with no simulator runtime installed.
#
# Two things matter in a restricted environment.
#
# 1. -Xfrontend -disable-sandbox stops the compiler from wrapping the macro plugin
#    server in its own sandbox-exec. A nested seatbelt sandbox is refused, which
#    makes every macro fail to expand with a "malformed response" error from
#    swift-plugin-server. Without this flag @Observable cannot compile at all here.
# 2. CLANG_MODULE_CACHE_PATH is pointed at a writable directory when the default
#    under ~/.cache is read-only, which is the case in a sandboxed workspace.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios26.0-simulator"

OUT="$ROOT/.build/ios-typecheck"
mkdir -p "$OUT"

if [ -z "$CLANG_MODULE_CACHE_PATH" ]; then
  export CLANG_MODULE_CACHE_PATH="$OUT/modulecache"
fi
mkdir -p "$CLANG_MODULE_CACHE_PATH"

KIT=$(find "$ROOT/Sources/ParallaxKit" -name '*.swift' | sort)
APP=$(find "$ROOT/Sources/ParallaxApp" -name '*.swift' | sort)

# ParallaxKit and ParallaxApp are separate modules, so emit ParallaxKit first and
# let the app type-check against it.
echo "type-checking ParallaxKit against $SDK"
swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -Xfrontend -disable-sandbox \
  -emit-module -module-name ParallaxKit \
  -emit-module-path "$OUT/ParallaxKit.swiftmodule" $KIT

echo "type-checking ParallaxApp against $SDK"
swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -Xfrontend -disable-sandbox \
  -typecheck -I "$OUT" $APP

echo "iOS type-check passed"
