import Foundation

// MARK: - Nutrition CSV import (source "nutrition-csv")
//
// Daily nutrition totals — calories in, protein, carbs, fat (+ optional body weight) — parsed
// from a nutrition tracker's CSV export and projected into the long-format metric-series store
// under the dedicated source id `nutrition-csv`. Header shapes recognised:
//   • Cronometer daily summary:  "Day"|"Date", "Energy (kcal)", "Protein (g)", "Carbs (g)", "Fat (g)"
//   • MacroFactor:               Date, Calories, Protein, Carbs, Fat
//   • Generic fallback (case-insensitive): date|day, energy|calories|kcal, protein, carb*, fat, weight
// Dates must be `yyyy-MM-dd` (a trailing time component is tolerated). Malformed rows are skipped
// and counted, never fatal — mirroring the tolerant ethos of the WHOOP/Apple importers.

/// One parsed day of nutrition totals. `day` is canonical `yyyy-MM-dd`.
public struct NutritionDayRow: Sendable, Equatable {
    public var day: String
    public var caloriesIn: Double?
    public var proteinG: Double?
    public var carbsG: Double?
    public var fatG: Double?
    /// Optional body weight, stored as-is (the export's own unit).
    public var weight: Double?

    public init(
        day: String,
        caloriesIn: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        weight: Double? = nil
    ) {
        self.day = day
        self.caloriesIn = caloriesIn
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.weight = weight
    }

    /// True when at least one nutrition value is present.
    public var hasAnyValue: Bool {
        caloriesIn != nil || proteinG != nil || carbsG != nil || fatG != nil || weight != nil
    }
}

/// A long-format (day, key, value) projection of a nutrition row, shaped for the
/// metric-series store. Kept as a plain value type here so StrandImport stays
/// store-agnostic; the app layer maps these 1:1 onto `MetricPoint`.
public struct NutritionMetricPoint: Sendable, Equatable {
    public let day: String
    public let key: String
    public let value: Double
    public init(day: String, key: String, value: Double) {
        self.day = day; self.key = key; self.value = value
    }
}

/// Result of parsing a nutrition CSV: one row per day (later duplicate-day rows
/// overwrite earlier non-nil fields, matching the store's latest-wins upsert),
/// plus imported/skipped counts and the day span.
public struct NutritionImportResult: Sendable, Equatable {
    /// Parsed days, oldest first.
    public var rows: [NutritionDayRow]
    /// Data rows dropped: unparseable/missing date, or no usable numeric value.
    public var skippedRows: Int
    public var earliestDay: String?
    public var latestDay: String?

    public init(rows: [NutritionDayRow], skippedRows: Int, earliestDay: String?, latestDay: String?) {
        self.rows = rows
        self.skippedRows = skippedRows
        self.earliestDay = earliestDay
        self.latestDay = latestDay
    }

    /// Number of distinct days imported.
    public var importedDays: Int { rows.count }

    /// Long-format projection for `upsertMetricSeries`.
    public var metricPoints: [NutritionMetricPoint] {
        var pts: [NutritionMetricPoint] = []
        pts.reserveCapacity(rows.count * 5)
        for r in rows {
            if let v = r.caloriesIn { pts.append(.init(day: r.day, key: NutritionCsvImporter.Keys.caloriesIn, value: v)) }
            if let v = r.proteinG { pts.append(.init(day: r.day, key: NutritionCsvImporter.Keys.proteinG, value: v)) }
            if let v = r.carbsG { pts.append(.init(day: r.day, key: NutritionCsvImporter.Keys.carbsG, value: v)) }
            if let v = r.fatG { pts.append(.init(day: r.day, key: NutritionCsvImporter.Keys.fatG, value: v)) }
            if let v = r.weight { pts.append(.init(day: r.day, key: NutritionCsvImporter.Keys.weight, value: v)) }
        }
        return pts
    }
}

public enum NutritionCsvImporter {

    /// Provenance/source id the app uses as the metric-series `deviceId`.
    public static let sourceId = "nutrition-csv"

    /// Metric-series keys this importer emits.
    public enum Keys {
        public static let caloriesIn = "calories_in"
        public static let proteinG = "protein_g"
        public static let carbsG = "carbs_g"
        public static let fatG = "fat_g"
        public static let weight = "weight"
    }

    /// Parse raw CSV bytes (UTF-8, BOM-tolerant, latin-1 fallback — same as `CSVTable`).
    public static func parse(data: Data) -> NutritionImportResult {
        parseTable(CSVTable(data: data))
    }

    /// Parse CSV text.
    public static func parse(text: String) -> NutritionImportResult {
        parseTable(CSVTable(text: text))
    }

