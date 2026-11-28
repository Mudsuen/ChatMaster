import AppKit
import LensCore
import MudsUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Prefs.model) private var agyModel = AgyConfig.defaultModel
    @AppStorage(Prefs.agyPath) private var agyPath = ""
    @AppStorage(Prefs.sidebar) private var sidebar = true
    @AppStorage(Prefs.bubble) private var bubble = true
    @AppStorage(Prefs.autoAnalyze) private var autoAnalyze = true
    @AppStorage(Prefs.includeOfficial) private var includeOfficial = false
    @AppStorage(Prefs.followOCR) private var followOCR = true
    @AppStorage(Prefs.recallNotify) private var recallNotify = true
    @AppStorage(Prefs.sendWithCommandReturn) private var sendWithCommandReturn = false
    @State private var testState = ""
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var screenOK = CGPreflightScreenCaptureAccess()

    var body: some View {
        TabView {
            Form {
                Section("数据源") {
                    LabeledContent("微信账号", value: model.source?.selfUsername ?? "—")
                    LabeledContent("密钥文件", value: LensPaths.keysFile.path)
                    LabeledContent("数据库目录") {
                        Text(model.source?.keyFile.dbDir ?? "—").lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    LabeledContent("已索引", value: "\(model.totalIndexed) 条")
                    LabeledContent("本地索引", value: LensPaths.indexDB.path)
                    LabeledContent("同步状态") {
                        HStack(spacing: 8) {
                            if model.syncErrors.isEmpty {
                                Text(model.lastSync.map { "正常 · \(Fmt.time.string(from: $0))" } ?? "等待首次同步")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(model.syncErrors.first ?? "同步异常")
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Button("立即同步") { model.syncNow() }
                                .controlSize(.small)
                        }
                    }
                    if !model.missingKeys.isEmpty {
                        Text("这些新数据库还没有配置密钥：\(model.missingKeys.joined(separator: "、"))。请先更新本地数据源配置（all_keys.json）。")
                            .foregroundStyle(.orange)
                    }
                    Toggle("显示公众号/服务通知", isOn: $includeOfficial)
                        .onChange(of: includeOfficial) { _, _ in model.refresh() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("数据", systemImage: "externaldrive") }

            Form {
                Section("agy CLI") {
                    TextField("agy 路径（留空自动查找）", text: $agyPath, prompt: Text(model.agyConfig.binary))
                    Picker("模型", selection: $agyModel) {
                        if model.agyModels.isEmpty { Text(agyModel).tag(agyModel) }
                        ForEach(model.agyModels, id: \.0) { m in Text("\(m.1)").tag(m.0) }
                    }
                    HStack {
                        Button("测试连接") { test() }
                        Button("刷新模型列表") { Task { await model.loadModels() } }
                        Text(testState).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Text("快速模型（Flash Low）一般 6–15 秒；Pro/Opus 更准但更慢。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("隐私") {
                    Text("消息分析会把目标消息和必要的上下文发给 agy 所用的云端模型。只有你点「分析」，或开启了自动分析的关注会话，才会发送；不会上传全量历史。agy 在空目录里以 --sandbox 运行，并被要求不使用任何工具。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("分析", systemImage: "sparkles") }

            Form {
                Section("微信伴侣") {
                    Toggle("吸附侧栏（贴在微信窗口旁）", isOn: $sidebar)
                    Toggle("复制即分析：在微信复制消息后弹出「分析」气泡", isOn: $bubble)
                    Toggle("关注会话的新消息自动分析", isOn: $autoAnalyze)
                    Toggle("用 OCR 识别微信当前打开的会话", isOn: $followOCR)
                }
                Section("防撤回") {
                    Toggle("有人撤回消息时发系统通知（附原文）", isOn: $recallNotify)
                    Text("ChatMaster 每 2 秒同步一次并保留已索引消息的原文。只有 ChatMaster 运行时才能保护；文字可完整保留，图片/语音等只保留类型。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("MenuBar 快捷回复") {
                    Picker("发送快捷键", selection: $sendWithCommandReturn) {
                        Text("Return（回车直接发送）").tag(false)
                        Text("⌘Return（Command + 回车发送）").tag(true)
                    }
                    Text("从顶部菜单栏直接回复时，会通过辅助功能激活微信并定位当前会话后粘贴发送。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("权限") {
                    LabeledContent("辅助功能（定位微信窗口）") {
                        permissionRow(ok: axTrusted) {
                            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                            AXIsProcessTrustedWithOptions(opts)
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    LabeledContent("屏幕录制（OCR）") {
                        permissionRow(ok: screenOK) {
                            CGRequestScreenCaptureAccess()
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                Section("快捷键") {
                    LabeledContent("框选屏幕 → OCR → 分析", value: "⌃⌥A")
                    LabeledContent("分析剪贴板文字", value: "⌃⌥V")
                    LabeledContent("显示/隐藏侧栏", value: "⌃⌥S")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("伴侣", systemImage: "rectangle.righthalf.inset.filled") }
            .onAppear { axTrusted = AXIsProcessTrusted(); screenOK = CGPreflightScreenCaptureAccess() }
        }
        .toggleStyle(LiquidToggleStyle())
        .tint(DS.pick)
        .frame(width: 580, height: 500)
    }

    private func permissionRow(ok: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(ok ? .green : .orange)
            Text(ok ? "已授权" : "未授权")
            if !ok { Button("去授权", action: request) }
        }
    }

    private func test() {
        let cfg = model.agyConfig
        testState = "测试中…"
        Task {
            let started = Date()
            let models = await AgyClient.listModels(binary: cfg.binary)
            testState = models.isEmpty
                ? "无法运行 \(cfg.binary)"
                : "可用 · \(models.count) 个模型 · \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
            if !models.isEmpty { model.agyModels = models }
        }
    }
}
