import SwiftUI

#if os(iOS)
typealias ScrollProbeView = UIView
#else
typealias ScrollProbeView = NSView
#endif

/// Observes the enclosing SwiftUI scroll view without replacing its gesture delegate.
@MainActor struct ReaderScrollView {
    let initialOffset: Double
    let onScroll: (Double) -> Void

    @MainActor final class Coordinator {
        var onScroll: (Double) -> Void
        private var timer: Timer?
        private var target: Double?
        private var last: Double = -1
        private var deadline = Date().addingTimeInterval(8)
        private var liveScroll = false
        private var observer: NSObjectProtocol?

        init(_ owner: ReaderScrollView) {
            target = owner.initialOffset > 0 ? owner.initialOffset : nil
            onScroll = owner.onScroll
            #if os(macOS)
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.liveScroll = true }
            }
            #endif
        }
        func attach(_ probe: ScrollProbeView) {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak probe] _ in
                Task { @MainActor in
                    guard let self, let probe else { return }
                    self.sample(probe)
                }
            }
        }
        private func sample(_ probe: ScrollProbeView) {
            #if os(iOS)
            var parent = probe.superview
            while parent != nil && !(parent is UIScrollView) { parent = parent?.superview }
            guard let scroll = parent as? UIScrollView else { return }
            let interacting = scroll.isTracking || scroll.isDragging || scroll.isDecelerating
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
            let offset = scroll.contentOffset.y
            #else
            guard let scroll = probe.enclosingScrollView else { return }
            let interacting = liveScroll
            let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
            let offset = scroll.contentView.bounds.minY
            #endif
            if interacting { target = nil }
            if let target {
                let desired = min(CGFloat(target), maximum)
                #if os(iOS)
                scroll.setContentOffset(CGPoint(x: 0, y: desired), animated: false)
                #else
                scroll.contentView.scroll(to: NSPoint(x: 0, y: desired))
                scroll.reflectScrolledClipView(scroll.contentView)
                #endif
                // Retain the target while asynchronous photos settle. User input wins immediately.
                if Date() < deadline { return }
                self.target = nil
                report(Double(desired))
            } else { report(Double(max(0, offset))) }
        }
        private func report(_ offset: Double) {
            guard abs(last - offset) >= 0.5 else { return }
            last = offset
            onScroll(offset)
        }
        func finish(_ probe: ScrollProbeView) { sample(probe); stop() }
        func stop() {
            timer?.invalidate(); timer = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
        deinit {
            timer?.invalidate()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
}
#if os(iOS)
extension ReaderScrollView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        context.coordinator.attach(view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { context.coordinator.onScroll = onScroll }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.finish(view) }
}
#else
extension ReaderScrollView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.finish(view) }
}
#endif
