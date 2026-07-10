import SwiftUI
import Foundation
import StrandDesign
import WhoopStore
import WhoopProtocol

// MARK: - SleepView
//
// Whoop-sleep clarity on the locked Noop component system. Scannable in two seconds:
//   1. HERO ChartCard "Last night" — the stage breakdown (Hypnogram if intervals
//      reconstruct from stagesJSON, else a clean proportional stacked stage bar),
//      trailing = total asleep, footer = REM/Deep/Light/Awake each "Xh Ym · NN%".
//   2. A uniform grid of fixed StatTiles, each with a sparkline and a "vs typical"
//      caption: Performance, Efficiency, Consistency, Hours vs Needed, Restorative,
//      Respiratory, Sleep Debt.
//   3. "Stages vs typical" NoopCard — Deep/REM/Light as horizontal bars, last-night
//      minutes with a marker at the personal typical (mean) so highs/lows pop.
//   4. A 30-day asleep-hours ChartCard trend.
//
// Every surface is a NoopCard / StatTile / ChartCard — no hand-sized cards, one grid,
// equal margins. Data wiring is preserved from the previous screen (stagesJSON =
// minutes for light/deep/rem/awake; typical = mean of repo.days).

struct SleepView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var live: LiveState

    // The standard tile grid: ONE adaptive column set, used for every tile group.
    private let tileColumns = [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)]

    /// Memoized snapshot of every expensive derivation (latest Night with its intervals
    /// resolved once, the seven metric series, the trend points, the typical means). Rebuilt
    /// only when the underlying repo data actually changes — NOT on hover/animation/1Hz HR
    /// ticks that merely re-evaluate `body`. `nil` until first build or when there's no night.
    @State private var model: SleepModel?
    /// The repo signature the cached `model` was built from. Cheap to compute every render;
    /// when it differs from the current inputs we rebuild the model.
    @State private var modelKey: SleepInputKey?

    /// Real HR samples for the currently-shown night's window. Empty for nights we didn't
    /// capture live (e.g. imported-only history).
    @State private var nightHR: [HRSample] = []
    /// The night (startTs) the loaded `nightHR` belongs to, so we don't reload on every render.
    @State private var loadedNightTs: Int?
    /// The stage the user CLICKED to lock as highlighted on the HR trace; nil = whole night.
    @State private var selectedStage: SleepStage?
    /// The stage the user is HOVERING over (transient); previews the highlight without locking it.
    /// The effective highlight is `hoveredStage ?? selectedStage` — hover wins while the cursor is
    /// over a chip, falling back to the locked selection when it leaves.
    @State private var hoveredStage: SleepStage?

    /// The stage currently driving the HR highlight: a live hover takes precedence over the locked
    /// click-selection, so moving across the chips previews each while a click still persists.
    private var activeStage: SleepStage? { hoveredStage ?? selectedStage }

    var body: some View {
        // Resolve the memoized model for THIS render. `dataKey` is O(1)-ish (counts + last-row
        // identity), so comparing it every render is cheap. When it matches the cached key we
        // reuse the cached model untouched — the many body re-evaluations from hover/animation/
        // 1Hz HR ticks pay nothing. When it differs (or on first render) we build once, here,
        // synchronously, so the very first frame already shows content (no empty-state flash).
        let key = dataKey
        let resolved: SleepModel? = (key == modelKey) ? model : buildModel()
        ScreenScaffold(title: "Sleep") {
            Group {
                if let resolved {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        hero(resolved)
                        metricGrid(resolved)
                        stagesVsTypical(resolved)
                        durationTrend(resolved)
                    }
                } else {
                    emptyState
                }
            }
            // Persist the freshly-built model so subsequent renders with the same inputs hit
            // the cache. Writing State during body is not allowed, so commit it after layout;
            // `resolved` already drives THIS frame, so there is no flash and no extra rebuild.
            .onChange(of: key) { newKey in
                modelKey = newKey
                model = buildModel()
            }
            .onAppear {
                if modelKey != key {
                    modelKey = key
                    model = resolved
                }
            }
            // Load the real HR for this night whenever the shown night changes.
            .task(id: resolved?.night.session.startTs) {
                await loadNightHR(resolved?.night)
            }
        }
    }

    /// Pull the real heart-rate samples spanning the night's window (merged live + imported).
    /// Resets the highlighted stage so a night change starts on the full trace.
    private func loadNightHR(_ night: Night?) async {
        guard let night else { nightHR = []; loadedNightTs = nil; return }
        if loadedNightTs == night.session.startTs { return }
        selectedStage = nil
        let samples = await repo.nightHRSamples(from: night.session.startTs, to: night.session.endTs)
        nightHR = samples
        loadedNightTs = night.session.startTs
    }

    /// True when this night should show the live HR chart — i.e. we actually captured real
    /// heart-rate samples across it. Imported-only nights (no HR) fall back to the stage view.
    private func showsHRChart(_ night: Night) -> Bool {
        !nightHR.isEmpty
    }

    // MARK: - 1. HERO — stage breakdown

    @ViewBuilder
    private func hero(_ model: SleepModel) -> some View {
        let night = model.night
        if showsHRChart(night) {
            hrHero(model)
        } else {
            stageHero(model)
        }
    }

    /// Live-era hero: real heart rate across the FULL WIDTH of the screen, a clock axis along the
    /// bottom, and a row of stage chips beneath. Hover a chip → that stage's HR lights up on the
    /// trace; click to lock it (click again to release). No dropdown — the chips are the control.
    @ViewBuilder
    private func hrHero(_ model: SleepModel) -> some View {
        let night = model.night
        let s = night.stages
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last night", overline: "Sleep · heart rate",
                          trailing: "\(night.dateLabel) · \(night.onsetText)–\(night.wakeText)")
            ChartCard(
                title: activeStage.map { "Heart rate · \($0.label)" } ?? "Heart rate through the night",
                subtitle: "\(durationText(night.timeInBed)) in bed · \(hrTrailing)",
                trailing: nil,
                height: hrChartHeight,
                chart: {
                    NightHRChart(samples: nightHR,
                                 nightStartTs: night.session.startTs,
                                 nightEndTs: night.session.endTs,
                                 intervals: model.intervals,
                                 selectedStage: activeStage,
                                 showsTimeAxis: true,
                                 onsetOffset: sleepOnsetOffset(model.intervals),
                                 wakeOffset: finalWakeOffset(model.intervals),
                                 height: hrChartHeight)
                },
                footer: { stageChips(s) }
            )
        }
    }

    /// Taller than the default so a full-width night reads clearly.
    private var hrChartHeight: CGFloat { NoopMetrics.chartHeight * 1.4 }

    /// Sleep onset (seconds from night start) = start of the FIRST non-awake interval. nil if the
    /// night is all wake / has no intervals.
    private func sleepOnsetOffset(_ intervals: [SleepInterval]) -> Double? {
        intervals.first { $0.stage != .awake }?.start
    }

    /// Final wake (seconds from night start) = end of the LAST non-awake interval.
    private func finalWakeOffset(_ intervals: [SleepInterval]) -> Double? {
        intervals.last { $0.stage != .awake }?.end
    }

    /// The four stage chips beneath the chart — the replacement for the old dropdown. Each is a
    /// hoverable + tappable box a little larger than its label: HOVER previews the stage's HR on the
    /// trace, TAP locks it (tap again or tap another to change). The currently-active chip is filled
    /// in its stage color so it's obvious what's highlighted.
    @ViewBuilder
    private func stageChips(_ s: Stages) -> some View {
        HStack(spacing: 8) {
            stageChip(.rem,   "REM",   s.rem,   s.total)
            stageChip(.deep,  "Deep",  s.deep,  s.total)
            stageChip(.light, "Light", s.light, s.total)
            stageChip(.awake, "Awake", s.awake, s.total)
        }
        .frame(maxWidth: .infinity)
    }

    /// One stage chip. `activeStage == stage` (hover or lock) fills it in the stage color.
    @ViewBuilder
    private func stageChip(_ stage: SleepStage, _ label: String, _ minutes: Double, _ total: Double) -> some View {
        let isActive = activeStage == stage
        let isLocked = selectedStage == stage
        let color = StrandPalette.sleepStageColor(stage)
        VStack(spacing: 3) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(isActive ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
            Text("\(durationText(minutes)) · \(pct(minutes, total))%")
                .font(StrandFont.footnote)
                .foregroundStyle(isActive ? StrandPalette.surfaceBase.opacity(0.85) : StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(isActive ? color : StrandPalette.surfaceInset,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLocked ? color : StrandPalette.hairline, lineWidth: isLocked ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering in
            hoveredStage = hovering ? stage : (hoveredStage == stage ? nil : hoveredStage)
        }
        .onTapGesture {
            selectedStage = (selectedStage == stage) ? nil : stage   // toggle lock
        }
        .animation(.easeOut(duration: 0.15), value: isActive)
        .accessibilityLabel("\(label): \(durationText(minutes)). Tap to highlight this stage's heart rate.")
    }

    /// Legacy / toggle-off hero: the original stage breakdown. Shows a small note for nights
    /// recorded before NOOP began capturing live heart rate.
    @ViewBuilder
    private func stageHero(_ model: SleepModel) -> some View {
        let night = model.night
        let s = night.stages
        let intervals = model.intervals
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last night", overline: "Sleep",
                          trailing: "\(night.dateLabel) · \(night.onsetText)–\(night.wakeText)")
            ChartCard(
                title: "Stage breakdown",
                subtitle: "\(durationText(night.timeInBed)) in bed · \(efficiencyText(night)) efficiency",
                trailing: durationText(s.asleep),
                height: NoopMetrics.chartHeight,
                chart: {
                    if intervals.count >= 2 {
                        Hypnogram(intervals: intervals,
                                  height: NoopMetrics.chartHeight,
                                  showsStageAxis: true,
                                  nightStart: night.onsetDate)
                    } else {
                        stageBar(s)
                    }
                },
                footer: {
                    ChartFooter([
                        ("REM",   "\(durationText(s.rem)) · \(pct(s.rem, s.total))%"),
                        ("Deep",  "\(durationText(s.deep)) · \(pct(s.deep, s.total))%"),
                        ("Light", "\(durationText(s.light)) · \(pct(s.light, s.total))%"),
                        ("Awake", "\(durationText(s.awake)) · \(pct(s.awake, s.total))%"),
                    ])
                }
            )
        }
    }

    /// HR RANGE (low–high bpm) across the night, or within the active (hovered/locked) stage when
    /// one is chosen.
    private var hrTrailing: String {
        let relevant: [Int]
        if let stage = activeStage {
            let night = model?.night
            let start = night?.session.startTs ?? 0
            let ranges = (model?.intervals ?? []).filter { $0.stage == stage }.map { $0.start...$0.end }
            relevant = nightHR.filter { s in
                let o = Double(s.ts - start)
                return ranges.contains { $0.contains(o) }
            }.map { $0.bpm }
        } else {
            relevant = nightHR.map { $0.bpm }
        }
        let valid = relevant.filter { $0 > 0 }
        guard let lo = valid.min(), let hi = valid.max() else { return "—" }
        return "\(lo)–\(hi) bpm"
    }

    /// Full-width proportional stacked stage bar (fallback when no intervals).
    @ViewBuilder
    private func stageBar(_ s: Stages) -> some View {
        let total = max(1, s.total)
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    segment(.deep, s.deep, total, geo.size.width)
                    segment(.light, s.light, total, geo.size.width)
                    segment(.rem, s.rem, total, geo.size.width)
                    segment(.awake, s.awake, total, geo.size.width)
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleep stage breakdown: deep \(pct(s.deep, s.total)) percent, light \(pct(s.light, s.total)) percent, REM \(pct(s.rem, s.total)) percent, awake \(pct(s.awake, s.total)) percent")
            HStack(spacing: 16) {
                legend(.deep, "Deep")
                legend(.light, "Light")
                legend(.rem, "REM")
                legend(.awake, "Awake")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func segment(_ stage: SleepStage, _ minutes: Double, _ total: Double, _ width: CGFloat) -> some View {
        let w = CGFloat(minutes / total) * width
        Rectangle()
            .fill(StrandPalette.sleepStageColor(stage))
            .frame(width: max(0, w))
    }

    @ViewBuilder
    private func legend(_ stage: SleepStage, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(StrandPalette.sleepStageColor(stage))
                .frame(width: 9, height: 9)
            Text(label).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - 2. Metric grid (UNIFORM fixed-height StatTiles, each with sparkline)

    @ViewBuilder
    private func metricGrid(_ model: SleepModel) -> some View {
        // Per-tile latest value + history series (for the sparkline) + typical mean.
        // All seven series are computed ONCE in the model build (each is a full pass over
        // repo.days/repo.sleeps) — here we only read the memoized results.
        let perf  = model.performance
        let eff   = model.efficiency
        let cons  = model.consistency
        let need  = model.hoursVsNeeded
        let rest  = model.restorative
        let resp  = model.respiratory
        let debt  = model.sleepDebt

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Night detail", overline: "Metrics", trailing: "vs typical")
            LazyVGrid(columns: tileColumns, alignment: .leading, spacing: NoopMetrics.gap) {

                StatTile(
                    label: "Sleep Performance",
                    value: pctValue(perf.latest),
                    caption: vsTypical(perf.latest, perf.typical, suffix: "%"),
                    accent: perf.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(perf.series),
                    sparkColor: StrandPalette.accent)

                StatTile(
                    label: "Efficiency",
                    value: pctValue(eff.latest),
                    caption: vsTypical(eff.latest, eff.typical, suffix: "%"),
                    accent: StrandPalette.statusPositive,
                    sparkline: spark(eff.series),
                    sparkColor: StrandPalette.statusPositive)

                StatTile(
                    label: "Consistency",
                    value: pctValue(cons.latest),
                    caption: vsTypical(cons.latest, cons.typical, suffix: "%"),
                    accent: cons.latest.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                    sparkline: spark(cons.series),
                    sparkColor: StrandPalette.metricCyan)

                StatTile(
                    label: "Hours vs Needed",
                    value: pctValue(need.latest),
                    caption: vsTypical(need.latest, need.typical, suffix: "%"),
                    accent: need.latest.map { StrandPalette.recoveryColor(min(100, $0)) } ?? StrandPalette.textPrimary,
                    sparkline: spark(need.series),
                    sparkColor: StrandPalette.accent)

                StatTile(
                    label: "Restorative",
                    value: pctValue(rest.latest),
                    caption: vsTypical(rest.latest, rest.typical, suffix: "%"),
                    accent: StrandPalette.sleepREM,
                    sparkline: spark(rest.series),
                    sparkColor: StrandPalette.sleepREM)

                StatTile(
                    label: "Respiratory",
                    value: rrValue(resp.latest),
                    caption: vsTypical(resp.latest, resp.typical, suffix: " rpm", decimals: 1),
                    accent: StrandPalette.metricPurple,
                    sparkline: spark(resp.series),
                    sparkColor: StrandPalette.metricPurple)

                StatTile(
                    label: "Sleep Debt",
                    value: debt.latest.map { durationText($0) } ?? "—",
                    caption: debtCaption(debt.latest),
                    accent: debtColor(debt.latest),
                    sparkline: spark(debt.series),
                    sparkColor: StrandPalette.metricRose)
            }
        }
    }

    // MARK: - 3. Stages vs typical

    @ViewBuilder
    private func stagesVsTypical(_ model: SleepModel) -> some View {
        let s = model.night.stages
        // Per-stage typical means are computed ONCE in the model build (each a full pass
        // over repo.days) and read here.
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages vs typical", overline: "Last night",
                          trailing: "marker = your mean")
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    stageRow("Deep",  last: s.deep,  typical: model.typicalDeepMin,  color: StrandPalette.sleepDeep)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow("REM",   last: s.rem,   typical: model.typicalRemMin,   color: StrandPalette.sleepREM)
                    Divider().overlay(StrandPalette.hairline)
                    stageRow("Light", last: s.light, typical: model.typicalLightMin, color: StrandPalette.sleepLight)
                }
            }
        }
    }

    /// One stage bar: last-night minutes filled, with a vertical marker at the typical mean.
    @ViewBuilder
    private func stageRow(_ label: String, last: Double, typical: Double?, color: Color) -> some View {
        // Scale both values against a shared per-row max so the marker is meaningful.
        let scaleMax = max(last, typical ?? 0) * 1.18
        let max = scaleMax > 0 ? scaleMax : 1
        let deltaText: String = {
            guard let typical, typical > 0 else { return "" }
            let diff = last - typical
            let sign = diff >= 0 ? "+" : "−"
            return "\(sign)\(durationText(abs(diff))) vs typ"
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label.uppercased()).strandOverline()
                Spacer()
                Text(durationText(last)).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                if !deltaText.isEmpty {
                    Text(deltaText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(last >= (typical ?? last) ? StrandPalette.statusPositive : StrandPalette.statusWarning)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    // track
                    Capsule(style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                    // last-night fill
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: w * CGFloat(min(1, last / max)))
                    // typical marker
                    if let typical, typical > 0 {
                        Rectangle()
                            .fill(StrandPalette.textPrimary)
                            .frame(width: 2, height: 16)
                            .position(x: w * CGFloat(min(1, typical / max)), y: 5)
                    }
                }
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(durationText(last)) last night\(typical.map { ", typical \(durationText($0))" } ?? "")")
        }
    }

    // MARK: - 4. 30-day asleep-hours trend

    @ViewBuilder
    private func durationTrend(_ model: SleepModel) -> some View {
        // Trailing-30 trend points and the typical total are precomputed in the model build
        // (full passes over repo.days) — read here, not recomputed per render.
        let pts = model.trendPoints
        let avg = model.typicalTotalMin.map { $0 / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Asleep duration", overline: "Trend", trailing: "Last 30 days")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: avg.map { String(format: "%.1f h avg", $0) },
                height: NoopMetrics.chartHeight,
                chart: {
                    if pts.count >= 2 {
                        TrendChart(points: pts,
                                   gradient: StrandPalette.recoveryGradient,
                                   valueRange: trendRange(pts),
                                   showsArea: true,
                                   height: NoopMetrics.chartHeight,
                                   valueFormat: { String(format: "%.1f h", $0) })
                    } else {
                        sparsePlaceholder
                    }
                },
                footer: {
                    ChartFooter([
                        ("Avg",    avg.map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Min",    pts.map(\.value).min().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Max",    pts.map(\.value).max().map { String(format: "%.1f h", $0) } ?? "—"),
                        ("Nights", "\(pts.count)"),
                    ])
                }
            )
        }
    }

    // MARK: - Memoization plumbing

    /// A cheap fingerprint of the repo inputs this screen derives from. Recomputed every
    /// render but only contains counts + the identity of the newest/oldest rows, so equality
    /// is fast. When it changes we know `repo.days`/`repo.sleeps` actually changed and the
    /// memoized `model` must be rebuilt; otherwise hover/animation/1Hz HR re-renders are free.
    private var dataKey: SleepInputKey {
        SleepInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            sleepsCount: repo.sleeps.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last?.day,
            lastDayUpdated: repo.days.last,
            lastSleep: repo.sleeps.last)
    }

    /// Build every expensive derivation exactly once. Called only when `dataKey` changes,
    /// so each full pass over repo.days / repo.sleeps runs once per data change rather than
    /// once per render. Returns nil when there is no usable latest night (renders empty state).
    private func buildModel() -> SleepModel? {
        guard let night = latestNight else { return nil }
        return SleepModel(
            night: night,
            intervals: night.intervals,
            performance: performanceSeries,
            efficiency: efficiencySeries,
            consistency: consistencySeries,
            hoursVsNeeded: hoursVsNeededSeries,
            restorative: restorativeSeries,
            respiratory: respiratorySeries,
            sleepDebt: sleepDebtSeries,
            typicalTotalMin: typicalTotalMin,
            typicalDeepMin: typicalStageMin(\.deepMin),
            typicalRemMin: typicalStageMin(\.remMin),
            typicalLightMin: typicalStageMin(\.lightMin),
            trendPoints: durationTrendPoints)
    }

    // MARK: - Derived model

    /// The most recent sleep, decoded into stage durations + (when available) the REAL stage
    /// timeline. Both computed and imported sessions store a `[{start,end,stage}]` segment array
    /// with absolute unix timestamps, so we can show the true hypnogram instead of a synthetic
    /// deep-early/rem-later reconstruction.
    private var latestNight: Night? {
        guard let s = repo.sleeps.last,
              let stages = decodeStages(s.stagesJSON),
              stages.total > 0 else { return nil }
        return Night(session: s, stages: stages,
                     realIntervals: decodeRealIntervals(s.stagesJSON, nightStartTs: s.startTs))
    }

    /// Parse the real stage timeline from a `[{start,end,stage}]` segment array into
    /// `SleepInterval`s (start/end = SECONDS FROM `nightStartTs`, which is what Hypnogram expects).
    /// Returns nil for the legacy dict-of-minutes shape (no timeline to show).
    private func decodeRealIntervals(_ json: String?, nightStartTs: Int) -> [SleepInterval]? {
        guard let json, let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        func num(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            return nil
        }
        func stage(_ s: String) -> SleepStage {
            switch s.lowercased() {
            case "wake", "awake":     return .awake
            case "rem":               return .rem
            case "deep", "sws", "n3": return .deep
            default:                  return .light
            }
        }
        let base = TimeInterval(nightStartTs)
        let out: [SleepInterval] = arr.compactMap { seg in
            guard let start = num(seg["start"]), let end = num(seg["end"]), end > start else { return nil }
            return SleepInterval(stage: stage(seg["stage"] as? String ?? ""),
                                 start: start - base, end: end - base)
        }
        return out.count >= 2 ? out.sorted { $0.start < $1.start } : nil
    }

    /// Mean total sleep duration (minutes) across nights with data — the "typical".
    private var typicalTotalMin: Double? {
        mean(repo.days.compactMap { $0.totalSleepMin }.filter { $0 > 0 })
    }

    /// Mean of a per-stage minutes column across days with data.
    private func typicalStageMin(_ key: KeyPath<DailyMetric, Double?>) -> Double? {
        mean(repo.days.compactMap { $0[keyPath: key] }.filter { $0 > 0 })
    }

    // MARK: - Per-tile series (latest, typical mean, sparkline history)

    private typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    /// Build a metric from a per-day transform, keeping only finite positive-ish values.
    private func metric(_ transform: (DailyMetric) -> Double?) -> Metric {
        let series = repo.days.compactMap(transform).filter { $0.isFinite }
        return (series.last, mean(series), series)
    }

    /// Sleep performance % = asleep / sleep-need, where need = 7.75h baseline + debt-style
    /// nudge. We don't have a stored need, so approximate against the personal asleep mean
    /// (capped 0–100): how much of a *typical* night you achieved.
    private var performanceSeries: Metric {
        let need = sleepNeedMin
        return metric { d in
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return min(100, asleep / need * 100)
        }
    }

    private var efficiencySeries: Metric {
        metric { d in
            guard let e = d.efficiency else { return nil }
            return e <= 1.0 ? e * 100 : e
        }
    }

    /// Consistency per day from the rolling bedtime spread of the trailing window up to
    /// each night; lower spread → higher score. Reuses the same SD→score mapping.
    private var consistencySeries: Metric {
        let cal = Calendar.current
        func bedMinutes(_ s: CachedSleepSession) -> Double {
            let d = Date(timeIntervalSince1970: TimeInterval(s.startTs))
            let comps = cal.dateComponents([.hour, .minute], from: d)
            var m = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
            if m < 12 * 60 { m += 24 * 60 }   // wrap evening onsets into one continuous scale
            return m
        }
        let mins = repo.sleeps.map(bedMinutes)
        guard mins.count >= 3 else { return (nil, nil, []) }
        var scores: [Double] = []
        for i in mins.indices {
            let lo = Swift.max(0, i - 13)
            let window = Array(mins[lo...i])
            guard window.count >= 3 else { continue }
            let m = window.reduce(0, +) / Double(window.count)
            let variance = window.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(window.count)
            let sd = variance.squareRoot()
            scores.append(Swift.max(0, Swift.min(100, 100 * (1 - sd / 120))))
        }
        return (scores.last, mean(scores), scores)
    }

    /// Hours vs needed % = asleep / need (can exceed 100 on a long night).
    private var hoursVsNeededSeries: Metric {
        let need = sleepNeedMin
        return metric { d in
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return asleep / need * 100
        }
    }

    /// Restorative % = (deep + REM) / asleep — the share of the night that does the work.
    private var restorativeSeries: Metric {
        metric { d in
            guard let deep = d.deepMin, let rem = d.remMin,
                  let asleep = d.totalSleepMin, asleep > 0 else { return nil }
            return (deep + rem) / asleep * 100
        }
    }

    private var respiratorySeries: Metric {
        metric { $0.respRateBpm }
    }

    /// Sleep debt (minutes) per night = need − asleep, floored at 0 (no "credit").
    private var sleepDebtSeries: Metric {
        let need = sleepNeedMin
        let series = repo.days.compactMap { d -> Double? in
            guard let asleep = d.totalSleepMin, asleep > 0, need > 0 else { return nil }
            return Swift.max(0, need - asleep)
        }
        return (series.last, mean(series), series)
    }

    /// The personal sleep need (minutes): mean asleep, but never below a 7.5h floor so
    /// debt/performance read sensibly even for a chronically short sleeper.
    private var sleepNeedMin: Double {
        Swift.max(450, typicalTotalMin ?? 450)   // 450 min = 7.5h
    }

    // MARK: - Trend points

    /// Trailing 30 days of total sleep, plotted in HOURS. Falls back to all nights with
    /// data if the trailing window is too sparse.
    private var durationTrendPoints: [TrendPoint] {
        let fmt = SleepView.dayParser
        func build(_ slice: ArraySlice<DailyMetric>) -> [TrendPoint] {
            slice.compactMap { d -> TrendPoint? in
                guard let mins = d.totalSleepMin, mins > 0,
                      let date = fmt.date(from: d.day) else { return nil }
                return TrendPoint(date: date, value: mins / 60.0)
            }
        }
        let recent = build(repo.days.suffix(30))
        if recent.count >= 2 { return recent }
        return build(repo.days[...])
    }

    private func trendRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        let lo = Swift.max(0, (vals.min() ?? 0) - 1)
        let hi = (vals.max() ?? 9) + 1
        return lo...Swift.max(hi, lo + 1)
    }

    // MARK: - Empty / sparse states

    @ViewBuilder
    private var emptyState: some View {
        if repo.loaded {
            ComingSoon(what: "No nights here yet. Import your WHOOP export in Data Sources to see every night, your sleep stages and trends straight away. Or open Intelligence to see last night computed from the strap after you wear it to bed.")
        } else {
            ComingSoon(what: "Loading your sleep history…")
        }
    }

    private var sparsePlaceholder: some View {
        Text("Not enough nights yet.")
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting helpers

    private func pct(_ minutes: Double, _ total: Double) -> Int {
        total > 0 ? Int((minutes / total * 100).rounded()) : 0
    }

    private func pctValue(_ v: Double?) -> String {
        v.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    private func rrValue(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? "—"
    }

    /// "+12% vs typical" / "−0.4 rpm vs typical" — the latest-vs-mean caption every tile carries.
    private func vsTypical(_ latest: Double?, _ typical: Double?, suffix: String, decimals: Int = 0) -> String {
        guard let latest, let typical, typical != 0 else { return "vs typical —" }
        let diff = latest - typical
        let sign = diff >= 0 ? "+" : "−"
        let mag = abs(diff)
        let num = decimals == 0 ? "\(Int(mag.rounded()))" : String(format: "%.\(decimals)f", mag)
        return "\(sign)\(num)\(suffix) vs typical"
    }

    private func debtCaption(_ debt: Double?) -> String {
        guard let debt else { return "vs need" }
        return debt < 15 ? "On target" : "Below need"
    }

    private func debtColor(_ debt: Double?) -> Color {
        guard let debt else { return StrandPalette.textPrimary }
        switch debt {
        case ..<15:  return StrandPalette.statusPositive
        case ..<60:  return StrandPalette.statusWarning
        default:     return StrandPalette.statusCritical
        }
    }

    private func efficiencyText(_ night: Night) -> String {
        let e = efficiencyPct(night)
        return e.map { "\(Int($0.rounded()))%" } ?? "—"
    }

    /// Efficiency in percent. Prefer the stored session value, else asleep / time-in-bed.
    private func efficiencyPct(_ night: Night) -> Double? {
        if let stored = night.session.efficiency ?? repo.today?.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    private func durationText(_ minutes: Double) -> String {
        let m = Swift.max(0, Int(minutes.rounded()))
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// A sparkline needs at least two points; otherwise return nil so the tile stays clean.
    private func spark(_ series: [Double]) -> [Double]? {
        let tail = Array(series.suffix(30))
        return tail.count > 1 ? tail : nil
    }

    private func mean(_ vals: [Double]) -> Double? {
        guard !vals.isEmpty else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Stage decoding

    /// Decode `stagesJSON` into per-stage MINUTES. Handles BOTH shapes:
    ///   1. An ARRAY of segments `[{start,end,stage}]` (unix seconds) — the shape written by BOTH
    ///      the on-device stager (AnalyticsEngine/SleepStager) AND the WHOOP importer. Per-stage
    ///      minutes = Σ (end−start)/60 over segments of that stage. THIS is why the graph was blank:
    ///      the old code only understood shape #2, so every real night decoded to nil → empty state.
    ///   2. A legacy DICT of minutes `{"light","deep","rem","awake"}` — kept as a fallback.
    /// Stage names are matched loosely ("wake"/"awake", "rem", "deep"/"sws", "light"/other).
    private func decodeStages(_ json: String?) -> Stages? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // Shape #1: array of {start,end,stage} segments.
        if let arr = obj as? [[String: Any]] {
            func num(_ v: Any?) -> Double? {
                if let n = v as? NSNumber { return n.doubleValue }
                if let d = v as? Double { return d }
                if let i = v as? Int { return Double(i) }
                return nil
            }
            var awake = 0.0, light = 0.0, deep = 0.0, rem = 0.0
            for seg in arr {
                guard let start = num(seg["start"]), let end = num(seg["end"]), end > start else { continue }
                let mins = (end - start) / 60.0
                switch (seg["stage"] as? String ?? "").lowercased() {
                case "wake", "awake":        awake += mins
                case "rem":                  rem += mins
                case "deep", "sws", "n3":    deep += mins
                default:                     light += mins   // "light", "core", "n1", "n2", unknown
                }
            }
            let s = Stages(awake: awake, light: light, deep: deep, rem: rem)
            return s.total > 0 ? s : nil
        }

        // Shape #2 (legacy): dict of minutes.
        if let dict = obj as? [String: Any] {
            func val(_ key: String) -> Double {
                if let n = dict[key] as? NSNumber { return n.doubleValue }
                if let d = dict[key] as? Double { return d }
                if let i = dict[key] as? Int { return Double(i) }
                return 0
            }
            let s = Stages(awake: val("awake"), light: val("light"),
                           deep: val("deep"), rem: val("rem"))
            return s.total > 0 ? s : nil
        }
        return nil
    }

    /// yyyy-MM-dd → Date (en_US_POSIX, UTC), per task spec.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Local value types

/// Cheap, Equatable fingerprint of the repo inputs SleepView derives from. Two snapshots are
/// equal iff the data the screen reads is unchanged, so the heavy `SleepModel` rebuild is
/// skipped on the many `body` re-evaluations that don't touch sleep data.
private struct SleepInputKey: Equatable {
    let loaded: Bool
    let daysCount: Int
    let sleepsCount: Int
    let firstDay: String?
    let lastDay: String?
    /// Newest day row (Equatable) — catches in-place edits to the latest day's values.
    let lastDayUpdated: DailyMetric?
    /// Newest sleep session (Equatable) — catches a re-import of the latest night.
    let lastSleep: CachedSleepSession?
}

/// Memoized result of every expensive SleepView derivation. Built once per data change in
/// `buildModel()` and read by the subviews, so full passes over repo.days / repo.sleeps and
/// the Night.intervals reconstruction no longer run on every render.
private struct SleepModel {
    /// (latest, typical mean, full history) per metric — mirrors SleepView.Metric.
    typealias Metric = (latest: Double?, typical: Double?, series: [Double])

    let night: Night
    /// Reconstructed stage intervals for the hypnogram — computed once (Night.intervals is a
    /// computed property; it was previously re-derived on each access during render).
    let intervals: [SleepInterval]

    let performance: Metric
    let efficiency: Metric
    let consistency: Metric
    let hoursVsNeeded: Metric
    let restorative: Metric
    let respiratory: Metric
    let sleepDebt: Metric

    let typicalTotalMin: Double?
    let typicalDeepMin: Double?
    let typicalRemMin: Double?
    let typicalLightMin: Double?

    let trendPoints: [TrendPoint]
}

private struct Stages {
    var awake: Double
    var light: Double
    var deep: Double
    var rem: Double
    /// All stages (includes awake) — total time-in-bed minutes.
    var total: Double { awake + light + deep + rem }
    /// Asleep time = total minus awake.
    var asleep: Double { light + deep + rem }
}

private struct Night {
    let session: CachedSleepSession
    let stages: Stages
    /// The REAL stage timeline parsed from the segment array, when the session has one. Preferred
    /// over the synthetic reconstruction so the hypnogram shows actual stage transitions.
    var realIntervals: [SleepInterval]? = nil

    /// Total time in bed in minutes (from reconstructed stages).
    var timeInBed: Double { stages.total }

    /// The wall-clock start of the night (for the Hypnogram's clock labels).
    var onsetDate: Date { Date(timeIntervalSince1970: TimeInterval(session.startTs)) }

    /// Stage intervals across the night, in seconds from start. Uses the REAL timeline when present
    /// (computed + modern imports carry it); otherwise falls back to a plausible reconstruction from
    /// durations only (legacy dict-of-minutes exports have no per-epoch timeline).
    var intervals: [SleepInterval] {
        if let realIntervals { return realIntervals }
        var t: TimeInterval = 0
        var out: [SleepInterval] = []
        func add(_ stage: SleepStage, _ minutes: Double) {
            guard minutes > 0 else { return }
            let secs = minutes * 60
            out.append(SleepInterval(stage: stage, start: t, end: t + secs))
            t += secs
        }
        // A plausible architecture: deep early, REM later, awake last.
        add(.light, stages.light * 0.4)
        add(.deep, stages.deep)
        add(.light, stages.light * 0.3)
        add(.rem, stages.rem)
        add(.light, stages.light * 0.3)
        add(.awake, stages.awake)
        return out
    }

    var onsetText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))) }
    var wakeText: String { Night.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.endTs))) }
    var dateLabel: String { Night.dateFmt.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs))) }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
}

