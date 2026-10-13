import Cocoa
import SwiftUI

final class NotchWindow: NSPanel {
    init(contentView: some View) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        self.isMovable = false
        self.acceptsMouseMovedEvents = true
        
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = hostingView
        
        repositionUnderNotch()
    }

    func repositionUnderNotch() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let screenFrame = screen.frame
        let notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 34.0
        let expansionHeight: CGFloat = 46.0
        let totalHeight = notchHeight + expansionHeight
        
        let islandWidth: CGFloat = 250.0

        let x = screenFrame.origin.x + (screenFrame.width - islandWidth) / 2.0
        let y = screenFrame.maxY - totalHeight

        self.setFrame(NSRect(x: x, y: y, width: islandWidth, height: totalHeight), display: true)
    }
}
