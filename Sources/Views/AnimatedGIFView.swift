import AppKit
import SwiftUI

struct AnimatedGIFView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.animates = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.isEditable = false
        // Prevent NSImageView from imposing the GIF's native size on the layout
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        if let image = NSImage(data: data) {
            image.size = .zero // Let the view control sizing, not the image
            imageView.image = image
        }
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if let image = NSImage(data: data) {
            image.size = .zero
            nsView.image = image
        }
        nsView.animates = true
    }
}
