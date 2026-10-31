#!/bin/bash
# Extract the pinned CPython pkg into a build-only staging directory.
set -euo pipefail

REPO="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PKG="${1:-$REPO/python-3.14.7-macos11.pkg}"
STAGE="${2:-$REPO/build/python-runtime}"

[ -f "$PKG" ] || { echo "缺少 Python runtime 包：$PKG" >&2; exit 1; }
command -v pkgutil >/dev/null || { echo "需要 macOS pkgutil" >&2; exit 1; }
command -v lipo >/dev/null || { echo "需要 Xcode lipo" >&2; exit 1; }
command -v install_name_tool >/dev/null || { echo "需要 Xcode install_name_tool" >&2; exit 1; }
command -v codesign >/dev/null || { echo "需要 codesign" >&2; exit 1; }
command -v shasum >/dev/null || { echo "需要 shasum" >&2; exit 1; }

TEMP="$(mktemp -d "${TMPDIR:-/tmp}/controlmymac-python.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
EXTRACT="$TEMP/extracted"
pkgutil --expand-full "$PKG" "$EXTRACT"

FRAMEWORK="$(/usr/bin/find "$EXTRACT" -type d -path '*/Python_Framework.pkg/Payload' -print -quit)"
[ -n "$FRAMEWORK" ] || { echo "pkg 中找不到标准 Python.framework payload" >&2; exit 1; }
PYTHON_BIN="$FRAMEWORK/Versions/3.14/bin/python3.14"
[ -x "$PYTHON_BIN" ] || { echo "pkg 中找不到 Python 3.14 解释器" >&2; exit 1; }

VERSION="3.14.7"
# The extracted pkg is not installed at its framework path yet, so its interpreter
# cannot be launched before staging. The pkg filename/version is pinned above;
# runtime execution is verified after the framework is inside the App bundle.

ARCHES="$(lipo -archs "$PYTHON_BIN")"
[ -n "$ARCHES" ] || { echo "无法读取 Python runtime 架构" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$FRAMEWORK" "$STAGE/Python.framework"

# The pkg is installed under /Library/Frameworks. Rewrite that absolute
# install name so the bundled interpreter loads its sibling framework in the App.
OLD_INSTALL_NAME="/Library/Frameworks/Python.framework/Versions/3.14/Python"
OLD_SSL_NAME="/Library/Frameworks/Python.framework/Versions/3.14/lib/libssl.3.dylib"
OLD_CRYPTO_NAME="/Library/Frameworks/Python.framework/Versions/3.14/lib/libcrypto.3.dylib"
FRAMEWORK_BINARY="$STAGE/Python.framework/Versions/3.14/Python"
install_name_tool -id "@rpath/Python" "$FRAMEWORK_BINARY"
codesign --force --sign - "$FRAMEWORK_BINARY" >/dev/null
while IFS= read -r -d '' macho; do
    deps="$(otool -L "$macho" 2>/dev/null || true)"
    case "$macho" in
        */Resources/Python.app/Contents/MacOS/*) ssl_replacement="@loader_path/../../../../Python"; crypto_replacement="@loader_path/../../../../Python" ;;
        */lib/libssl.3.dylib) ssl_replacement="@loader_path/libssl.3.dylib"; crypto_replacement="@loader_path/libcrypto.3.dylib" ;;
        */lib/libcrypto.3.dylib) ssl_replacement="@loader_path/libssl.3.dylib"; crypto_replacement="@loader_path/libcrypto.3.dylib" ;;
        */lib-dynload/*) ssl_replacement="@loader_path/../../../lib/libssl.3.dylib"; crypto_replacement="@loader_path/../../../lib/libcrypto.3.dylib" ;;
        *) ssl_replacement="@loader_path/../Python"; crypto_replacement="@loader_path/../Python" ;;
    esac
    changed=0
    if printf '%s' "$deps" | grep -Fq "$OLD_INSTALL_NAME"; then
        install_name_tool -change "$OLD_INSTALL_NAME" "$ssl_replacement" "$macho"
        changed=1
    fi
    if printf '%s' "$deps" | grep -Fq "$OLD_SSL_NAME"; then
        install_name_tool -change "$OLD_SSL_NAME" "$ssl_replacement" "$macho"
        changed=1
    fi
    if printf '%s' "$deps" | grep -Fq "$OLD_CRYPTO_NAME"; then
        install_name_tool -change "$OLD_CRYPTO_NAME" "$crypto_replacement" "$macho"
        changed=1
    fi
    if [ "$changed" -eq 1 ]; then
        codesign --force --sign - "$macho" >/dev/null
    fi
done < <(/usr/bin/find "$STAGE/Python.framework" -type f -print0)
install_name_tool -id "@loader_path/libssl.3.dylib" "$STAGE/Python.framework/Versions/3.14/lib/libssl.3.dylib"
install_name_tool -id "@loader_path/libcrypto.3.dylib" "$STAGE/Python.framework/Versions/3.14/lib/libcrypto.3.dylib"
codesign --force --sign - "$STAGE/Python.framework/Versions/3.14/lib/libssl.3.dylib" >/dev/null
codesign --force --sign - "$STAGE/Python.framework/Versions/3.14/lib/libcrypto.3.dylib" >/dev/null


LICENSE="$FRAMEWORK/Versions/3.14/lib/python3.14/LICENSE.txt"
[ -f "$LICENSE" ] || { echo "pkg 中找不到 Python LICENSE" >&2; exit 1; }
cp "$LICENSE" "$STAGE/PYTHON_LICENSE"

STAGE_PYTHON="$STAGE/Python.framework/Versions/3.14/bin/python3.14"
STAGE_LIBRARY="$STAGE/Python.framework/Versions/3.14/lib/python3.14/os.py"
[ -f "$STAGE_LIBRARY" ] || { echo "Python 标准库不完整：$STAGE_LIBRARY" >&2; exit 1; }
HASH_PYTHON="$(shasum -a 256 "$STAGE_PYTHON" | awk '{print $1}')"
HASH_LIBRARY="$(shasum -a 256 "$STAGE_LIBRARY" | awk '{print $1}')"
HASH_LICENSE="$(shasum -a 256 "$STAGE/PYTHON_LICENSE" | awk '{print $1}')"

ARCH_JSON="$(printf '%s' "$ARCHES" | awk '{gsub(/ /, "\",\""); print "[\"" $0 "\"]"}')"
cat > "$STAGE/python-runtime.json" <<EOF
{
  "runtimeVersion": "$VERSION",
  "architectures": $ARCH_JSON,
  "executable": "Contents/Frameworks/Python.framework/Versions/3.14/bin/python3.14",
  "home": "Contents/Frameworks/Python.framework/Versions/3.14",
  "files": {
    "Contents/Frameworks/Python.framework/Versions/3.14/bin/python3.14": "$HASH_PYTHON",
    "Contents/Frameworks/Python.framework/Versions/3.14/lib/python3.14/os.py": "$HASH_LIBRARY",
    "Contents/Resources/PYTHON_LICENSE": "$HASH_LICENSE"
  },
  "licenseFiles": ["Contents/Resources/PYTHON_LICENSE"]
}
EOF

echo "Python runtime 已准备：$VERSION [$ARCHES]"
echo "Stage: $STAGE"
