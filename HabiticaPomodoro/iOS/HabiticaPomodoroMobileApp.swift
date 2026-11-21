import SwiftUI
import AVFoundation
import UserNotifications

// MARK: - iOS App Entry
@main
struct HabiticaPomodoroMobileApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-previewWidgets") { WidgetPreviewGallery() } else { root }
            #else
            root
            #endif
        }
    }

    private var root: some View {
        RootTabView()
            .onAppear {
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "-previewTab"), index + 1 < args.count, let tab = Int(args[index + 1]) {
                    AppTabState.shared.selectedTab = tab
                }
                if let index = args.firstIndex(of: "-previewSkin"), index + 1 < args.count,
                   let style = AppUIStyle(rawValue: args[index + 1]) {
                    UIStyleStore.shared.style = style
                }
                #endif
            }
    }
}

// MARK: - App Delegate (通知权限 + 音频会话 + 前台重同步)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 必须最先执行：解析 iCloud Drive 文件夹授权 bookmark，
        // 保证之后任何 Manager 首次初始化时 PomodoroDataDir.url 已指向 iCloud 目录
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-isolatedDataDirectory"), index + 1 < args.count {
            PomodoroDataDir.isolatedDirectory = URL(fileURLWithPath: args[index + 1])
        }
        if args.contains("-captureDevicePreview"), let directory = PomodoroDataDir.debugDirectoryOverride {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                let window = application.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first { $0.isKeyWindow }
                guard let window, !window.bounds.isEmpty else { return }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try? image.pngData()?.write(to: directory.appendingPathComponent("device-preview.png"), options: .atomic)
            }
        }
        #endif
        _ = ICloudFolderGrant.shared
        // DEBUG 构建支持 -grantFolder <path> 启动参数授权（自动化验证用）
        ICloudFolderGrant.shared.handleLaunchArguments()

        // 通知 delegate（前台也展示横幅）；权限在首次启动番茄时再请求（懒加载，避免启动即弹窗）
        UNUserNotificationCenter.current().delegate = self

        // 音频会话：允许与静音开关共存（响铃模式仍出声），后台可播放环境音
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        // 初始化 Habitica 任务与今日计数
        Task { await PomodoroEngine.shared.initHabiticaTasks() }
        PomodoroEngine.shared.loadTodayCount()
        BlockNotificationManager.shared.startReminderTimer(settings: SettingsManager.shared.settings)

        // 锁屏实时活动与主屏小组件：只在外部观察引擎与管理器，共享代码不感知
        if #available(iOS 16.2, *) { PomodoroLiveActivity.shared.start() }
        TodayTasksWidgetSync.shared.start()

        // 回前台重同步：计时器校正 + 检测 iCloud 是否同步来了 Mac 端的新数据
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            PomodoroEngine.shared.resyncAfterForeground {
                ICloudFolderGrant.shared.refreshStatus()
                Task { await TopThreeManager.shared.synchronize(settings: SettingsManager.shared.settings) }
                BlockNotificationManager.shared.startReminderTimer(settings: SettingsManager.shared.settings)
                BlockNotificationManager.shared.checkReminders(settings: SettingsManager.shared.settings)
            }
        }
        return true
    }

    // 应用在前台时也弹通知横幅
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Root Tab View (底部标签栏)
struct RootTabView: View {
    @StateObject private var tabState = AppTabState.shared
    @ObservedObject private var styleStore = UIStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme

    private var theme: AppTheme {
        AppTheme(style: styleStore.style, dark: colorScheme == .dark)
    }

    var body: some View {
        TabView(selection: $tabState.selectedTab) {
            NavigationStack { MobilePomoView() }
                .tabItem { Label("Pomo", systemImage: "timer") }
                .tag(0)

            themedTab { TopThreeView() }
                .tabItem { Label("Task", systemImage: "star.fill") }
                .tag(1)

            themedTab { HabiticaHabitsView() }
                .tabItem { Label("Habits", systemImage: "plusminus.circle") }
                .tag(2)

            themedTab { HabiticaDailiesView() }
                .tabItem { Label("Dailies", systemImage: "checkmark.square") }
                .tag(3)

            themedTab { HabiticaProfileView() }
                .tabItem { Label("Role", systemImage: "person.crop.circle") }
                .tag(4)

            MobileSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(9)
        }
        .tint(theme.accent)
        .environment(\.appTheme, theme)
        .toolbarBackground(theme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear { styleStore.applyForcedAppearance() }
    }

    private func themedTab<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.pageBackground.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { SkinPaletteButton() }
                }
                .toolbarBackground(theme.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
