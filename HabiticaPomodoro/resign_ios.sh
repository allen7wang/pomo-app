#!/bin/bash
# 一键重签安装：检测已连接的实体 iPhone → 每台构建签名 Release → 核验 → 覆盖安装 → 启动
#
# 免费个人团队签名 7 天过期，应用到期无法启动；届时插上手机重跑本脚本即可。
# 覆盖安装不卸载、不清数据（同 bundle ID 升级，沙箱与 iCloud 授权保留）。
# 内嵌 PlugIns/HabiticaPomodoroWidgets.appex（实时活动 + 主屏小组件）由 Xcode 一并签名，
# 自动注册第二个 App ID（…ios.widgets）与 App Group；免费账号每 7 天最多注册 10 个 App ID。
# 若 Xcode 拒绝 App Group，自动改为不带 App Group 重签：实时活动照常，主屏小组件显示占位。
#
# 用法:
#   bash resign_ios.sh              # 安装到所有已连接且解锁的实体 iPhone
#   HABITICA_IOS_TEAM=XXXXXXXXXX bash resign_ios.sh   # 换签名团队
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE"

TEAM="${HABITICA_IOS_TEAM:-Q7N96QQT8M}"
BUNDLE_ID="com.hermes.habitica-pomodoro.ios"
SCRATCH="${HERMES_SCRATCH:-$HOME/.hermes/cache/scratch}"
WORK="${HABITICA_RESIGN_WORK:-$SCRATCH/pomo-ios-resign}"
mkdir -p "$WORK"

command -v xcodegen >/dev/null || { echo "需要 xcodegen: brew install xcodegen" >&2; exit 1; }

# ── 1. 发现已连接的实体设备 ──
echo "1/4  检测已连接实体 iPhone..."
UDIDS=$(xcrun devicectl list devices 2>/dev/null | awk '
    /physical/ && !/unavailable/ && !/simulated/ {
        for (i = 1; i <= NF; i++)
            if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$/) { print $i; break }
    }')
if [ -z "$UDIDS" ]; then
    echo "未发现已连接的实体 iPhone。请：插上数据线（直连机身接口）、解锁屏幕、" >&2
    echo "如弹出「信任此电脑」点信任，然后重跑。" >&2
    exit 1
fi
echo "      发现设备:"
for U in $UDIDS; do echo "        - $U"; done

# ── 2. 生成工程 ──
echo "2/4  生成 Xcode 工程 (xcodegen)..."
xcodegen generate >/dev/null

FAIL=0
for UDID in $UDIDS; do
    echo ""
    echo "════ 设备 $UDID ════"

    # 就绪探测（挂载 DDI；锁屏时这里就会失败，避免浪费构建时间）
    if ! xcrun devicectl --timeout 45 device info apps --device "$UDID" >/dev/null 2>&1; then
        echo "  ⚠️  设备未就绪（锁屏/未信任/连接不稳），跳过。解锁后重跑。" >&2
        FAIL=1; continue
    fi

    # 构建（自动注册设备 + 生成含该设备的新 profile）
    echo "  构建签名 Release..."
    DD="$WORK/dd-$UDID"
    build_signed() {
        xcodebuild -project HabiticaPomodoroMobile.xcodeproj \
            -scheme HabiticaPomodoroMobile \
            -destination "id=$UDID" -destination-timeout 60 \
            -derivedDataPath "$DD" -jobs 1 -configuration Release \
            -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
            build DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
            CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES "$@" \
            > "$WORK/build-$UDID.log" 2>&1
    }
    if ! build_signed; then
        if grep -qi "app group" "$WORK/build-$UDID.log"; then
            echo "  ⚠️  签名团队不接受 App Group，改为不带 App Group 重签（主屏小组件将显示占位）..."
            cp "$WORK/build-$UDID.log" "$WORK/build-$UDID-appgroup.log"
            if ! build_signed CODE_SIGN_ENTITLEMENTS=; then
                echo "  ❌ 构建失败，日志: $WORK/build-$UDID.log" >&2
                tail -5 "$WORK/build-$UDID.log" >&2
                FAIL=1; continue
            fi
        else
            echo "  ❌ 构建失败，日志: $WORK/build-$UDID.log" >&2
            tail -5 "$WORK/build-$UDID.log" >&2
            FAIL=1; continue
        fi
    fi

    APP="$DD/Build/Products/Release-iphoneos/HabiticaPomodoro.app"
    APPEX="$APP/PlugIns/HabiticaPomodoroWidgets.appex"

    # 核验：版本 / strict 签名 / profile 含本机 UDID / 有效期
    VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
    BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP/Info.plist")
    [ -d "$APPEX" ] || { echo "  ❌ 缺少小组件扩展 $APPEX" >&2; FAIL=1; continue; }
    codesign --verify --strict "$APPEX" || { echo "  ❌ 小组件扩展签名校验失败" >&2; FAIL=1; continue; }
    codesign --verify --strict "$APP" || { echo "  ❌ 签名校验失败" >&2; FAIL=1; continue; }
    PROFILE_PLIST=$(mktemp "$WORK/profile.XXXXXX.plist")
    PROFILE_OK=1
    for BUNDLE in "$APP" "$APPEX"; do
        security cms -D -i "$BUNDLE/embedded.mobileprovision" -o "$PROFILE_PLIST" 2>/dev/null
        if ! /usr/libexec/PlistBuddy -c "Print ProvisionedDevices" "$PROFILE_PLIST" 2>/dev/null | grep -q "$UDID"; then
            echo "  ❌ $(basename "$BUNDLE") 的 profile 未包含该设备 UDID" >&2; PROFILE_OK=0
        fi
    done
    security cms -D -i "$APP/embedded.mobileprovision" -o "$PROFILE_PLIST" 2>/dev/null
    EXPIRY=$(/usr/libexec/PlistBuddy -c "Print ExpirationDate" "$PROFILE_PLIST" 2>/dev/null || echo "?")
    rm -f "$PROFILE_PLIST"
    [ "$PROFILE_OK" -eq 1 ] || { FAIL=1; continue; }
    echo "  ✅ $VER (build $BUILD)，签名有效，profile 到期: $EXPIRY (UTC)"

    # 覆盖安装（不卸载不清数据）
    echo "  安装..."
    if ! xcrun devicectl --timeout 180 device install app --device "$UDID" "$APP"; then
        echo "  ❌ 安装失败" >&2; FAIL=1; continue
    fi

    # 尝试启动（锁屏/未信任会失败，不算致命）
    if xcrun devicectl --timeout 30 device process launch --device "$UDID" --activate "$BUNDLE_ID" >/dev/null 2>&1; then
        echo "  ✅ 已安装并启动"
    else
        echo "  ✅ 已安装；启动失败（解锁屏幕手动点开；首次安装需在"
        echo "     设置 → 通用 → VPN 与设备管理 里信任开发者证书）"
    fi
done

echo ""
if [ "$FAIL" -ne 0 ]; then
    echo "⚠️  部分设备未完成，见上方日志。"
    exit 1
fi
echo "✅ 全部设备完成。签名 7 天后过期，届时重跑本脚本。"
