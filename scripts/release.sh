#!/usr/bin/env bash
# release.sh — 一键发版:swift build release → 装入 .app → 签名 → (可选) notarize → DMG
#
# 用法:
#   ./scripts/release.sh 0.3.0                          # ad-hoc 签名,不 notarize
#   IDENTITY="Developer ID Application: Foo Bar (ABCD123456)" \
#     NOTARY_PROFILE=kown-notarize \
#     ./scripts/release.sh 0.3.0                        # 完整流程:签名 + notarize + staple + DMG
#
# 一次性准备 notarytool keychain profile(对所有 app 通用):
#   xcrun notarytool store-credentials kown-notarize \
#       --apple-id you@example.com \
#       --team-id ABCD123456 \
#       --password xxxx-xxxx-xxxx-xxxx          # app-specific password
set -euo pipefail

VERSION="${1:?usage: release.sh <version>  例:./scripts/release.sh 0.3.0}"
IDENTITY="${IDENTITY:--}"   # 默认 ad-hoc(短横线)
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

APP_NAME="Kown"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="${ROOT}/dist/${APP_NAME}.app"
DMG_PATH="${ROOT}/dist/${APP_NAME}-${VERSION}.dmg"
ENTITLEMENTS="${ROOT}/dist/${APP_NAME}.entitlements"
ZIP_PATH="${ROOT}/dist/${APP_NAME}-${VERSION}.zip"

cd "${ROOT}"

# 0) 准备 entitlements。iCloud 同步依赖这些 entitlement;正式可用仍需要
# Apple-issued signing identity + 对应 iCloud container capability。
if [ ! -f "${ENTITLEMENTS}" ]; then
    cat > "${ENTITLEMENTS}" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.xiaobo.kown</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudDocuments</string>
    </array>
    <key>com.apple.developer.ubiquity-container-identifiers</key>
    <array>
        <string>iCloud.com.xiaobo.kown</string>
    </array>
</dict>
</plist>
EOF
fi

# 1) build release
echo "▶ Building Kown ${VERSION} (release)..."
swift build -c release

# 2) 装进 .app bundle
echo "▶ Copying binary into bundle..."
cp -f .build/release/Kown "${APP_BUNDLE}/Contents/MacOS/Kown"

# 2.5) 把 CHANGELOG.md 直接拷到 .app/Contents/Resources/。
#
#      历史教训:之前依赖 SPM 生成的 `Bundle.module`(从 Kown_Kown.bundle 里读)。
#      但 SPM 在 macOS 上输出的 bundle 是扁平目录,新版 Foundation 的 Bundle(url:) 偶发拒绝
#      → `Bundle.module` 静态初始化 fatalError → app 启动闪退,而且 fatalError 无法 catch。
#      现在 ChangelogService 改成走 Bundle.main 读,直接把 CHANGELOG.md 放进主 bundle 即可,
#      永远不会让一个找不到的资源把 app 干掉。
if [ -f ".build/release/Kown_Kown.bundle/CHANGELOG.md" ]; then
    echo "▶ Copying CHANGELOG.md to .app/Contents/Resources/..."
    cp -f ".build/release/Kown_Kown.bundle/CHANGELOG.md" "${APP_BUNDLE}/Contents/Resources/CHANGELOG.md"
fi
# 清掉历史遗留的 SPM resource bundle(如果之前的脚本拷过)— 防止 codesign --deep 校验它
rm -rf "${APP_BUNDLE}/Contents/Resources/Kown_Kown.bundle"

