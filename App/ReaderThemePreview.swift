import SwiftUI
import WebKit

struct ReaderThemePreview: View {
    let palette: ReaderPalette
    let scheme: ColorScheme
    @State private var height: CGFloat = 64

    var body: some View {
        Sample(palette: palette, scheme: scheme, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

private struct Sample {
    let palette: ReaderPalette
    let scheme: ColorScheme
    @Binding var height: CGFloat

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        var palette: ReaderPalette?

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let pixels = message.body as? Double, pixels.isFinite, pixels > 0 else { return }
            height.wrappedValue = CGFloat(ceil(pixels))
        }
    }

    @MainActor func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    @MainActor func makeSample(_ coordinator: Coordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = config.userContentController
        controller.add(coordinator, name: "sampleHeight")
        // Fit the form row to the sample as the window or reading size changes.
        let measure = """
        new ResizeObserver(() => window.webkit.messageHandlers.sampleHeight.postMessage(
            document.body.getBoundingClientRect().height
        )).observe(document.body);
        """
        controller.addUserScript(WKUserScript(source: measure, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        return WKWebView(frame: .zero, configuration: config)
    }

    @MainActor func updateSample(_ view: WKWebView, coordinator: Coordinator) {
        #if os(iOS)
        view.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        view.scrollView.isScrollEnabled = false
        #else
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        #endif
        guard coordinator.palette != palette else { return }
        coordinator.palette = palette
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(ReaderAppearance.stylesheet(palette))
        body { margin:0; padding:16px; overflow-wrap:anywhere; }
        </style></head><body><article>A little more perspective.</article></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}

#if os(iOS)
extension Sample: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeSample(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { updateSample(view, coordinator: context.coordinator) }
}
#else
extension Sample: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeSample(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { updateSample(view, coordinator: context.coordinator) }
}
#endif
