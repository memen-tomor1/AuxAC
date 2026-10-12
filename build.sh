#!/bin/bash
# 编译并打包成 .app（含桌面小组件扩展）。
#
# 为什么不用 `swift build`：本机的 DSH 沙箱下，SwiftPM 的构建引擎在读取
# `.build/**/output-file-map.json` 时会报 I/O error（它内部还会调 sandbox-exec，
# 嵌套沙箱被拒）。直接用 swiftc 编译同样这几个文件完全正常，所以这里绕过 SwiftPM。
# 本项目零第三方依赖，直接 swiftc 没有任何代价。
#
# 为什么要有 .app 外壳：`swiftc` 只产出裸可执行文件，此时
# Bundle.main.bundleIdentifier 是 nil，而 SwiftUI 的 MenuBarExtra 依赖 bundle 标识——
# 没有外壳程序能启动但菜单栏图标不出现。
#
# 为什么主程序用 swiftc、小组件却必须用 xcodebuild：
# 一开始小组件也是用 swiftc 手搓的 .appex（目录 + 可执行文件 + Info.plist）。
# 结果是——chronod 认得它、会启动它，但进程每次都在 WidgetKit 引导阶段
# 崩在 `ExtensionFoundation` 的 `_EXRunningExtension` 初始化里
# （SIGTRAP / brk 1）。试过部署目标 11/12/13/14/20/24/25/26、-Onone、
# 去掉 -application-extension、补 AppKit / AppIntents / rpath、
# 手写 DT* 与 CFBundleSupportedPlatforms 键，全部照崩。
# 换成正规 Xcode 工程（xcodebuild）编同一个源文件，同一个 appex 结构，
# 立刻稳定通过、连测 3 次不崩。所以这条界线是「Xcode 的链接/签名流水线」，
# 不是我们代码的问题——小组件这一块就别再退回 swiftc 了。
# 工程文件来源：复制本机一个真实工程改造（手写 pbxproj 一定被 xcodebuild
# 判定为 damaged，别试）。工程在 Xcode/AuxACWidget.xcodeproj，
# 源码用符号链接指回 Sources/AuxACWidget/，避免两份文件漂移。
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AuxAC"
BUNDLE_ID="com.local.auxac"
VERSION="0.1.0"
TARGET="arm64-apple-macosx13.0"
# 小组件的部署目标写在 Xcode 工程里（MACOSX_DEPLOYMENT_TARGET = 14.0）：
# 交互式按钮（`Button(intent:)`）和 `.containerBackground` 都是 macOS 14
# 才有的 API。主 App 继续停在 13.0 以兼容更老的系统。
WIDGET_NAME="AuxACWidget"

CACHE_DIR="$PWD/.cache/clangmod"
mkdir -p "$CACHE_DIR" build
# /var/folders 在当前沙箱下不可写，clang 的模块缓存必须改道
export TMPDIR="${TMPDIR:-/tmp}"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR"

