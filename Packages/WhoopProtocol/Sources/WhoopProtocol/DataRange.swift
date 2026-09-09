import Foundation

/// GET_DATA_RANGE (command 34) COMMAND_RESPONSE decoding.
///
/// The strap answers GET_DATA_RANGE with a fixed-layout block, NOT with a scatter of timestamps to be
/// hunted for. The previous in-app decoder walked the frame in 4-byte steps and accepted ANY word in
/// 1_700_000_000…1_900_000_000 as a timestamp, taking min for "oldest" and max for "newest". That band is
/// 6.3 years wide, so ring-buffer page counters, byte offsets and straddling (mis-aligned) reads all pass
/// it, and one spurious low word poisons `oldest` for the whole session. On a real WHOOP 5/MG capture the
/// old scan reported "oldest = 2029-10-06" — a straddle word, not a date the strap ever sent.
///
/// LAYOUT (offsets relative to `cmdOff`, the byte holding the echoed command number 34):
///
///     cmdOff + 0   u8    echoed command number (34 = GET_DATA_RANGE)
///     cmdOff + 1   u8    origin sequence (the seq of the command we sent)
///     cmdOff + 2   u8    result: 0 FAILURE, 1 SUCCESS, 2 PENDING, 3 UNSUPPORTED
///     cmdOff + 3   u8    payload subtype/version (0x01 in every SUCCESS capture)
///     cmdOff + 4 + 4*i   u32 LE  word V(i), i = 0…15   (the whole answer is exactly 16 words)
///     …then 2 pad bytes, then the frame's CRC32 trailer.
///
/// The words we name (everything else is deliberately left unnamed rather than guessed):
///
///     V(2)  write pointer  W   — ring page most recently written
///     V(3)  read pointer   U   — ring page the strap has been acked up to
///     V(5)  ring capacity  T   — 131072 in every capture seen so far, still read per-frame
///     V(8)  oldest         — unix seconds of the oldest record still retained in flash
///     V(10) cursor         — unix seconds of the oldest record NOT yet offloaded (== V(12) in every capture)
///     V(14) newest         — unix seconds of the newest record the strap holds
///
/// EVIDENCE. W/U/T are upstream's (ryanbr/noop) hardware-confirmed mapping: `DataRange.pagesBehind`
/// (Packages/WhoopProtocol/Sources/WhoopProtocol/DataRange.swift:60-89 upstream) states the same three
/// offsets and its `testPagesBehind_realCaptures` (DataRangeTests.swift:111-128 upstream) pins them against
/// four real frames — one WHOOP 4.0 and three WHOOP 5.0/MG. Those same four frames are the evidence for the
/// timestamp words here: reading V(8)/V(10)/V(14) off each of them yields a consistent
/// oldest ≤ cursor ≤ newest window, and for the MG frame upstream independently asserts
/// history_oldest = 1778377136 and history_newest = 1780926332 (Whoop5CommandResponseTests.swift:38-49
/// upstream) — exactly V(8) and V(14). The fixed-offset read reproduces upstream's own numbers.
///
/// NOT ASSERTED: upstream never claims a fixed offset for these timestamps (its own newest/oldest readers
/// are still scans), the meaning of V(0)/V(1)/V(4)/V(6)/V(7)/V(9)/V(11)/V(13)/V(15) is unknown, and the
/// 16-word length has only been seen on firmware that produces an 80-byte (4.0) / 84-byte (5/MG) frame.
/// Everything here therefore fails CLOSED: a frame that does not match returns `.unrecognised`, never a
/// date. See `DataRangeParse`.
public enum DataRange {

    /// Decoded, validated GET_DATA_RANGE window.
    public struct Window: Equatable, Sendable {
        /// V(8): oldest record still in flash. `nil` when the strap reports a sentinel instead of a real
        /// date — a WHOOP 4.0 capture carries 1262044800 (2010-01-01), i.e. "not set" — so the caller
        /// shows "unknown" rather than a fabricated day.
        public let oldest: Int?
        /// V(10): oldest record not yet offloaded (the strap's own trim cursor).
        public let cursor: Int
        /// V(14): newest record the strap holds.
        public let newest: Int
        /// V(2) − V(3) over the ring V(5). DIAGNOSTIC ONLY — never gate sync on it.
        public let pagesBehind: Int?
    }

    /// Outcome of decoding a GET_DATA_RANGE COMMAND_RESPONSE. `unrecognised` carries a human-readable
    /// reason so an unknown firmware shows up in the strap log as a decode failure instead of silently
    /// printing a wrong date (the failure mode this type exists to end).
    public enum Parse: Equatable {
        case window(Window)
        /// The result byte is PENDING(2). GET_DATA_RANGE answers twice — a short ack, then the payload —
        /// so this is normal traffic, not a fault, and the caller should stay quiet and wait.
        case pending
        case unrecognised(reason: String)
    }

