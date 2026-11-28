import AppKit
import LensCore
import MudsUI
import SwiftUI
import UserNotifications

@main
struct ChatMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("ChatMaster", id: "main") {
            RootView()
                .environmentObject(model)
                .background(OpenWindowCapture())
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("立即同步") { model.syncNow() }.keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(model)
        }

        MenuBarExtra {
            MenuBarPopoverView().environmentObject(model)
        } label: {
            MenuBarLabel(unreadCount: model.menuBarUnreadCount)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps a reference to SwiftUI's openWindow action so AppKit code can reopen the main window.
struct OpenWindowCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { WindowOpener.shared.open = { openWindow(id: "main") } }
    }
}

@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated {
            MUClipboard.didCopy = { ClipboardGuard.ownChangeCount = $0 }
            AppModel.shared.start()
            CompanionController.shared.start()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["messageID"] as? Int64 {
            DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.openRecall(id: id) } }
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { WindowOpener.shared.open?() } }
        return true
    }
}
