import Foundation

/// What the session should do after feeding keystrokes into the line editor.
public enum LineEditorAction: Equatable, Sendable {
    /// Bytes to echo back to the terminal (redraws, cursor moves, bell).
    case echo([UInt8])
    /// The user pressed Return.
    case submit(String)
    /// Ctrl-C at the prompt (discard the line).
    case interrupt
    /// Ctrl-D on an empty line.
    case endOfInput
    /// Ctrl-L.
    case clearScreen
    /// Tab: completion requested for the text before the cursor.
    case complete(prefix: String)
}

/// A line discipline for sessions that do not have a real PTY (the built-in environment).
/// Supports printable UTF-8, Backspace, Delete, Left/Right, Home/End, Up/Down history,
/// Ctrl-A/E/U/K/W/C/D/L and Tab completion hooks.
public struct LineEditor: Sendable {
    public private(set) var buffer: [Character] = []
    public private(set) var cursor = 0
    public var prompt: String = ""
    /// Visible width of `prompt` (excluding escape sequences).
    public var promptWidth = 0

    private var history: [String] = []
    private var historyIndex: Int?
    private var savedLine: [Character] = []
    private var pending: [UInt8] = []
    private var escape: [UInt8]?

    public init() {}

    public var line: String { String(buffer) }
    public var historyEntries: [String] { history }

    public mutating func addHistory(_ entry: String) {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, history.last != trimmed else { return }
        history.append(trimmed)
        if history.count > 1000 { history.removeFirst(history.count - 1000) }
    }

    public mutating func reset() {
        buffer = []
        cursor = 0
        historyIndex = nil
        savedLine = []
    }

    /// Inserts text programmatically (Tab completion).
    public mutating func insert(_ text: String) -> [UInt8] {
        buffer.insert(contentsOf: Array(text), at: cursor)
        cursor += text.count
        return redraw()
    }

    public mutating func feed(_ bytes: [UInt8]) -> [LineEditorAction] {
        var actions: [LineEditorAction] = []
        var echo: [UInt8] = []

        func flushEcho() {
            if !echo.isEmpty { actions.append(.echo(echo)); echo = [] }
        }

        for byte in bytes {
            if var sequence = escape {
                sequence.append(byte)
                if let result = handleEscape(sequence) {
                    escape = nil
                    echo += result
                } else if sequence.count > 8 {
                    escape = nil
                } else {
                    escape = sequence
                }
                continue
            }

            switch byte {
            case 0x1B:
                escape = [byte]
            case 0x0D, 0x0A:
                let submitted = line
                echo += Array("\r\n".utf8)
                flushEcho()
                actions.append(.submit(submitted))
                reset()
            case 0x7F, 0x08:
                if cursor > 0 {
                    buffer.remove(at: cursor - 1)
                    cursor -= 1
                    echo += redraw()
                } else {
                    echo.append(0x07)
                }
            case 0x03:
                echo += Array("^C\r\n".utf8)
                flushEcho()
                actions.append(.interrupt)
                reset()
            case 0x04:
                if buffer.isEmpty {
                    flushEcho()
                    actions.append(.endOfInput)
                } else if cursor < buffer.count {
                    buffer.remove(at: cursor)
                    echo += redraw()
                }
            case 0x0C:
                flushEcho()
                actions.append(.clearScreen)
            case 0x01:
                cursor = 0; echo += redraw()
            case 0x05:
                cursor = buffer.count; echo += redraw()
            case 0x15:
                buffer.removeSubrange(0..<cursor); cursor = 0; echo += redraw()
            case 0x0B:
                buffer.removeSubrange(cursor..<buffer.count); echo += redraw()
            case 0x17:
                var start = cursor
                while start > 0, buffer[start - 1] == " " { start -= 1 }
                while start > 0, buffer[start - 1] != " " { start -= 1 }
                buffer.removeSubrange(start..<cursor); cursor = start; echo += redraw()
            case 0x09:
                flushEcho()
                actions.append(.complete(prefix: String(buffer[0..<cursor])))
            default:
                if byte < 0x20 { continue }
                pending.append(byte)
                if let text = String(bytes: pending, encoding: .utf8) {
                    pending = []
                    buffer.insert(contentsOf: Array(text), at: cursor)
                    cursor += text.count
                    echo += cursor == buffer.count ? Array(text.utf8) : redraw()
                } else if pending.count >= 4 {
                    pending = []
                }
            }
        }
        flushEcho()
        return actions
    }

    /// Returns bytes to echo when `sequence` is a complete escape sequence, `nil` if incomplete.
    private mutating func handleEscape(_ sequence: [UInt8]) -> [UInt8]? {
        // ESC [ X or ESC O X (application cursor keys), ESC [ n ~
        guard sequence.count >= 2 else { return nil }
        guard sequence[1] == UInt8(ascii: "[") || sequence[1] == UInt8(ascii: "O") else { return [] }
        guard sequence.count >= 3 else { return nil }
        let final = sequence.last!
        if (0x30...0x3F).contains(final) { return nil } // parameter bytes, keep reading
        switch final {
        case UInt8(ascii: "A"): return historyStep(-1)
        case UInt8(ascii: "B"): return historyStep(1)
        case UInt8(ascii: "C"):
            if cursor < buffer.count { cursor += 1; return Array("\u{1B}[C".utf8) }
            return []
        case UInt8(ascii: "D"):
            if cursor > 0 { cursor -= 1; return Array("\u{1B}[D".utf8) }
            return []
        case UInt8(ascii: "H"): cursor = 0; return redraw()
        case UInt8(ascii: "F"): cursor = buffer.count; return redraw()
        case UInt8(ascii: "~"):
            let parameter = String(decoding: sequence[2..<(sequence.count - 1)], as: UTF8.self)
            switch parameter {
            case "3":
                if cursor < buffer.count { buffer.remove(at: cursor); return redraw() }
                return []
            case "1", "7": cursor = 0; return redraw()
            case "4", "8": cursor = buffer.count; return redraw()
            default: return []
            }
        default:
            return []
        }
    }

    private mutating func historyStep(_ delta: Int) -> [UInt8] {
        guard !history.isEmpty else { return [0x07] }
        if historyIndex == nil {
            guard delta < 0 else { return [0x07] }
            savedLine = buffer
            historyIndex = history.count
        }
        let next = historyIndex! + delta
        if next < 0 { return [0x07] }
        if next >= history.count {
            historyIndex = nil
            buffer = savedLine
        } else {
            historyIndex = next
            buffer = Array(history[next])
        }
        cursor = buffer.count
        return redraw()
    }

    /// Redraws prompt and line, then places the cursor.
    public func redraw() -> [UInt8] {
        var out = "\r\u{1B}[K" + prompt + String(buffer)
        let back = buffer.count - cursor
        if back > 0 { out += "\u{1B}[\(back)D" }
        return Array(out.utf8)
    }
}