    // MARK: - Core

    private static func parseTable(_ table: CSVTable) -> NutritionImportResult {
        let headers = table.normalizedHeaders

        // Resolve which normalized column feeds each field. Exact matches first (the named
        // Cronometer/MacroFactor shapes), then a case-insensitive substring fallback so unknown
        // trackers still import. `HeaderNorm.normalize` already lowercases, so "DAY"/"Calories"
        // and friends are covered for free.
        let dateCol = resolve(headers, exact: ["day", "date"], contains: ["date"])
        let energyCol = resolve(headers,
                                exact: ["energy_kcal", "calories", "energy", "kcal", "calories_kcal"],
                                contains: ["energy", "calorie", "kcal"],
                                excluding: ["burn"])           // never confuse intake with burned energy
        let proteinCol = resolve(headers, exact: ["protein_g", "protein"], contains: ["protein"])
        let carbsCol = resolve(headers,
                               exact: ["carbs_g", "carbs", "carbohydrates_g", "carbohydrates"],
                               contains: ["carb"])
        let fatCol = resolve(headers,
                             exact: ["fat_g", "fat"],
                             contains: ["fat"],
                             excluding: ["saturated", "trans", "mono", "poly"])
        let weightCol = resolve(headers, exact: ["weight_kg", "weight"], contains: ["weight"])

        var byDay: [String: NutritionDayRow] = [:]
        var skipped = 0

        for row in table.rows {
            guard let dateCol,
                  let rawDay = row.cell(dateCol),
                  let day = canonicalDay(rawDay)
            else { skipped += 1; continue }

            var parsed = NutritionDayRow(day: day)
            if let c = energyCol { parsed.caloriesIn = row.double(c) }
            if let c = proteinCol { parsed.proteinG = row.double(c) }
            if let c = carbsCol { parsed.carbsG = row.double(c) }
            if let c = fatCol { parsed.fatG = row.double(c) }
            if let c = weightCol { parsed.weight = row.double(c) }

            guard parsed.hasAnyValue else { skipped += 1; continue }

            // Duplicate day: later non-nil fields overwrite earlier ones (latest value wins,
            // mirroring the metric-series store's ON CONFLICT rule).
            if var existing = byDay[day] {
                if let v = parsed.caloriesIn { existing.caloriesIn = v }
                if let v = parsed.proteinG { existing.proteinG = v }
                if let v = parsed.carbsG { existing.carbsG = v }
                if let v = parsed.fatG { existing.fatG = v }
                if let v = parsed.weight { existing.weight = v }
                byDay[day] = existing
            } else {
                byDay[day] = parsed
            }
        }

        // yyyy-MM-dd sorts correctly lexicographically.
        let days = byDay.keys.sorted()
        return NutritionImportResult(
            rows: days.compactMap { byDay[$0] },
            skippedRows: skipped,
            earliestDay: days.first,
            latestDay: days.last
        )
    }

    // MARK: - Column resolution

    /// First exact normalized-header match wins; otherwise the first header containing any of
    /// `contains` (skipping any containing an `excluding` term); nil if nothing matches.
    private static func resolve(
        _ headers: [String],
        exact: [String],
        contains: [String],
        excluding: [String] = []
    ) -> String? {
        for e in exact where headers.contains(e) { return e }
        for h in headers {
            if excluding.contains(where: { h.contains($0) }) { continue }
            if contains.contains(where: { h.contains($0) }) { return h }
        }
        return nil
    }

    // MARK: - Date handling

    /// Validate/canonicalise a cell to `yyyy-MM-dd`. A trailing time component
    /// (`2024-01-15 07:00` or `2024-01-15T07:00:00`) is tolerated by taking the date part;
    /// anything else (e.g. `15/01/2024`, `Jan 15 2024`) is rejected so the row is skipped.
    static func canonicalDay(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return nil }
        let candidate = String(t.prefix(10))
        // Anything after the date must be a time separator, not more date (rejects "2024-01-150").
        if t.count > 10 {
            let sep = t[t.index(t.startIndex, offsetBy: 10)]
            guard sep == " " || sep == "T" else { return nil }
        }
        // Strict shape check: dddd-dd-dd.
        let chars = Array(candidate)
        for (i, ch) in chars.enumerated() {
            if i == 4 || i == 7 {
                guard ch == "-" else { return nil }
            } else {
                guard ch.isASCII, ch.isNumber else { return nil }
            }
        }
        // Real-calendar check (rejects 2024-13-40).
        guard dayFormatter.date(from: candidate) != nil else { return nil }
        return candidate
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
}