// MARK: - Preview

#if DEBUG
#Preview("Sleep") {
    SleepView()
        .environmentObject(Repository.previewSleep())
        .environmentObject(LiveState())
        .frame(width: 980, height: 1180)
        .preferredColorScheme(.light)
}

@MainActor
private extension Repository {
    /// Sample repository populated with imported-style nights for previews.
    static func previewSleep() -> Repository {
        let repo = Repository(deviceId: "preview")
        let cal = Calendar.current
        let now = Date()

        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f
        }()

        for i in (0..<30).reversed() {
            let date = cal.date(byAdding: .day, value: -i, to: now)!
            let jitter = Double((i * 23) % 11) - 5
            let light = 210.0 + jitter
            let deep = 80.0 + jitter * 0.5
            let rem = 95.0 + jitter * 0.7
            let awake = 25.0 + Double((i * 7) % 9)
            let asleep = light + deep + rem
            let stagesJSON = "{\"light\":\(light),\"deep\":\(deep),\"rem\":\(rem),\"awake\":\(awake)}"

            days.append(DailyMetric(
                day: fmt.string(from: date),
                totalSleepMin: asleep,
                efficiency: 88 + jitter * 0.3,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Int(awake / 6), restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5), recovery: 60 + jitter,
                strain: 10 + Double(i % 6), exerciseCount: i % 2,
                spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6 + jitter * 0.1))

            var onset = cal.date(bySettingHour: 22, minute: 50 + Int(jitter), second: 0, of: date) ?? date
            onset = cal.date(byAdding: .day, value: -1, to: onset) ?? onset
            let end = onset.addingTimeInterval((asleep + awake) * 60)
            sleeps.append(CachedSleepSession(
                startTs: Int(onset.timeIntervalSince1970),
                endTs: Int(end.timeIntervalSince1970),
                efficiency: 88 + jitter * 0.3,
                restingHr: 50 + (i % 4),
                avgHrv: 65 - Double(i % 5),
                stagesJSON: stagesJSON))
        }

        repo.days = days
        repo.sleeps = sleeps
        repo.loaded = true
        return repo
    }
}
#endif
