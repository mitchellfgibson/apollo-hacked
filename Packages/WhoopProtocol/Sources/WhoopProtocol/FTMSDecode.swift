import Foundation

// MARK: - FTMS (Fitness Machine Service, 0x1826) pure decoders
//
// Spec-deterministic field parsing for the four FTMS machine-data characteristics NOOP reads live:
//   • Treadmill Data        0x2ACD
//   • Cross Trainer Data    0x2ACE
//   • Rower Data            0x2AD1
//   • Indoor Bike Data      0x2AD2
//
// Each characteristic begins with a little-endian flags field (u16 for treadmill/cross-trainer/rower,
// u16 for indoor bike too) whose bits gate which fields follow, in a FIXED spec order. We decode the
// flag-gated fields we surface (speed, cadence, power, distance, total energy, heart rate, elapsed
// time) and IGNORE the rest by advancing the cursor by their spec width — so an unrecognised optional
// field never desynchronises the ones after it.
//
// SECURITY / ROBUSTNESS: the byte buffer is UNTRUSTED BLE input. Every field read is bounds-checked
// against the buffer length; a truncated/malformed packet yields the fields decoded so far (never a
// crash, never a read past the end). This mirrors the bounds discipline in `StandardHeartRate.parse`.
//
// This is a PURE value type with no CoreBluetooth dependency, so it lives in WhoopProtocol and is unit
// tested headlessly (`swift test`) against byte fixtures built from the FTMS spec — exactly like the
// existing biometric stream decoders. The app-target `FTMSSource` (CoreBluetooth glue) calls in here.
//
// Reference: Bluetooth SIG "Fitness Machine Service" 1.0 (FTMS_v1.0) and "GATT Specification
// Supplement" characteristic field tables. NOOP's own clean re-implementation of the public spec.

/// The kind of FTMS machine, identified by which machine-data characteristic it streams.
public enum FTMSMachineKind: String, Sendable, Equatable, Codable {
    case treadmill, indoorBike, rower, crossTrainer

    /// 16-bit characteristic UUID (the assigned-number short form) this machine streams.
    public var characteristicUUID16: String {
        switch self {
        case .treadmill:    return "2ACD"
        case .crossTrainer: return "2ACE"
        case .rower:        return "2AD1"
        case .indoorBike:   return "2AD2"
        }
    }

    /// A human label for the live machine readout / workout naming. Honest, no claims beyond the kind.
    public var displayName: String {
        switch self {
        case .treadmill:    return "Treadmill"
        case .indoorBike:   return "Indoor Bike"
        case .rower:        return "Rower"
        case .crossTrainer: return "Cross Trainer"
        }
    }
}

/// A single decoded FTMS machine-data notification. Every field is OPTIONAL — a machine only advertises
/// a subset, and a truncated packet decodes only what fit. Units are the spec's resolved units (not the
/// raw fixed-point), so the UI shows honest values and never has to know the per-field scale.
///
/// `kind` records which characteristic produced it (so the UI can label the session).
public struct FTMSReading: Equatable, Sendable {
    public let kind: FTMSMachineKind
    /// Instantaneous speed in km/h. (Treadmill/cross-trainer/indoor-bike report this; rower does not.)
    public var speedKmh: Double?
    /// Instantaneous cadence: steps/min (treadmill/cross-trainer), rpm (indoor bike), strokes/min (rower).
    public var cadence: Double?
    /// Instantaneous power in watts (signed per spec; negative is physically implausible but preserved).
    public var powerWatts: Int?
    /// Total distance covered this session, in metres.
    public var distanceM: Int?
    /// Total energy expended this session, in kilocalories (the FTMS "Total Energy" field).
    public var totalEnergyKcal: Int?
    /// Heart rate in bpm, if the machine reports it (FTMS carries HR as a u8 in the same packet).
    public var heartRate: Int?
    /// Elapsed session time in seconds.
    public var elapsedTimeSec: Int?

    public init(kind: FTMSMachineKind,
                speedKmh: Double? = nil, cadence: Double? = nil, powerWatts: Int? = nil,
                distanceM: Int? = nil, totalEnergyKcal: Int? = nil, heartRate: Int? = nil,
                elapsedTimeSec: Int? = nil) {
        self.kind = kind
        self.speedKmh = speedKmh; self.cadence = cadence; self.powerWatts = powerWatts
        self.distanceM = distanceM; self.totalEnergyKcal = totalEnergyKcal
        self.heartRate = heartRate; self.elapsedTimeSec = elapsedTimeSec
    }
}

/// Pure FTMS decoders. Stateless; one static entry point per machine-data characteristic.
public enum FTMSDecode {

