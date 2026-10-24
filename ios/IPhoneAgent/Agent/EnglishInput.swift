import Foundation

/// The hardware-keyboard input source for ASCII HID text.
///
/// iOS routes hardware keys through the selected input method: Zhuyin turns
/// letters and digits into Bopomofo. The JIS 英数 key (HID LANG2) selects the
/// Latin source directly and leaves it selected if it already is. Physical
/// tests from Zhuyin, Traditional and Japanese handwriting typed exact mixed
/// case ASCII right after it. Control-Space instead toggles recent sources:
/// it needs the source menu, frames and OCR, and a held Control repeat types
/// full-width spaces into Chinese sources.
enum EnglishInput {
    @MainActor static func ensure(device: HIDDevice, log: (String) -> Void) async throws {
        do { try await device.send("key eisu") }
        catch let error as DeviceError where error.message.hasSuffix("unknown key") {
            throw DeviceError(message: "開發板韌體不支援英數鍵切換輸入來源，未輸入文字。請更新開發板韌體後再試。")
        }
        log("keyboard: English selected with the 英数 key")
    }
}