echo "==> 编译主程序"
# 主程序要 -framework WidgetKit 是为了 `WidgetCenter.shared.reloadTimelines`：
# 状态一变就通知小组件重画，不然小组件只能等自己的 15 分钟兜底刷新。
swiftc -O \
  -module-cache-path "$CACHE_DIR" \
  -target "$TARGET" \
  -framework SwiftUI -framework AppKit -framework Foundation \
  -framework ServiceManagement -framework WidgetKit \
  -parse-as-library \
  -o "build/$APP_NAME.bin" \
  Sources/AuxAC/*.swift

echo "==> 编译小组件扩展（xcodebuild）"
# 源码只有一份（Sources/AuxACWidget/），工程里用符号链接指过去。
# `release` 配置里 CODE_SIGN_IDENTITY = "-"，也就是 Xcode 的
# "Sign to Run Locally"，本机没有任何可用签名身份（security find-identity
# 返回 0 valid identities），ad-hoc 是唯一选择，够用。
WIDGET_PROJ="Xcode/AuxACWidget.xcodeproj"
WIDGET_BUILD_DIR="$PWD/build/widget"
if ! xcodebuild -project "$WIDGET_PROJ" -target "$WIDGET_NAME" -configuration Release \
      CONFIGURATION_BUILD_DIR="$WIDGET_BUILD_DIR" \
      SYMROOT="$PWD/build/widget-sym" OBJROOT="$PWD/build/widget-obj" \
      build 2>&1 | tail -5 | grep -q "BUILD SUCCEEDED"; then
  echo "小组件编译失败，完整输出见下："
  xcodebuild -project "$WIDGET_PROJ" -target "$WIDGET_NAME" -configuration Release \
    CONFIGURATION_BUILD_DIR="$WIDGET_BUILD_DIR" \
    SYMROOT="$PWD/build/widget-sym" OBJROOT="$PWD/build/widget-obj" build
  exit 1
fi

APP_DIR="build/$APP_NAME.app"
echo "==> 组装 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "build/$APP_NAME.bin" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>奥克斯空调</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <!-- 菜单栏工具：不出现在 Dock 和 Cmd-Tab 里 -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <!-- auxac:// 自动化入口。快捷指令的「打开 URL」、AppleScript 的
         do shell script "open 'auxac://on'"、终端 open 全都走这里。
         命令表见 Sources/AuxAC/URLCommands.swift 与 README。
         注意：这个 heredoc 没有引号，所以注释里不能出现反引号——
         反引号会被 bash 当命令替换执行（踩过一次）。 -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.local.auxac.command</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>auxac</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

WIDGET_DIR="$APP_DIR/Contents/PlugIns/$WIDGET_NAME.appex"
echo "==> 组装 $WIDGET_DIR"
# 直接搬 xcodebuild 的产物。它已经带好了 LSMinimumSystemVersion、DT*、
# CFBundleSupportedPlatforms 这些键（手写 plist 时得自己补，还补不对），
# Resources/ 里还有交互式按钮要用的 Metadata.appintents。
mkdir -p "$APP_DIR/Contents/PlugIns"
rm -rf "$WIDGET_DIR"
cp -R "$WIDGET_BUILD_DIR/$WIDGET_NAME.appex" "$WIDGET_DIR"

echo "==> ad-hoc 签名（先里后外）"
# 必须从内往外签：外层签名会把当前的内层哈希记进 CodeResources，
# 顺序反了的话装完系统会发现内层和外层对不上，直接拒绝加载扩展。
#
# 扩展必须带上 entitlements 里的 `com.apple.security.app-sandbox`。
# 没有沙箱的 WidgetKit 扩展 chronod 根本不会托管——症状是小组件库里搜不到、
# 也不报任何错，最难查。对照过本机三个第三方小组件，三个全带沙箱。
# 主 App 不需要沙箱（AirBattery 的主 App 也没有）。
codesign --force --sign - \
  --entitlements Sources/AuxACWidget/AuxACWidget.entitlements \
  "$WIDGET_DIR" 2>&1 | grep -v "replacing existing signature" || true
# 外层**不加** `--deep`。`--deep` 会重新签内层，而它默认不保留内层已有的
# entitlements——那会把刚给扩展加上的沙箱权限抹掉。扩展已经签好了，
# 这里只签外层、把内层当资源封进去即可（后面用 `--verify --deep --strict` 校验）。
codesign --force --sign - "$APP_DIR" 2>&1 | grep -v "replacing existing signature" || true

# 把签名结果打出来。entitlements 掉了的话这里一眼能看出来，
# 不用等到「小组件怎么又不见了」再来查。
echo "    扩展签名:"
codesign -d --entitlements - "$WIDGET_DIR" 2>/dev/null | grep -E "sandbox|network|home-relative" | sed 's/^/      /'

echo "==> 注册小组件"
# pluginkit 只认「见过」的扩展。App 没被 LaunchServices 启动过时，
# 系统还不知道这个 .appex 存在，小组件库里就没有它。
# `-a` 是幂等的，重复添加不会报错。
pluginkit -a "$WIDGET_DIR" 2>/dev/null || echo "    （pluginkit 注册失败，首次打开 App 后可能仍会出现）"

echo "==> 完成: $APP_DIR"
echo "    运行: open \"$APP_DIR\""
echo "    小组件: 右键桌面 → 编辑小组件 → 搜「奥克斯空调」"

# `--install` 额外把 App 装到 /Applications 并重新注册。
# 为什么要装过去：小组件库对 App 的位置是挑的，装在 build/ 这种深目录里
# 经常搜不到；本机能看到的第三方小组件全都在 /Applications。
# 装了之后要重新 lsregister + pluginkit，否则系统还记得旧路径。
if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> 安装到 $DEST"
  rm -rf "$DEST"
  cp -R "$APP_DIR" "$DEST"
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -f "$DEST" 2>/dev/null || true
  pluginkit -a "$DEST/Contents/PlugIns/$WIDGET_NAME.appex" 2>/dev/null || true
  echo "    已注册。小组件: 右键桌面 → 编辑小组件 → 搜「奥克斯空调」"
fi
