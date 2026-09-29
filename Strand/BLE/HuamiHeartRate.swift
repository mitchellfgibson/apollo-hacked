import Foundation

/// Pure parser for the Huami / Zepp (Amazfit, Mi Band) custom heart-rate notification.
///
/// CLEAN-ROOM. This is NOOP's own implementation written from PUBLICLY DOCUMENTED protocol FACTS about
/// the Huami family (the GATT layout is documented in several open projects — we reuse only the FACTS:
/// service/characteristic UUIDs and the on-wire byte layout — and write our own code). No GPL/AGPL code
/// is copied.
///
/// DOCUMENTED FACT (the layout this parser decodes):
///   • Huami devices expose a custom HR service `0000fee0-…` and a custom HR *measurement*
///     characteristic `00002a37-0000-3512-2118-0009af100700` (note: the same 0x2A37 short form as the
///     standard SIG characteristic, but on the Huami 128-bit base — a DIFFERENT characteristic).
///   • Newer bands also implement the *standard* SIG Heart Rate Service (0x180D / 0x2A37). When a device
///     exposes that, the existing `StandardHRSource` already reads it — we prefer it and never come here.
///   • On the Huami custom characteristic the notification payload is short. The HR value is a single
///     byte. Across documented firmware variants the meaningful byte is either:
///       - a 2-byte `[status, hr]` form (byte 0 a status/flags byte, byte 1 the bpm), or
///       - a 1-byte `[hr]` form.
///     We decode both honestly and never guess beyond them.
///
/// HONESTY: a value of 0 (or 255, the common "no reading"/off-wrist sentinel) is returned as `nil` — we
/// surface "—", never a fabricated number. Out-of-physiological-range values are rejected by the caller's
/// gate (the same 30–220 bpm gate the standard path uses), so this parser only owns the byte extraction.
///
/// SECURITY / ROBUSTNESS: the buffer is UNTRUSTED BLE input. Every read is bounds-checked; an empty or
/// implausible packet yields `nil`, never a crash or a read past the end (mirrors `StandardHeartRate`).
public enum HuamiHeartRate {

    /// Extract the heart rate (bpm) from a Huami custom HR-measurement notification, or `nil` when the
    /// packet carries no usable reading (empty, a 0/255 "no reading" sentinel, or implausibly large).
    ///
    /// - Returns: a bpm in 1...254, or `nil`.
    public static func parse(_ data: [UInt8]) -> Int? {
        guard !data.isEmpty else { return nil }

        // Two documented shapes:
        //   • 1 byte  → [hr]
        //   • 2 bytes → [status, hr]  (the common Huami "HR measurement" notification)
        // For 2+ bytes we take the LAST byte as the bpm: in the [status, hr] form that is the reading,
        // and it degrades safely for the 1-byte form too. We never read past the buffer.
        let hr: Int
        if data.count == 1 {
            hr = Int(data[0])
        } else {
            hr = Int(data[data.count - 1])
        }

        // 0 = no/last-unknown reading; 255 (0xFF) = the common off-wrist / no-contact sentinel. Both are
        // honestly "unknown" → nil so the UI shows "—" rather than a fake 0 or 255.
        guard hr > 0, hr < 255 else { return nil }
        return hr
    }
}
