import AppKit
import Combine
import LensCore
import MudsUI
import SwiftUI
import UserNotifications

enum AppSection: String, CaseIterable, Identifiable {
    case dashboard, chats, pending, insight, briefing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "概览"
        case .chats: return "会话"
        case .pending: return "待回复"
        case .insight: return "关系洞察"
        case .briefing: return "每日简报"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .chats: return "bubble.left.and.bubble.right"
        case .pending: return "tray.full"
        case .insight: return "person.2.wave.2"
        case .briefing: return "newspaper"
        }
    }

    /// Sections where individual messages can be inspected/analyzed in the trailing panel.
    var supportsInspector: Bool {
        switch self {
        case .chats, .pending: return true
        case .dashboard, .insight, .briefing: return false
        }
    }
}

enum LoadState: Equatable {
    case starting
    case importing(String, Double)
    case ready
    case failed(String)
}

enum AnalysisState {
    case loading(Date)
    case done(MessageAnalysis)
    case failed(String)

    var result: MessageAnalysis? { if case .done(let a) = self { return a } else { return nil } }
    var isLoading: Bool { if case .loading = self { return true } else { return false } }
}

enum Prefs {
    static let model = "agyModel"
    static let agyPath = "agyPath"
    static let sidebar = "companionSidebar"
    static let bubble = "clipboardBubble"
    static let autoAnalyze = "autoAnalyzeWatched"
    static let includeOfficial = "includeOfficial"
    static let followOCR = "sidebarFollowOCR"
    static let recallNotify = "recallNotify"
    static let sendWithCommandReturn = "sendWithCommandReturn"
    static let showMutedChats = "showMutedChats"
    private static let migratedFlag = "migratedFromWeChatLens"

    static func register() {
        let defaults: [String: Any] = [
            model: AgyConfig.defaultModel, agyPath: "", sidebar: true, bubble: true, autoAnalyze: true,
            includeOfficial: false, followOCR: true, recallNotify: true, sendWithCommandReturn: false,
            showMutedChats: false,
        ]
        UserDefaults.standard.register(defaults: defaults)
        migrateLegacyIfNeeded()
    }

    private static func migrateLegacyIfNeeded() {
        guard !d.bool(forKey: migratedFlag) else { return }
        if let legacy = UserDefaults(suiteName: "com.mudsuen.WeChatLens") {
            for key in [model, agyPath, sidebar, bubble, autoAnalyze, includeOfficial, followOCR, recallNotify] {
                if d.object(forKey: key) == nil, let val = legacy.object(forKey: key) {
                    d.set(val, forKey: key)
                }
            }
        }
        d.set(true, forKey: migratedFlag)
    }

    static var d: UserDefaults { .standard }
}

@MainActor
final class AppModel: ObservableObject {
    enum DashboardPeriod: String, CaseIterable, Hashable {
        case today, week, month, all

        var title: String {
            switch self {
            case .today: return "今日"
            case .week: return "7 天"
            case .month: return "30 天"
            case .all: return "全部"
            }
        }

