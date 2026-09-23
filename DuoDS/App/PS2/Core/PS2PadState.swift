import Foundation

/// The DualShock 2 state sent to the PS2 core in one message: a button bit mask in Play!'s
/// `PS2::CControllerInfo::BUTTON` order plus four analog axes (0…255, 127 neutral, +y down).
struct PS2PadState: Equatable, Sendable {
    enum Stick: Sendable { case left, right }

    private(set) var buttons: UInt32 = 0
    private(set) var leftX: UInt8 = 127
    private(set) var leftY: UInt8 = 127
    private(set) var rightX: UInt8 = 127
    private(set) var rightY: UInt8 = 127

    /// libretro joypad id → Play! button index (DPAD_UP = 4 … R3 = 19).
    static let playButtonIndex: [Int: Int] = [
        0: 13,   // B → CROSS
        1: 10,   // Y → SQUARE
        2: 8,    // SELECT
        3: 9,    // START
        4: 4, 5: 5, 6: 6, 7: 7, // UP, DOWN, LEFT, RIGHT
        8: 12,   // A → CIRCLE
        9: 11,   // X → TRIANGLE
        10: 14,  // L → L1
        11: 17,  // R → R1
        12: 15,  // L2
        13: 18,  // R2
        14: 16,  // L3
        15: 19,  // R3
    ]

    /// Sets a button by libretro joypad id; unknown ids are ignored.
    mutating func setButton(libretroID id: Int, pressed: Bool) {
        guard let index = Self.playButtonIndex[id] else { return }
        if pressed { buttons |= 1 << UInt32(index) } else { buttons &= ~(1 << UInt32(index)) }
    }

    /// Analog values −1…1 with +y down.
    mutating func setStick(_ stick: Stick, x: Double, y: Double) {
        switch stick {
        case .left: (leftX, leftY) = (Self.axis(x), Self.axis(y))
        case .right: (rightX, rightY) = (Self.axis(x), Self.axis(y))
        }
    }

    mutating func reset() { self = PS2PadState() }

    /// −1 → 0, 0 → 127 (neutral), +1 → 255.
    static func axis(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 127 }
        let v = min(1, max(-1, value))
        let raw = v < 0 ? 127 + v * 127 : 127 + v * 128
        return UInt8(raw.rounded())
    }

    /// Arguments for `window.duo.setPad(buttons, lx, ly, rx, ry)`.
    var javaScriptArguments: String { "\(buttons),\(leftX),\(leftY),\(rightX),\(rightY)" }
}