    // MARK: - Little-endian readers (bounds-checked over UNTRUSTED input)

    /// A forward cursor over the byte buffer. Every read advances `idx` only on success; on a short
    /// buffer the read returns nil and leaves the cursor put, so the caller stops decoding cleanly.
    private struct Reader {
        let bytes: [UInt8]
        var idx: Int = 0

        mutating func u8() -> Int? {
            guard idx < bytes.count else { return nil }
            defer { idx += 1 }
            return Int(bytes[idx])
        }
        mutating func u16() -> Int? {
            guard idx + 1 < bytes.count else { return nil }
            defer { idx += 2 }
            return Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
        }
        /// Signed 16-bit (two's complement) — FTMS power is sint16.
        mutating func s16() -> Int? {
            guard let raw = u16() else { return nil }
            return raw >= 0x8000 ? raw - 0x10000 : raw
        }
        mutating func u24() -> Int? {
            guard idx + 2 < bytes.count else { return nil }
            defer { idx += 3 }
            return Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8) | (Int(bytes[idx + 2]) << 16)
        }
        /// Skip `n` bytes (an optional field we don't surface), clamped so it never runs past the end.
        mutating func skip(_ n: Int) { idx = min(bytes.count, idx + n) }
        /// True while at least one more byte remains.
        var hasMore: Bool { idx < bytes.count }
    }

    // MARK: - Treadmill Data (0x2ACD)
    //
    // Flags (u16) then, IN ORDER (each gated by its flag bit):
    //   bit0  More Data            → (when SET, Instantaneous Speed is ABSENT; otherwise present)
    //   —     Instantaneous Speed  u16, 0.01 km/h   (present unless bit0)
    //   bit1  Average Speed        u16, 0.01 km/h
    //   bit2  Total Distance       u24, metres
    //   bit3  Inclination+Ramp     sint16 incline 0.1% + sint16 ramp 0.1°  (2 fields, 4 bytes)
    //   bit4  Elevation Gain       u16 pos 0.1 m + u16 neg 0.1 m           (2 fields, 4 bytes)
    //   bit5  Inst. Pace           u8, 0.1 km/min
    //   bit6  Average Pace         u8, 0.1 km/min
    //   bit7  Total Energy         u16 total kcal + u16 per-hour + u8 per-min
    //   bit8  Heart Rate           u8, bpm
    //   bit9  Metabolic Equivalent u8, 0.1
    //   bit10 Elapsed Time         u16, seconds
    //   bit11 Remaining Time       u16, seconds
    //   bit12 Force on Belt + Power u16 force(N) + u16 power(W, the belt power output)
    public static func treadmill(_ data: [UInt8]) -> FTMSReading? {
        var r = Reader(bytes: data)
        guard let flags = r.u16() else { return nil }
        var out = FTMSReading(kind: .treadmill)

        // Instantaneous Speed is present UNLESS the "More Data" flag (bit0) is set.
        if flags & 0x0001 == 0, let raw = r.u16() { out.speedKmh = Double(raw) * 0.01 }
        if flags & 0x0002 != 0 { _ = r.u16() }                         // Average Speed (skip)
        if flags & 0x0004 != 0, let d = r.u24() { out.distanceM = d }  // Total Distance
        if flags & 0x0008 != 0 { r.skip(4) }                           // Inclination + Ramp Angle
        if flags & 0x0010 != 0 { r.skip(4) }                           // Pos + Neg Elevation Gain
        if flags & 0x0020 != 0 { _ = r.u8() }                          // Instantaneous Pace
        if flags & 0x0040 != 0 { _ = r.u8() }                          // Average Pace
        if flags & 0x0080 != 0 {                                       // Total Energy block
            if let e = r.u16() { out.totalEnergyKcal = e }             // Total Energy (kcal)
            _ = r.u16()                                                // Energy Per Hour
            _ = r.u8()                                                 // Energy Per Minute
        }
        if flags & 0x0100 != 0, let hr = r.u8() { out.heartRate = hr } // Heart Rate
        if flags & 0x0200 != 0 { _ = r.u8() }                          // Metabolic Equivalent
        if flags & 0x0400 != 0, let t = r.u16() { out.elapsedTimeSec = t } // Elapsed Time
        // Remaining Time / Force+Power are after the fields we surface — not decoded.
        return out
    }

    // MARK: - Indoor Bike Data (0x2AD2)
    //
    //   bit0  More Data            → Instantaneous Speed ABSENT when set
    //   —     Instantaneous Speed  u16, 0.01 km/h
    //   bit1  Average Speed        u16, 0.01 km/h
    //   bit2  Inst. Cadence        u16, 0.5 rpm
    //   bit3  Average Cadence      u16, 0.5 rpm
    //   bit4  Total Distance       u24, metres
    //   bit5  Resistance Level     sint16
    //   bit6  Inst. Power          sint16, watts
    //   bit7  Average Power        sint16, watts
    //   bit8  Total Energy         u16 total kcal + u16 per-hour + u8 per-min
    //   bit9  Heart Rate           u8, bpm
    //   bit10 Metabolic Equivalent u8, 0.1
    //   bit11 Elapsed Time         u16, seconds
    //   bit12 Remaining Time       u16, seconds
    public static func indoorBike(_ data: [UInt8]) -> FTMSReading? {
        var r = Reader(bytes: data)
        guard let flags = r.u16() else { return nil }
        var out = FTMSReading(kind: .indoorBike)

        if flags & 0x0001 == 0, let raw = r.u16() { out.speedKmh = Double(raw) * 0.01 }
        if flags & 0x0002 != 0 { _ = r.u16() }                         // Average Speed
        if flags & 0x0004 != 0, let c = r.u16() { out.cadence = Double(c) * 0.5 } // Inst. Cadence (0.5 rpm)
        if flags & 0x0008 != 0 { _ = r.u16() }                         // Average Cadence
        if flags & 0x0010 != 0, let d = r.u24() { out.distanceM = d }  // Total Distance
        if flags & 0x0020 != 0 { _ = r.u16() }                         // Resistance Level
        if flags & 0x0040 != 0, let p = r.s16() { out.powerWatts = p } // Inst. Power
        if flags & 0x0080 != 0 { _ = r.s16() }                         // Average Power
        if flags & 0x0100 != 0 {                                       // Total Energy block
            if let e = r.u16() { out.totalEnergyKcal = e }
            _ = r.u16(); _ = r.u8()
        }
        if flags & 0x0200 != 0, let hr = r.u8() { out.heartRate = hr } // Heart Rate
        if flags & 0x0400 != 0 { _ = r.u8() }                          // Metabolic Equivalent
        if flags & 0x0800 != 0, let t = r.u16() { out.elapsedTimeSec = t } // Elapsed Time
        return out
    }

    // MARK: - Rower Data (0x2AD1)
    //
    //   bit0  More Data            → Stroke Rate + Stroke Count ABSENT when set
    //   —     Stroke Rate          u8, 0.5 stroke/min
    //   —     Stroke Count         u16
    //   bit1  Average Stroke Rate  u8, 0.5 stroke/min
    //   bit2  Total Distance       u24, metres
    //   bit3  Inst. Pace           u16, seconds (per 500 m)
    //   bit4  Average Pace         u16, seconds
    //   bit5  Inst. Power          sint16, watts
    //   bit6  Average Power        sint16, watts
    //   bit7  Resistance Level     sint16
    //   bit8  Total Energy         u16 total kcal + u16 per-hour + u8 per-min
    //   bit9  Heart Rate           u8, bpm
    //   bit10 Metabolic Equivalent u8, 0.1
    //   bit11 Elapsed Time         u16, seconds
    //   bit12 Remaining Time       u16, seconds
    public static func rower(_ data: [UInt8]) -> FTMSReading? {
        var r = Reader(bytes: data)
        guard let flags = r.u16() else { return nil }
        var out = FTMSReading(kind: .rower)

        if flags & 0x0001 == 0 {                                       // Stroke Rate + Stroke Count
            if let sr = r.u8() { out.cadence = Double(sr) * 0.5 }       // 0.5 stroke/min
            _ = r.u16()                                                // Stroke Count
        }
        if flags & 0x0002 != 0 { _ = r.u8() }                          // Average Stroke Rate
        if flags & 0x0004 != 0, let d = r.u24() { out.distanceM = d }  // Total Distance
        if flags & 0x0008 != 0 { _ = r.u16() }                         // Inst. Pace
        if flags & 0x0010 != 0 { _ = r.u16() }                         // Average Pace
        if flags & 0x0020 != 0, let p = r.s16() { out.powerWatts = p } // Inst. Power
        if flags & 0x0040 != 0 { _ = r.s16() }                         // Average Power
        if flags & 0x0080 != 0 { _ = r.s16() }                         // Resistance Level
        if flags & 0x0100 != 0 {                                       // Total Energy block
            if let e = r.u16() { out.totalEnergyKcal = e }
            _ = r.u16(); _ = r.u8()
        }
        if flags & 0x0200 != 0, let hr = r.u8() { out.heartRate = hr } // Heart Rate
        if flags & 0x0400 != 0 { _ = r.u8() }                          // Metabolic Equivalent
        if flags & 0x0800 != 0, let t = r.u16() { out.elapsedTimeSec = t } // Elapsed Time
        return out
    }

    // MARK: - Cross Trainer Data (0x2ACE)
    //
    // The cross-trainer flags are 24-bit per spec (a u16 flags + u8 "more flags"), then:
    //   bit0  More Data            → Instantaneous Speed ABSENT when set
    //   —     Instantaneous Speed  u16, 0.01 km/h
    //   bit1  Average Speed        u16, 0.01 km/h
    //   bit2  Total Distance       u24, metres
    //   bit3  Step Count           u16 steps/min + u16 average step rate (2 fields)
    //   bit4  Stride Count         u16
    //   bit5  Elevation Gain       u16 pos + u16 neg (2 fields)
    //   bit6  Inclination + Ramp   sint16 + sint16 (2 fields)
    //   bit7  Resistance Level     sint16
    //   bit8  Inst. Power          sint16, watts
    //   bit9  Average Power        sint16, watts
    //   bit10 Total Energy         u16 total kcal + u16 per-hour + u8 per-min
    //   bit11 Heart Rate           u8, bpm
    //   bit12 Metabolic Equivalent u8, 0.1
    //   bit13 Elapsed Time         u16, seconds
    //   bit14 Remaining Time       u16, seconds
    //
    // The cadence we surface for a cross-trainer is the per-minute STEP rate (first field of the Step
    // Count block), the closest analogue to "cadence" the machine reports.
    public static func crossTrainer(_ data: [UInt8]) -> FTMSReading? {
        var r = Reader(bytes: data)
        guard let lo = r.u16(), let hi = r.u8() else { return nil }
        let flags = lo | (hi << 16)
        var out = FTMSReading(kind: .crossTrainer)

        if flags & 0x000001 == 0, let raw = r.u16() { out.speedKmh = Double(raw) * 0.01 }
        if flags & 0x000002 != 0 { _ = r.u16() }                       // Average Speed
        if flags & 0x000004 != 0, let d = r.u24() { out.distanceM = d } // Total Distance
        if flags & 0x000008 != 0 {                                     // Step Count block
            if let spm = r.u16() { out.cadence = Double(spm) }         // Step Per Minute
            _ = r.u16()                                                // Average Step Rate
        }
        if flags & 0x000010 != 0 { _ = r.u16() }                       // Stride Count
        if flags & 0x000020 != 0 { r.skip(4) }                         // Pos + Neg Elevation Gain
        if flags & 0x000040 != 0 { r.skip(4) }                         // Inclination + Ramp Angle
        if flags & 0x000080 != 0 { _ = r.s16() }                       // Resistance Level
        if flags & 0x000100 != 0, let p = r.s16() { out.powerWatts = p } // Inst. Power
        if flags & 0x000200 != 0 { _ = r.s16() }                       // Average Power
        if flags & 0x000400 != 0 {                                     // Total Energy block
            if let e = r.u16() { out.totalEnergyKcal = e }
            _ = r.u16(); _ = r.u8()
        }
        if flags & 0x000800 != 0, let hr = r.u8() { out.heartRate = hr } // Heart Rate
        if flags & 0x001000 != 0 { _ = r.u8() }                        // Metabolic Equivalent
        if flags & 0x002000 != 0, let t = r.u16() { out.elapsedTimeSec = t } // Elapsed Time
        return out
    }

    /// Decode whichever machine-data characteristic by its 16-bit UUID short form (case-insensitive).
    /// Returns nil for an unknown UUID or an empty packet, so the caller can ignore it cleanly.
    public static func decode(uuid16: String, _ data: [UInt8]) -> FTMSReading? {
        switch uuid16.uppercased() {
        case "2ACD": return treadmill(data)
        case "2AD2": return indoorBike(data)
        case "2AD1": return rower(data)
        case "2ACE": return crossTrainer(data)
        default:     return nil
        }
    }
}

// MARK: - Battery Service (0x180F / 0x2A19) pure decoder

/// Pure parser for the standard BLE Battery Level characteristic (0x2A19): a single u8 percent, 0–100.
/// Values above 100 are clamped (a misbehaving device must never surface a >100% battery); an empty
/// buffer yields nil. Pure → unit-testable away from CoreBluetooth, mirroring `StandardHeartRate`.
public enum StandardBattery {
    /// The battery percent (0...100), or nil if the packet was empty.
    public static func parse(_ data: [UInt8]) -> Int? {
        guard let first = data.first else { return nil }
        return min(100, Int(first))
    }
}
