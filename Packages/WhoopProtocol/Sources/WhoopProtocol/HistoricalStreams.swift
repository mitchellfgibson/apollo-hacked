import Foundation

/// Turn historical (offload) parsed frames into datastore rows. Port of
/// interpreter.extract_historical_streams.
///
/// HR/R-R come from REALTIME_RAW_DATA (type 43) headers — the canonical stream
/// during a historical backfill, where type-40 frames are absent.
/// EVENT and COMMAND_RESPONSE handling is identical to extractStreams.
/// CRC-failed and non-ok frames are skipped.
public func extractHistoricalStreams(_ parsed: [ParsedFrame],
                                     deviceClockRef: Int, wallClockRef: Int) -> Streams {
    func wall(_ deviceTs: Int?) -> Int? {
        guard let d = deviceTs else { return nil }
        return wallClockRef + (d - deviceClockRef)
    }
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "HISTORICAL_DATA":
            // type-47 carries a REAL unix timestamp + the full DSP record. No wall-clock offset.
            guard let ts = p["unix"]?.intValue else { continue }
            if let bpm = p["heart_rate"]?.intValue, bpm != 0 {  // skip startup hr=0
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
            if let red = p["spo2_red"]?.intValue {
                out.spo2.append(SpO2Sample(ts: ts, red: red, ir: p["spo2_ir"]?.intValue ?? 0))
            }
            if let raw = p["skin_temp_raw"]?.intValue {
                out.skinTemp.append(SkinTempSample(ts: ts, raw: raw))
            }
            if let raw = p["resp_rate_raw"]?.intValue {
                out.resp.append(RespSample(ts: ts, raw: raw))
            }
            if let gx = p["gravity_x"]?.doubleValue {
                out.gravity.append(GravitySample(ts: ts, x: gx,
                    y: p["gravity_y"]?.doubleValue ?? 0, z: p["gravity_z"]?.doubleValue ?? 0))
            }
            // v26 records (WHOOP 5): 24 Hz optical PPG waveform. The decoder surfaces it as
            // `ppg_waveform`; v18 frames lack the key, so this is a no-op for them.
            if let wf = p["ppg_waveform"]?.intArrayValue, !wf.isEmpty {
                out.ppg.append(PPGWaveformSample(ts: ts, samples: wf))
            }
            // v21 records (WHOOP 5/MG): 100 Hz 6-axis IMU. Summarised to per-second motion features
            // rather than banked as a waveform — see `ImuFeatures`. v18/v20/v26 lack these keys, so
            // this is a no-op for them.
            if let ax = p["imu_ax"]?.intArrayValue,
               let ay = p["imu_ay"]?.intArrayValue,
               let az = p["imu_az"]?.intArrayValue,
               let gx = p["imu_gx"]?.intArrayValue,
               let gy = p["imu_gy"]?.intArrayValue,
               let gz = p["imu_gz"]?.intArrayValue,
               let f = ImuFeatures.summarise(ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz) {
                out.imu.append(ImuFeatureSample(ts: ts,
                                                accelMagMean: f.accelMagMean,
                                                accelMagSd: f.accelMagSd,
                                                jerkMean: f.jerkMean,
                                                gyroMagMean: f.gyroMagMean,
                                                activityCount: f.activityCount))
            }
        case "REALTIME_RAW_DATA":
            let ts = wall(p["timestamp"]?.intValue)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
            guard let ts = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            continue
        }
    }
    return out
}
