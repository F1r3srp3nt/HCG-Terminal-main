import Foundation

/// A small wrapper around `AsyncStream` used by sessions to publish events.
/// Buffers a bounded number of events so a slow interface cannot grow memory without limit.
public final class EventChannel<Element: Sendable>: Sendable {
    public let stream: AsyncStream<Element>
    private let continuation: AsyncStream<Element>.Continuation

    public init(bufferLimit: Int = 4096) {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(bufferLimit))
        self.stream = stream
        self.continuation = continuation
    }

    public func yield(_ element: Element) {
        continuation.yield(element)
    }

    public func finish() {
        continuation.finish()
    }
}

public extension EventChannel where Element == TerminalEvent {
    /// Writes text to the terminal, converting bare `\n` to `\r\n` as a terminal expects.
    func write(_ text: String) {
        guard !text.isEmpty else { return }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count + 8)
        var previous: UInt8 = 0
        for byte in text.utf8 {
            if byte == 0x0A, previous != 0x0D { bytes.append(0x0D) }
            bytes.append(byte)
            previous = byte
        }
        yield(.output(bytes))
    }
}

/// ANSI styling helpers for text that HCG Terminal itself writes into sessions.
public enum ANSI {
    public static let reset = "\u{1B}[0m"
    public static let bold = "\u{1B}[1m"
    public static let dim = "\u{1B}[2m"
    public static let red = "\u{1B}[31m"
    public static let green = "\u{1B}[32m"
    public static let yellow = "\u{1B}[33m"
    public static let blue = "\u{1B}[34m"
    public static let magenta = "\u{1B}[35m"
    public static let cyan = "\u{1B}[36m"
    public static let clearScreen = "\u{1B}[2J\u{1B}[H"
}
