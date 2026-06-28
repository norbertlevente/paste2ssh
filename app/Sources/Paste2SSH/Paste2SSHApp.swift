import AppKit
import SwiftUI

@main
struct Paste2SSHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let state = AppController.shared.state

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    AppController.shared.showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

struct MenuBarLabel: View {
    @Bindable var state: AppState

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: state.connectionPhase, pulsing: state.menuBarPulsing))
    }
}

enum MenuBarIcon {
    private static let onColor = NSColor(srgbRed: 0.28, green: 0.66, blue: 0.58, alpha: 1.0)
    private static let onPulseColor = NSColor(srgbRed: 0.40, green: 0.85, blue: 0.76, alpha: 1.0)

    static func image(for phase: ConnectionPhase, pulsing: Bool) -> NSImage {
        switch phase {
        case .off:
            return templateGlyph()
        case .connecting:
            let glyph = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Connecting") ?? templateGlyph()
            glyph.isTemplate = true
            glyph.size = NSSize(width: 18, height: 18)
            return glyph
        case .on:
            return tinted(templateGlyph(), with: pulsing ? onPulseColor : onColor)
        }
    }

    private static func templateGlyph() -> NSImage {
        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Paste2SSH")
            ?? NSImage()
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    /// Flat-tints the glyph silhouette (used for the teal "on" state). The result is
    /// non-template, so the color is preserved in the menu bar (teal reads in light & dark).
    private static func tinted(_ base: NSImage, with color: NSColor) -> NSImage {
        let size = base.size
        let tintedImage = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tintedImage.isTemplate = false
        return tintedImage
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppController.shared.showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppController.shared.showMainWindow()
        return true
    }
}

@MainActor
final class AppController {
    static let shared = AppController()

    let state = AppState()
    let updater = Updater()
    private var mainWindow: NSWindow?

    private init() {}

    func showMainWindow() {
        let window: NSWindow
        if let existing = mainWindow {
            window = existing
        } else {
            let hostingView = NSHostingView(rootView: MainWindowView(state: state))
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Paste2SSH"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 560, height: 560)
            window.contentAspectRatio = NSSize(width: 1, height: 1)
            window.contentView = hostingView
            window.isReleasedWhenClosed = false
            window.center()
            mainWindow = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettingsWindow() {
        showMainWindow()
        state.selectedPage = .settings
        state.activePanel = nil
    }
}
