import UIKit
import UniformTypeIdentifiers

/// Text a US HID keyboard cannot type (Chinese, emoji, line breaks) goes through the clipboard and Cmd+V.
///
/// ASCII stays on the keyboard path: pasting replaces whatever the user had copied, and some fields
/// refuse paste. iOS never lets a background app read the clipboard, and nothing documents writing to
/// it from the background, so a write counts only when the pasteboard's change count moves.
@MainActor protocol Clipboard: AnyObject {
    /// True once the text is on the clipboard.
    func put(_ text: String) -> Bool
}

/// The general pasteboard, local only (no Universal Clipboard) and expiring soon after the paste.
@MainActor final class SystemClipboard: Clipboard {
    static let lifetime: TimeInterval = 60

    func put(_ text: String) -> Bool {
        let board = UIPasteboard.general, before = board.changeCount
        let appState = UIApplication.shared.applicationState
        DebugLog.write("clipboard put: '\(text.prefix(20))' state \(appState.rawValue) hasStrings \(board.hasStrings) hasURLs \(board.hasURLs) changeCount \(before) string '\(board.string?.prefix(20) ?? "nil")'")
        board.string = text
        let afterString = board.changeCount
        DebugLog.write("clipboard after string=: changeCount \(afterString) string '\(board.string?.prefix(20) ?? "nil")' hasStrings \(board.hasStrings) strings \(board.strings?.map { $0.prefix(10) } ?? []) items \(board.items.count)")
        if afterString != before { DebugLog.write("clipboard put: wrote via string"); return true }
        board.setItems([[UTType.utf8PlainText.identifier: text]],
                       options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(Self.lifetime)])
        let afterItems = board.changeCount
        DebugLog.write("clipboard after setItems: changeCount \(afterItems) string '\(board.string?.prefix(20) ?? "nil")' hasStrings \(board.hasStrings) items \(board.items.count)")
        if afterItems != before { DebugLog.write("clipboard put: wrote via setItems"); return true }
        // Third attempt: the old public.utf8-plain-text key without localOnly
        board.setValue(text, forPasteboardType: "public.utf8-plain-text")
        let afterValue = board.changeCount
        DebugLog.write("clipboard after setValue public.utf8-plain-text: changeCount \(afterValue) string '\(board.string?.prefix(20) ?? "nil")'")
        let ok = afterValue != before
        if !ok { DebugLog.write("clipboard put: FAILED, before \(before) after \(afterValue)") }
        return ok
    }
}

enum PasteInput {
    static func needed(_ text: String) -> Bool { !text.utf8.allSatisfy { $0 >= 32 && $0 < 127 } }

    @MainActor static func paste(_ text: String, clipboard: Clipboard, device: HIDDevice, log: (String) -> Void) async throws {
        guard clipboard.put(text) else {
            throw DeviceError(message: "無法寫入剪貼簿，未輸入文字。")
        }
        try await device.send("key cmd+v")
        log("keyboard: pasted \(text.count) characters")
    }
}
