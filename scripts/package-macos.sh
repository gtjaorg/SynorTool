#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# 固定本机签名证书指纹；证书私钥只保存在登录钥匙串，不能自动重建或回退临时签名。
signing_identity="F02844FCD1930CC89593D75F847682C1E7FAA50B"
signing_keychain="$HOME/Library/Keychains/login.keychain-db"
install_path="/Applications/Synor.app"
identities="$(security find-identity -p codesigning "$signing_keychain")"
if [[ "$identities" != *"$signing_identity"* ]]; then
    printf '缺少固定的 Synor Local Development 签名身份，请恢复原钥匙串；已停止打包。\n' >&2
    exit 1
fi
mkdir -p "$root/obj" "$root/dist"
stage="$(mktemp -d "$root/obj/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Synor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Web" "$stage/Synor.iconset"
dotnet publish "$root/SynorTool.csproj" -c Release -r osx-arm64 --self-contained true -o "$app/Contents/MacOS"
cp "$root/bin/Release/net10.0/osx-arm64/libSynorPanel.dylib" "$app/Contents/MacOS/"
cp "$root/bin/Release/net10.0/osx-arm64/libSynorAppleTranslation.dylib" "$app/Contents/MacOS/"
cp "$root/Web/dist/index.html" "$root/Web/dist/translation.html" "$root/Web/dist/settings.html" "$app/Contents/Resources/Web/"
mv "$app/Contents/MacOS/Assets" "$app/Contents/Resources/Assets"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$root/Assets/BrandIcon.png" --out "$stage/Synor.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$root/Assets/BrandIcon.png" --out "$stage/Synor.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/Synor.iconset" -o "$app/Contents/Resources/Synor.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.synor.tool</string>
<key>CFBundleName</key><string>Synor</string>
<key>CFBundleDisplayName</key><string>Synor</string>
<key>CFBundleExecutable</key><string>SynorTool</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleIconFile</key><string>Synor.icns</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# .NET 自包含目录同时有 Mach-O 与托管程序集，递归签名后再固定外层应用身份。
codesign --force --deep --sign "$signing_identity" --keychain "$signing_keychain" --timestamp=none "$app"
requirement="identifier \"com.synor.tool\" and certificate leaf = H\"$signing_identity\""
codesign --force --sign "$signing_identity" --keychain "$signing_keychain" --timestamp=none --requirements "=designated => $requirement" "$app"
codesign --verify --deep --strict "$app"
codesign --verify --strict -R="$requirement" "$app"
# 所有验证通过后才更新固定安装位置；dist 仅保留入口，避免重复安装副本。
mkdir -p "/Applications"
install_stage="$(mktemp -d "/Applications/.synor-install.XXXXXX")"
trap 'rm -rf "$stage" "$install_stage"' EXIT
ditto "$app" "$install_stage/Synor.app"
codesign --verify --deep --strict -R="$requirement" "$install_stage/Synor.app"
if [[ -e "$install_path" ]]; then
    installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$install_path/Contents/Info.plist")
    if [[ "$installed_id" != "com.synor.tool" ]]; then
        printf '安装位置存在其他应用，已停止更新：%s\n' "$install_path" >&2
        exit 1
    fi
    mv "$install_path" "$install_stage/previous.app"
fi
if ! mv "$install_stage/Synor.app" "$install_path"; then
    if [[ -d "$install_stage/previous.app" ]]; then mv "$install_stage/previous.app" "$install_path"; fi
    exit 1
fi
rm -rf "$root/dist/Synor.app"
ln -s "$install_path" "$root/dist/Synor.app"
printf '已签名并安装：%s\n' "$install_path"