# 2.6) 内嵌 Sparkle.framework(自动更新)。
#      SPM 只把 Sparkle 链进可执行文件,不会帮我们把 framework 拷进 .app —— 手动装。
#      framework 的 install_name 是 @rpath/Sparkle.framework/...,所以主程序要带上
#      @executable_path/../Frameworks 这条 rpath 才能在运行时找到它。
SPARKLE_FW="$(/usr/bin/find .build/artifacts -type d -ipath '*macos*/Sparkle.framework' 2>/dev/null | head -1)"
if [ -n "${SPARKLE_FW}" ] && [ -d "${SPARKLE_FW}" ]; then
    echo "▶ Embedding Sparkle.framework..."
    mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
    rm -rf "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    # ditto 保留符号链接 / 扩展属性(签名所需);别用 cp -R。
    ditto "${SPARKLE_FW}" "${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
    # 加 rpath(已存在则忽略报错);顺手删掉 SPM 注入的 .build 绝对路径 rpath,
    # 否则在别的 Mac 上那条死路径会拖慢 dyld 解析。
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "${APP_BUNDLE}/Contents/MacOS/Kown" 2>/dev/null || true
    BUILD_RPATH="$(otool -l "${APP_BUNDLE}/Contents/MacOS/Kown" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | grep "/.build/" || true)"
    if [ -n "${BUILD_RPATH}" ]; then
        install_name_tool -delete_rpath "${BUILD_RPATH}" "${APP_BUNDLE}/Contents/MacOS/Kown" 2>/dev/null || true
    fi
else
    echo "⚠ 没找到 Sparkle.framework artifact,自动更新不会工作。先跑 swift build -c release。"
fi

# 3) 写版本号
plutil -replace CFBundleShortVersionString -string "${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
# CFBundleVersion 用 git 提交数(单调递增),没 git 就用时间戳
build_num="$(git rev-list --count HEAD 2>/dev/null || date +%s)"
plutil -replace CFBundleVersion -string "${build_num}" "${APP_BUNDLE}/Contents/Info.plist"

# 3.5) 声明 iCloud Documents 容器,与 entitlements 中的 container identifier 保持一致。
/usr/libexec/PlistBuddy -c "Delete :NSUbiquitousContainers" "${APP_BUNDLE}/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :NSUbiquitousContainers dict" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSUbiquitousContainers:iCloud.com.xiaobo.kown dict" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSUbiquitousContainers:iCloud.com.xiaobo.kown:NSUbiquitousContainerIsDocumentScopePublic bool false" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSUbiquitousContainers:iCloud.com.xiaobo.kown:NSUbiquitousContainerName string Kown" "${APP_BUNDLE}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NSUbiquitousContainers:iCloud.com.xiaobo.kown:NSUbiquitousContainerSupportedFolderLevels string Any" "${APP_BUNDLE}/Contents/Info.plist"

# 3.6) 嵌入 Developer ID provisioning profile(用 iCloud 时必需,否则
#      amfid 在没装 profile 的别的 Mac 上找不到授权链,启动直接被拒)。
#      profile UUID 来自 Apple Developer 后台生成的 "Kown Developer ID" profile。
#      ad-hoc 签名不嵌入(没意义)。
PROFILE_UUID="9465c15d-1e8a-4139-ad0a-478155150a16"
PROFILE_SRC="${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles/${PROFILE_UUID}.provisionprofile"
if [ "${IDENTITY}" != "-" ] && [ -f "${PROFILE_SRC}" ]; then
    echo "▶ Embedding provisioning profile..."
    cp -f "${PROFILE_SRC}" "${APP_BUNDLE}/Contents/embedded.provisionprofile"
elif [ "${IDENTITY}" != "-" ]; then
    echo "⚠ Developer ID profile 没找到: ${PROFILE_SRC}"
    echo "  iCloud 启用的 app 在别的 Mac 上会启动失败,先去 Xcode 把 profile fetch 下来。"
fi

# 4) 签名
#    内嵌的 Sparkle.framework 必须「由里到外」逐个签:XPC 服务 → Autoupdate → Updater.app
#    → framework 本体 → 最后主 app。且这些 helper 绝不能带上主 app 的 entitlements
#    (iCloud / 文件访问),否则公证 / Gatekeeper 会拒。所以主 app 这步不能用 --deep。
SP="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"
sign_sparkle() {  # $1 = identity, $2... = extra codesign flags
    local id="$1"; shift
    [ -d "${SP}" ] || return 0
    echo "▶ Signing embedded Sparkle.framework (inside-out)..."
    local item
    for item in \
        "${SP}/Versions/B/XPCServices/Downloader.xpc" \
        "${SP}/Versions/B/XPCServices/Installer.xpc" \
        "${SP}/Versions/B/Autoupdate" \
        "${SP}/Versions/B/Updater.app" \
        "${SP}"
    do
        [ -e "${item}" ] && codesign --force "$@" --sign "${id}" "${item}"
    done
}

