import AppKit
import SwiftUI

final class WindowSizeConfigurator: NSObject, NSWindowDelegate {
    let initialSize = NSSize(width: 900, height: 825)
    
    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        
        // Apply initial size only once
        if window.frame.size != initialSize {
            var frame = window.frame
            frame.origin.y += frame.size.height - initialSize.height
            frame.size = initialSize
            window.setFrame(frame, display: true)
        }
    }
}

struct ApplyInitialWindowSize: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                let delegate = WindowSizeConfigurator()
                window.delegate = delegate
                objc_setAssociatedObject(window, "WindowSizeConfigurator", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
