import AppKit
import Combine
import MudsUI
import SwiftUI

enum MenuBarPanelLayout {
    static func frame(
        anchor: NSRect,
        screenVisibleFrame: NSRect,
        panelSize: NSSize,
        gap: CGFloat = 4,
        edgeInset: CGFloat = 8
    ) -> NSRect {
        let minX = screenVisibleFrame.minX + edgeInset
        let maxX = max(minX, screenVisibleFrame.maxX - panelSize.width - edgeInset)
        let idealX = round(anchor.midX - panelSize.width / 2)
        let originX = min(max(idealX, minX), maxX)

        let maxHeight = max(200, anchor.minY - gap - screenVisibleFrame.minY - edgeInset)
        let height = min(panelSize.height, maxHeight)
        let originY = anchor.minY - gap - height
        return NSRect(x: originX, y: originY, width: panelSize.width, height: height)
    }
}

@MainActor
final class MenuBarPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

/// Manages the NSStatusItem and an anchored non-draggable NSPanel below the menu bar icon.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    static let shared = MenuBarController()

    private let panelSize = NSSize(width: 390, height: 520)
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    private var unreadCancellable: AnyCancellable?
    private var outsideClickMonitor: Any?

    func start(model: AppModel) {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseDown])
            button.imagePosition = .imageOnly
            button.alignment = .center
            applyStatusImage(unreadCount: model.menuBarUnreadCount, to: button)
        }
        statusItem = item

        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.hidePanel() }

        let rootView = MenuBarPopoverView(onClose: { [weak self] in
            self?.hidePanel()
        }).environmentObject(model)

        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.frame = NSRect(origin: .zero, size: panelSize)
        panel.contentViewController = hosting
        panel.setContentSize(panelSize)
        self.panel = panel

        unreadCancellable = model.$menuBarUnreadCount
            .receive(on: RunLoop.main)
            .sink { [weak self, weak item] count in
                guard let self, let button = item?.button else { return }
                self.applyStatusImage(unreadCount: count, to: button)
            }
    }

    @objc private func handleStatusItemClick(_ sender: Any?) {
        togglePanel(fromUserClick: true)
    }

    func togglePanel(fromUserClick: Bool = false) {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel(fromUserClick: fromUserClick)
        }
    }

    func showPanel(fromUserClick: Bool = false) {
        guard let panel, let resolved = resolveAnchor(useMouseFallback: fromUserClick) else { return }
        let frame = MenuBarPanelLayout.frame(
            anchor: resolved.anchor,
            screenVisibleFrame: resolved.visibleFrame,
            panelSize: panelSize
        )

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(frame, display: true, animate: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        CATransaction.commit()
        NSAnimationContext.endGrouping()

        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem?.button?.highlight(true)
        installOutsideClickMonitor()
    }

    func hidePanel() {
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
    }

    var debugGeometryDescription: String {
        let btn = statusItem?.button?.window?.frame ?? .zero
        let pan = panel?.frame ?? .zero
        let visible = statusItem?.button?.window?.screen?.visibleFrame ?? .zero
        return "button=\(NSStringFromRect(btn)) panel=\(NSStringFromRect(pan)) visible=\(NSStringFromRect(visible)) panelVisible=\(panel?.isVisible ?? false)"
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    private func applyStatusImage(unreadCount: Int, to button: NSStatusBarButton) {
        button.image = ChatMasterGlyph.menuBarImage(unreadCount: unreadCount)
        button.setAccessibilityLabel(unreadCount > 0 ? "ChatMaster，\(unreadCount) 条未读" : "ChatMaster")
    }

    private func resolveAnchor(useMouseFallback: Bool) -> (anchor: NSRect, visibleFrame: NSRect)? {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })

        if let buttonWindow = statusItem?.button?.window {
            let buttonScreen = buttonWindow.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(buttonWindow.frame) })
            if useMouseFallback, let mouseScreen, let buttonScreen, mouseScreen != buttonScreen {
                let menuBarHeight = max(24, mouseScreen.frame.maxY - mouseScreen.visibleFrame.maxY)
                let anchor = NSRect(
                    x: mouse.x - 14,
                    y: mouseScreen.visibleFrame.maxY,
                    width: 28,
                    height: menuBarHeight
                )
                return (anchor, mouseScreen.visibleFrame)
            }
            if let screen = buttonScreen ?? NSScreen.main ?? NSScreen.screens.first {
                return (buttonWindow.frame, screen.visibleFrame)
            }
        }

        guard let fallbackScreen = mouseScreen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let vf = fallbackScreen.visibleFrame
        let anchor = NSRect(x: vf.maxX - 48, y: vf.maxY, width: 28, height: max(24, fallbackScreen.frame.maxY - vf.maxY))
        return (anchor, vf)
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let loc = NSEvent.mouseLocation
                if panel.frame.contains(loc) { return }
                if let btnFrame = self.statusItem?.button?.window?.frame, btnFrame.contains(loc) { return }
                self.hidePanel()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