if [ "${IDENTITY}" = "-" ]; then
    echo "▶ Ad-hoc signing..."
    sign_sparkle "-"
    codesign --force --sign - \
        --entitlements "${ENTITLEMENTS}" \
        "${APP_BUNDLE}"
else
    echo "▶ Signing with identity: ${IDENTITY}"
    sign_sparkle "${IDENTITY}" --options runtime --timestamp
    # 主 app 最后签(不带 --deep,nested 已各自签好),带上 app 自己的 entitlements。
    codesign --force --options runtime --timestamp \
        --sign "${IDENTITY}" \
        --entitlements "${ENTITLEMENTS}" \
        "${APP_BUNDLE}"
fi

codesign --verify --strict --verbose=2 "${APP_BUNDLE}" 2>&1 | tail -3

# 5) Notarize(可选)
if [ -n "${NOTARY_PROFILE}" ] && [ "${IDENTITY}" != "-" ]; then
    echo "▶ Notarizing (profile: ${NOTARY_PROFILE})..."
    /usr/bin/ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"
    xcrun notarytool submit "${ZIP_PATH}" \
        --keychain-profile "${NOTARY_PROFILE}" --keychain "${HOME}/Library/Keychains/login.keychain-db" --wait
    rm -f "${ZIP_PATH}"
    echo "▶ Stapling ticket to .app..."
    xcrun stapler staple "${APP_BUNDLE}"
else
    echo "ℹ Skipping notarization (无 NOTARY_PROFILE 或 ad-hoc 签名)"
fi

# 6) 打 DMG — 做成"拖到 Applications"安装界面:
#    - staging 目录里放 Kown.app + Applications 软链接 → 用户挂载后双击窗口看到两个图标,
#      直接拖左边到右边即可。
#    - 先做 UDRW(可写)、挂上、osascript 设窗口大小 / 图标位置 / 隐藏侧栏,再转 UDZO 压缩 + 只读。
#    - 整个 osascript 部分失败也不致命(某些 CI / 远程环境没权限控制 Finder),fallback 成最朴素的两图标布局。
echo "▶ Building DMG: ${DMG_PATH}"
rm -f "${DMG_PATH}"

STAGING="${ROOT}/dist/.dmg-staging"
RW_DMG="${ROOT}/dist/.${APP_NAME}-${VERSION}.rw.dmg"
VOL_NAME="${APP_NAME} Installer"

rm -rf "${STAGING}" "${RW_DMG}"
mkdir -p "${STAGING}"
# 用 ditto 保留扩展属性(签名所需);别用 cp -R。
ditto "${APP_BUNDLE}" "${STAGING}/${APP_NAME}.app"
ln -s /Applications "${STAGING}/Applications"

# 先做 UDRW(可写) — 留出空间放 .DS_Store 用的图标位置 metadata
hdiutil create -volname "${VOL_NAME}" \
    -srcfolder "${STAGING}" \
    -ov -format UDRW -fs HFS+ \
    "${RW_DMG}" >/dev/null

# 挂载读写卷(用 mktemp mountpoint 避免和别人的 /Volumes/Xxx 撞 TCC)
MNT="$(mktemp -d -t kown-dmg-mnt)"
hdiutil attach "${RW_DMG}" -nobrowse -mountpoint "${MNT}" -noverify >/dev/null

# osascript 控制 Finder 给 DMG 窗口设属性(失败不挂全局)
# 容器图标 256px,窗口 540x360,左 Kown.app / 右 Applications,中间是个箭头印象。
osascript <<APPLESCRIPT 2>/dev/null || echo "  (Finder AppleScript 设窗口失败,DMG 仍可用,只是没预置图标位置)"
tell application "Finder"
    tell disk "${VOL_NAME}"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 740, 560}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set position of item "${APP_NAME}.app" of container window to {140, 180}
        set position of item "Applications" of container window to {400, 180}
        update without registering applications
        delay 0.5
        close
    end tell
end tell
APPLESCRIPT

# 把改动同步到磁盘
sync
hdiutil detach "${MNT}" -force >/dev/null || true
rm -rf "${MNT}"

# 转成只读压缩
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -ov -o "${DMG_PATH}" >/dev/null
rm -f "${RW_DMG}"
rm -rf "${STAGING}"