    /// Command number of GET_DATA_RANGE on both families.
    public static let getDataRangeCommand: UInt8 = 34
    /// Records older than this are a firmware sentinel, not data (2020-01-01).
    public static let minPlausibleUnix = 1_577_836_800
    /// How far ahead of the wall clock a "newest" may sit before the strap's RTC is the likelier
    /// explanation than real data. Matches upstream's auto-continue skew.
    public static let futureSkewSeconds = 48 * 3600

    /// Offset of the echoed command byte IF `frame` is a GET_DATA_RANGE COMMAND_RESPONSE, else nil.
    ///
    /// The packet-type gate is the half the old code was missing, and it is not optional:
    ///  • WHOOP 4.0 — a 20-byte EVENT frame (type 48) for BLE_REALTIME_HR_OFF also carries 34 at frame[6]
    ///    (it is the EVENT NUMBER there, not a command), and its `event_timestamp` sits at frame[8]. Any
    ///    decoder keyed on frame[6] alone reads live HR-off events as data-range answers.
    ///  • WHOOP 5/MG — the puffin envelope puts the inner record at 8, so frame[6] is the low byte of the
    ///    CRC16 header checksum. It equals 0x22 for whole classes of frame LENGTH (a CRC over
    ///    `AA 01 len len hdr hdr`), so the match is not even rare — it is deterministic per length, and
    ///    every frame of a colliding size is misread.
    public static func responseCommandOffset(in frame: [UInt8], family: DeviceFamily) -> Int? {
        let typeOffset: Int
        switch family {
        case .whoop5: typeOffset = 8   // puffin: [8]=type [9]=seq [10]=cmd (same split as isOffloadFrame)
        case .whoop4: typeOffset = 4   // 4.0:    [4]=type [5]=seq [6]=cmd
        }
        guard frame.count > typeOffset + 2 else { return nil }
        // 36 COMMAND_RESPONSE; 38 PUFFIN_COMMAND_RESPONSE is its 5/MG alias (see canonicalTypeName).
        guard frame[typeOffset] == 36 || frame[typeOffset] == UInt8(PuffinPacketType.puffinCommandResponse)
        else { return nil }
        guard frame[typeOffset + 2] == getDataRangeCommand else { return nil }
        return typeOffset + 2
    }

    /// Decode the 16-word answer at `cmdOff`. Pure; `now` is injected so the future-date guard is testable.
    public static func parse(_ frame: [UInt8], cmdOff: Int, now: Int) -> Parse {
        guard cmdOff >= 0, cmdOff + 2 < frame.count else {
            return .unrecognised(reason: "frame too short to hold a result byte")
        }
        let result = frame[cmdOff + 2]
        if result == 2 { return .pending }
        guard result == 1 else {
            return .unrecognised(reason: "strap answered result=\(result) (not SUCCESS)")
        }
        // 16 u32 words start at cmdOff+4; the last one ends at cmdOff+68.
        let wordsEnd = cmdOff + 4 + 16 * 4
        guard frame.count >= wordsEnd else {
            return .unrecognised(reason: "SUCCESS payload is \(frame.count - cmdOff) B from the command "
                                 + "byte, expected \(wordsEnd - cmdOff) B for 16 words")
        }
        func word(_ i: Int) -> Int {
            let o = cmdOff + 4 + i * 4
            return Int(frame[o]) | Int(frame[o + 1]) << 8 | Int(frame[o + 2]) << 16 | Int(frame[o + 3]) << 24
        }
        let cursor = word(10), newest = word(14), oldestWord = word(8)
        // Plausibility is now a CHECK on known fields, not a filter used to find them: a value outside the
        // window means the layout doesn't hold on this firmware, so refuse the whole frame.
        let ceiling = now + futureSkewSeconds
        guard cursor >= minPlausibleUnix, cursor <= ceiling else {
            return .unrecognised(reason: "cursor word V(10)=\(cursor) is not a plausible unix time")
        }
        guard newest >= minPlausibleUnix, newest <= ceiling else {
            return .unrecognised(reason: "newest word V(14)=\(newest) is not a plausible unix time")
        }
        guard newest >= cursor else {
            return .unrecognised(reason: "newest V(14)=\(newest) precedes cursor V(10)=\(cursor)")
        }
        // A sentinel oldest (2010-01-01 on 4.0) is reported as "unknown", not as a date, and never
        // drags the window backwards.
        let oldest: Int? = (oldestWord >= minPlausibleUnix && oldestWord <= cursor) ? oldestWord : nil
        return .window(Window(oldest: oldest, cursor: cursor, newest: newest,
                              pagesBehind: pagesBehind(write: word(2), read: word(3), capacity: word(5))))
    }

    /// Ring backlog in pages, or nil when the pointers are implausible. Same formula and guards as
    /// upstream's `pagesBehind` (its offsets are hardware-confirmed on both families); DIAGNOSTIC ONLY.
    static func pagesBehind(write w: Int, read u: Int, capacity t: Int) -> Int? {
        guard t > 0, t <= 0x00FF_FFFF, w < t, u < t else { return nil }
        let behind = w < u ? w + (t - u) : w - u
        guard behind >= 0, behind <= t else { return nil }
        return behind
    }
}
