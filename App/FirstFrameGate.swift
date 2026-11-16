import SwiftUI

/// Start library work only after the native Preparing screen has had a frame to draw.
/// An onAppear/task alone can run before SwiftUI commits its first frame.
#if os(iOS)
import UIKit

struct FirstFrameGate: UIViewRepresentable {
    let ready: () -> Void
    func makeUIView(context: Context) -> FrameView { FrameView(ready: ready) }
    func updateUIView(_ view: FrameView, context: Context) {}

    final class FrameView: UIView {
        private var ready: (() -> Void)?
        private var displayLink: CADisplayLink?
        private var ticks = 0
        init(ready: @escaping () -> Void) {
            self.ready = ready
            super.init(frame: .zero)
            isOpaque = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate(); displayLink = nil; ticks = 0
            guard window != nil, ready != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(frameTick))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }
        @objc private func frameTick() {
            ticks += 1
            // Display-link callbacks precede drawing. Wait for the next callback
            // so the first frame can be presented before any WKWebView is created.
            guard ticks >= 2 else { return }
            displayLink?.invalidate(); displayLink = nil
            let action = ready; ready = nil
            action?()
        }
    }
}
#else
import AppKit
import QuartzCore

struct FirstFrameGate: NSViewRepresentable {
    let ready: () -> Void
    func makeNSView(context: Context) -> FrameView { FrameView(ready: ready) }
    func updateNSView(_ view: FrameView, context: Context) {}

    final class FrameView: NSView {
        private var ready: (() -> Void)?
        private var frameLink: CADisplayLink?
        private var ticks = 0
        init(ready: @escaping () -> Void) {
            self.ready = ready
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            frameLink?.invalidate(); frameLink = nil; ticks = 0
            guard window != nil, ready != nil else { return }
            let link = displayLink(target: self, selector: #selector(frameTick))
            frameLink = link
            link.add(to: .main, forMode: .common)
        }
        @objc private func frameTick() {
            ticks += 1
            guard ticks >= 2 else { return }
            frameLink?.invalidate(); frameLink = nil
            let action = ready; ready = nil
            action?()
        }
    }
}
#endif