# 7) 给 DMG 也签名 + staple
if [ "${IDENTITY}" != "-" ]; then
    echo "▶ Signing DMG..."
    codesign --force --sign "${IDENTITY}" --timestamp "${DMG_PATH}"
    if [ -n "${NOTARY_PROFILE}" ]; then
        echo "▶ Notarizing DMG..."
        xcrun notarytool submit "${DMG_PATH}" \
            --keychain-profile "${NOTARY_PROFILE}" --keychain "${HOME}/Library/Keychains/login.keychain-db" --wait
        xcrun stapler staple "${DMG_PATH}"
    fi
fi

# 8) 生成签名后的 appcast.xml(Sparkle 更新源)。
#    用 Sparkle 自带的 generate_appcast,它用 keychain 里的 EdDSA 私钥给 DMG 签名,
#    并把 enclosure url 指向公开分发仓库 macuhy/kown-mac 的 release 资源。
#    把当前 DMG 单独丢进临时目录再扫描,避免 dist/ 里历史 DMG 串进同一个 tag 的下载链接。
#    产物 dist/appcast.xml 连同 DMG 一起上传到 macuhy/kown-mac(release 资源 + 仓库根的 appcast.xml)。
APPCAST_DOWNLOAD_PREFIX="${APPCAST_DOWNLOAD_PREFIX:-https://github.com/macuhy/kown-mac/releases/download/v${VERSION}/}"
APPCAST_LINK="${APPCAST_LINK:-https://github.com/macuhy/kown}"
GEN_APPCAST="$(/usr/bin/find "${ROOT}/.build/artifacts" -ipath '*sparkle*/bin/generate_appcast' 2>/dev/null | head -1)"
if [ -n "${GEN_APPCAST}" ] && [ -x "${GEN_APPCAST}" ]; then
    echo "▶ Generating signed appcast.xml..."
    APPCAST_WORK="$(mktemp -d -t kown-appcast)"
    cp -f "${DMG_PATH}" "${APPCAST_WORK}/"
    # generate_appcast 默认从 keychain 读私钥(account ed25519);失败不致命。
    if "${GEN_APPCAST}" \
        --download-url-prefix "${APPCAST_DOWNLOAD_PREFIX}" \
        --link "${APPCAST_LINK}" \
        -o "${ROOT}/dist/appcast.xml" \
        "${APPCAST_WORK}" 2>&1
    then
        echo "  → ${ROOT}/dist/appcast.xml"
    else
        echo "  ⚠ generate_appcast 失败(keychain 私钥没权限?)。appcast 需手动生成。"
    fi
    rm -rf "${APPCAST_WORK}"
else
    echo "ℹ 没找到 generate_appcast,跳过 appcast 生成(先 swift build 拉下 Sparkle artifact)。"
fi

echo ""
echo "✅ Release ready:"
echo "   App: ${APP_BUNDLE}"
echo "   DMG: ${DMG_PATH} ($(du -h "${DMG_PATH}" | awk '{print $1}'))"
if [ -f "${ROOT}/dist/appcast.xml" ]; then
    echo "   Appcast: ${ROOT}/dist/appcast.xml"
    echo ""
    echo "📤 发布自动更新:把 DMG 传到 macuhy/kown-mac 的 v${VERSION} release,"
    echo "   再把 dist/appcast.xml 推到 macuhy/kown-mac 仓库根(main)。例如:"
    echo "     gh release create v${VERSION} \"${DMG_PATH}\" -R macuhy/kown-mac -t v${VERSION}"
    echo "     # 然后把 dist/appcast.xml 提交到 macuhy/kown-mac 的 main 分支"
fi
echo ""
if [ "${IDENTITY}" = "-" ]; then
    echo "ℹ ad-hoc 模式 — 其他用户首次打开需手动 xattr -dr com.apple.quarantine /Applications/Kown.app"
    echo "  或右键 → 打开 → 同意。"
    echo "  要免警告请用 Developer ID + notarize:"
    echo "    IDENTITY=\"Developer ID Application: <Name> (<TEAMID>)\" \\"
    echo "      NOTARY_PROFILE=kown-notarize \\"
    echo "      ./scripts/release.sh ${VERSION}"
fi