        var days: Int? {
            switch self {
            case .today: return 1
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    struct DashboardSnapshot {
        var stats = PeriodStats()
        var pendingCount = 0
        var daily: [DayCount] = []
        var heat: [HeatCell] = []
        var kinds: [KindCount] = []
        var top: [ChatCount] = []
        var period: DashboardPeriod = .today
        var loadedRevision: Int = -1
    }

    struct NavEntry: Equatable {
        var section: AppSection
        var selectedChat: String?
        var insightChat: String?
    }

    static let shared = AppModel()

    @Published var state: LoadState = .starting
    @Published var lastSync: Date?
    @Published var syncErrors: [String] = []
    @Published var revision = 0
    @Published var arrivals: [LensMessage] = []
    @Published var chats: [ChatSummary] = []
    @Published var menuBarChats: [ChatSummary] = []
    @Published var menuBarUnreadCount = 0
    @Published var localUnread: [String: Int] = [:]
    @Published var dashboardPeriod: DashboardPeriod = .today
    @Published var dashboard: DashboardSnapshot?
    var dashboardAnimatedOnce = false
    @Published var searchQuery = ""
    @Published var isSearchOpen = false
    @Published var searchTrigger = 0
    @Published var focusSearchTrigger = 0
    @Published private(set) var navHistory: [NavEntry] = [NavEntry(section: .dashboard, selectedChat: nil, insightChat: nil)]
    @Published private(set) var navIndex = 0
    private var isApplyingHistory = false
    @Published var section: AppSection = .dashboard
    @Published var selectedChat: String?
    @Published var focusedMessageID: Int64?
    @Published var insightChat: String?
    @Published var inspected: LensMessage?
    @Published var analyses: [Int64: AnalysisState] = [:]
    @Published var missingKeys: [String] = []
    @Published var watchlist: Set<String> = []
    @Published var agyModels: [(String, String)] = []
    @Published var totalIndexed = 0
    @Published var recalledChatCounts: [String: Int] = [:]

    private(set) var store: LensStore?
    private(set) var source: WeChatSource?
    private(set) var syncEngine: SyncEngine?
    private(set) var engine: AnalysisEngine?
    private var syncTask: Task<Void, Never>?
    private var avatarCache: [String: NSImage] = [:]
    private var avatarMisses: Set<String> = []
    private var defaultsObserver: AnyCancellable?

    var newMessageHandlers: [([LensMessage]) -> Void] = []
    var chatOpenedHandlers: [(String) -> Void] = []

    private init() {
        Prefs.register()
    }

    var agyConfig: AgyConfig {
        let path = Prefs.d.string(forKey: Prefs.agyPath) ?? ""
        let bin = AgyClient.resolveBinary(path.isEmpty ? nil : path) ?? (path.isEmpty ? "~/.local/bin/agy" : path)
        return AgyConfig(binary: bin, model: Prefs.d.string(forKey: Prefs.model) ?? AgyConfig.defaultModel)
    }

    func start() {
        guard store == nil else { return }
        do {
            let source = try WeChatSource()
            let store = try LensStore()
            self.source = source
            self.store = store
            self.syncEngine = SyncEngine(source: source, store: store)
            self.engine = AnalysisEngine(store: store, config: agyConfig)
            self.missingKeys = source.missingKeyDBs
            self.watchlist = store.watchlist()
            if store.hasData { state = .ready; refresh() }
        } catch {
            state = .failed("无法打开数据源：\(error)\n请先准备本地已解密的数据源配置（all_keys.json）。")
            return
        }
        defaultsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let engine = self.engine else { return }
                let cfg = self.agyConfig
                if engine.config != cfg { engine.config = cfg }
            }
        startSyncLoop()
        if Prefs.d.bool(forKey: Prefs.recallNotify) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        Task { await loadModels() }
        listenForAutomation()
    }

    /// Local automation hook: `com.mudsuen.ChatMaster.navigate` with object `section:<name>`,
    /// `chat:<username>` or `inspect:<message id>`. Used by UI verification scripts.
    private func listenForAutomation() {
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.mudsuen.ChatMaster.navigate"),
                                                            object: nil, queue: .main) { note in
            guard let cmd = note.object as? String else { return }
            MainActor.assumeIsolated {
                let parts = cmd.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                switch parts[0] {
                case "section": if let s = AppSection(rawValue: parts[1]) { self.section = s }
                case "chat": self.openChat(parts[1])
                case "inspect": if let id = Int64(parts[1]), let m = self.store?.message(id: id) { self.inspect(m) }
                case "insight": self.insightChat = parts[1]; self.section = .insight
                case "search":
                    switch parts[1] {
                    case "open": self.isSearchOpen = true
                    case "close": self.isSearchOpen = false
                    default:
                        self.searchQuery = parts[1]
                        self.isSearchOpen = true
                        self.searchTrigger += 1
                    }
                case "popup": CompanionController.shared.openPopup(text: parts[1], source: .clipboard, near: NSEvent.mouseLocation)
                case "diag":
                    let c = CompanionController.shared
                    let info = "ax=\(AXIsProcessTrusted()) frame=\(String(describing: c.tracker.frame)) front=\(c.tracker.isFrontmost) sidebarPref=\(Prefs.d.bool(forKey: Prefs.sidebar)) screen=\(CGPreflightScreenCaptureAccess()) chat=\(c.currentChat ?? "-")"
                    try? info.write(toFile: parts[1], atomically: true, encoding: .utf8)
                case "companion": CompanionController.shared.pin(parts[1] == "follow" ? nil : parts[1])
                default: break
                }
            }
        }
    }

    func loadModels() async {
        let bin = agyConfig.binary
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        let models = await AgyClient.listModels(binary: bin)
        if !models.isEmpty { agyModels = models }
    }

