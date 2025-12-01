import SwiftUI
import AppKit

// MARK: - App Delegate for splash logic

class AppDelegate: NSObject, NSApplicationDelegate {
    var splashWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        showSplash()
    }
    
    private func showSplash() {
        let splashView = SplashContentView()
        let hosting = NSHostingView(rootView: splashView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear // makes background transparent
        window.level = .mainMenu
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = hosting

        // Constraints to fill the screen
        hosting.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor).isActive = true
        hosting.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor).isActive = true
        hosting.topAnchor.constraint(equalTo: window.contentView!.topAnchor).isActive = true
        hosting.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor).isActive = true

        window.center()
        window.orderFrontRegardless()
        window.alphaValue = 1.0

        splashWindow = window

        // Fade out after 5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.hideSplash()
        }
    }

    
    private func hideSplash() {
        guard let window = splashWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.7
            window.animator().alphaValue = 0
        }, completionHandler: {
            window.orderOut(nil)
            self.splashWindow = nil
            // Focus main window
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        })
    }

    // MARK: - SwiftUI app entry
    
    @main
    struct DVMetaDataBurnInApp: App {
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
        var body: some Scene {
            WindowGroup {
                ContentView()   // NOT SplashView anymore?()
            }
        }
    }
}
