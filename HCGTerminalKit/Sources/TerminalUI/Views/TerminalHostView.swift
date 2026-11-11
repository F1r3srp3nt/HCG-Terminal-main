#if canImport(UIKit) && canImport(SwiftUI)
import SwiftTerm
import SwiftUI
import TerminalCore
import UIKit

/// Hosts SwiftTerm's xterm-compatible `TerminalView` for one session. Give each session its
/// own instance with `.id(session.id)`.
struct TerminalHostView: UIViewRepresentable {
    let session: SessionModel
    let accent: Color
    var fontSize: CGFloat = 13

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(HCGPalette.canvas)
        view.nativeForegroundColor = UIColor(HCGPalette.ivory)
        view.caretColor = UIColor(accent)
        view.keyboardAppearance = .dark
        context.coordinator.bind(view)
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        view.caretColor = UIColor(accent)
    }

    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.unbind()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let session: SessionModel

        init(session: SessionModel) {
            self.session = session
        }

        func bind(_ view: SwiftTerm.TerminalView) {
            let replay = session.replay
            if !replay.isEmpty { view.feed(byteArray: replay[...]) }
            session.outputSink = { [weak view] bytes in
                view?.feed(byteArray: bytes[...])
            }
        }

        func unbind() {
            session.outputSink = nil
        }

        // MARK: TerminalViewDelegate

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            session.resize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            if !title.isEmpty { session.title = title }
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session.send(Array(data))
        }

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: SwiftTerm.TerminalView) {}

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
#endif