    private func startSyncLoop() {
        guard let syncEngine else { return }
        syncTask = Task.detached(priority: .utility) { [weak self] in
            var first = true
            while !Task.isCancelled {
                let result = syncEngine.sync { p in
                    guard first else { return }
                    let frac = p.total > 0 ? Double(p.done) / Double(p.total) : 0
                    Task { @MainActor [weak self] in
                        guard let self, self.state != .ready else { return }
                        self.state = .importing(p.phase, frac)
                    }
                }
                first = false
                await self?.apply(result)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func syncNow() {
        guard let syncEngine else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = syncEngine.sync(force: false)
            await self?.apply(r)
        }
    }

    private func apply(_ r: SyncEngine.Result) {
        lastSync = Date()
        syncErrors = r.errors
        if state != .ready { state = .ready }
        if r.inserted > 0 || r.metaChanged || chats.isEmpty {
            refresh()
        }
        if !r.openedChats.isEmpty {
            for opened in r.openedChats { localUnread.removeValue(forKey: opened) }
            recomputeMenuBarState()
            if let opened = r.openedChats.last {
                for h in chatOpenedHandlers { h(opened) }
            }
        }
        if !r.recalled.isEmpty {
            for m in r.recalled {
                notifyRecall(m)
                if !m.isSelf {
                    let id = m.id
                    ToastCenter.shared.show(.warning, "\(senderLabel(m)) 撤回了一条消息", m.text, action: "查看") { [weak self] in
                        self?.openRecall(id: id)
                    }
                }
            }
            refresh()
        }
        if !r.newMessages.isEmpty {
            let fresh = r.newMessages.sorted { $0.ts < $1.ts }
            arrivals = Array((arrivals + fresh).suffix(200))
            updateLocalUnread(with: fresh)
            for h in newMessageHandlers { h(fresh) }
            autoAnalyze(fresh)
        }
    }

    func effectiveUnread(for chat: ChatSummary) -> Int {
        max(chat.unread, localUnread[chat.username] ?? 0)
    }

    func markMenuBarRead(_ chat: String) {
        if localUnread.removeValue(forKey: chat) != nil {
            recomputeMenuBarState()
        }
    }

    private func updateLocalUnread(with fresh: [LensMessage]) {
        var changed = false
        let weChatActive = CompanionController.shared.tracker.isFrontmost
        for m in fresh {
            if m.isSelf {
                if localUnread.removeValue(forKey: m.chat) != nil { changed = true }
            } else if !m.isSystem && !weChatActive {
                guard let summary = menuBarChats.first(where: { $0.username == m.chat }) else { continue }
                if summary.unread == 0 {
                    localUnread[m.chat, default: 0] += 1
                    changed = true
                }
            }
        }
        if changed { recomputeMenuBarState() }
    }

    private func recomputeMenuBarState() {
        menuBarChats.sort { a, b in
            let au = effectiveUnread(for: a) > 0
            let bu = effectiveUnread(for: b) > 0
            if au != bu { return au }
            return a.lastTs > b.lastTs
        }
        menuBarUnreadCount = menuBarChats.reduce(0) { $0 + effectiveUnread(for: $1) }
    }

    func refresh() {
        guard let store else { return }
        let official = Prefs.d.bool(forKey: Prefs.includeOfficial)
        chats = store.chatList(includeOfficial: official)
        menuBarChats = store.menuBarChats(limit: 40)
        recomputeMenuBarState()
        totalIndexed = store.totalMessages()
        recalledChatCounts = store.recalledChatCounts()
        revision += 1
    }

    func loadDashboard(force: Bool = false) {
        guard let store else { return }
        let period = dashboardPeriod
        if !force, let cur = dashboard, cur.period == period, abs(revision - cur.loadedRevision) < 20 {
            return
        }
        let rev = revision
        Task.detached(priority: .userInitiated) { [weak self] in
            let stats = store.periodStats(days: period.days)
            let pendingCount = store.pendingReplies().count
            let daily = store.dailyCounts(days: 182)
            let heat = store.heatmap()
            let kinds = store.kindCounts()
            let top = store.topChats(days: period.days ?? 3650, limit: 10)
            let snap = DashboardSnapshot(
                stats: stats, pendingCount: pendingCount, daily: daily, heat: heat,
                kinds: kinds, top: top, period: period, loadedRevision: rev
            )
            await MainActor.run { [weak self] in
                guard let self, self.dashboardPeriod == period else { return }
                self.dashboard = snap
            }
        }
    }

    // MARK: - recall protection

    private func notifyRecall(_ m: LensMessage) {
        guard !m.isSelf, Prefs.d.bool(forKey: Prefs.recallNotify) else { return }
        let c = UNMutableNotificationContent()
        let who = senderLabel(m)
        c.title = "\(who) 撤回了一条消息"
        if m.chat.hasSuffix("@chatroom") { c.subtitle = displayName(m.chat) }
        c.body = m.text
        c.sound = .default
        c.userInfo = ["messageID": m.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "recall-\(m.id)", content: c, trigger: nil))
    }

    func openRecall(id: Int64) {
        guard let m = store?.message(id: id) else { return }
        openChat(m.chat, focusMessage: m)
    }

    // MARK: - names / avatars

    func displayName(_ username: String?) -> String { store?.displayName(username) ?? (username ?? "") }

    func chatKind(_ username: String) -> ChatKind { store?.contact(username)?.kind ?? Contact.kind(of: username) }

    func senderLabel(_ m: LensMessage) -> String {
        if m.isSelf { return "我" }
        return displayName(m.sender ?? m.chat)
    }

    func avatar(_ username: String) -> NSImage? {
        if let img = avatarCache[username] { return img }
        if avatarMisses.contains(username) { return nil }
        if let data = source?.avatar(for: username), let img = NSImage(data: data) {
            avatarCache[username] = img
            return img
        }
        avatarMisses.insert(username)
        return nil
    }

    // MARK: - analysis

    func analysisState(_ id: Int64) -> AnalysisState? {
        if let s = analyses[id] { return s }
        if let cached = engine?.cachedAnalysis(messageID: id) {
            return .done(cached)
        }
        return nil
    }

    func analyze(_ m: LensMessage, force: Bool = false) {
        guard let engine else { return }
        if case .loading = analyses[m.id] { return }
        if !force, let cached = engine.cachedAnalysis(messageID: m.id) {
            analyses[m.id] = .done(cached)
            return
        }
        analyses[m.id] = .loading(Date())
        Task {
            do {
                let a = try await engine.analyze(message: m, force: force)
                analyses[m.id] = .done(a)
            } catch {
                analyses[m.id] = .failed(error.localizedDescription)
                ToastCenter.shared.show(.error, "分析失败", error.localizedDescription)
            }
        }
    }

    func inspect(_ m: LensMessage, analyze run: Bool = true) {
        inspected = m
        if run { analyze(m) }
    }

    func setWatched(_ chat: String, _ on: Bool) {
        store?.setWatched(chat, on)
        watchlist = store?.watchlist() ?? []
    }

    private func autoAnalyze(_ msgs: [LensMessage]) {
        guard Prefs.d.bool(forKey: Prefs.autoAnalyze), !watchlist.isEmpty else { return }
        for m in msgs where !m.isSelf && m.isTextual && watchlist.contains(m.chat) {
            analyze(m)
        }
    }

    var canGoBack: Bool { navIndex > 0 }
    var canGoForward: Bool { navIndex + 1 < navHistory.count }

    func navigate(to target: AppSection) {
        isSearchOpen = false
        section = target
        recordNavigation()
    }

    func recordNavigation() {
        guard !isApplyingHistory else { return }
        let entry = NavEntry(section: section, selectedChat: selectedChat, insightChat: insightChat)
        if navHistory[navIndex] == entry { return }
        if navIndex + 1 < navHistory.count {
            navHistory.removeSubrange((navIndex + 1)...)
        }
        navHistory.append(entry)
        if navHistory.count > 50 {
            navHistory.removeFirst(navHistory.count - 50)
        }
        navIndex = navHistory.count - 1
    }

    func goBack() {
        guard canGoBack else { return }
        navIndex -= 1
        applyHistory(navHistory[navIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        navIndex += 1
        applyHistory(navHistory[navIndex])
    }

    private func applyHistory(_ entry: NavEntry) {
        isApplyingHistory = true
        section = entry.section
        selectedChat = entry.selectedChat
        if let ic = entry.insightChat { insightChat = ic }
        isApplyingHistory = false
    }

    func submitGlobalSearch() {
        isSearchOpen = true
        searchTrigger += 1
    }

    func openChat(_ chat: String, focusMessage: LensMessage? = nil) {
        markMenuBarRead(chat)
        isSearchOpen = false
        selectedChat = chat
        section = .chats
        focusedMessageID = focusMessage?.id
        if let focusMessage {
            inspect(focusMessage, analyze: false)
        }
        recordNavigation()
        showMainWindow()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            WindowOpener.shared.open?()
        }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("ChatMaster.openMainWindow")
}
