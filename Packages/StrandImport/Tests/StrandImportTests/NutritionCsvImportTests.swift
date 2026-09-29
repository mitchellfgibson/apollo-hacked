import XCTest
@testable import StrandImport

final class NutritionCsvImportTests: XCTestCase {

    // MARK: - Cronometer daily-summary header shape

    func testCronometerHeaders() {
        let csv = """
        Day,Energy (kcal),Protein (g),Net Carbs (g),Carbs (g),Fat (g)
        2024-01-15,2150.4,148.2,180.0,210.5,72.1
        2024-01-16,"1,980.0",141.0,160.2,190.8,65.4
        """
        let result = NutritionCsvImporter.parse(text: csv)

        XCTAssertEqual(result.importedDays, 2)
        XCTAssertEqual(result.skippedRows, 0)
        XCTAssertEqual(result.earliestDay, "2024-01-15")
        XCTAssertEqual(result.latestDay, "2024-01-16")

        let d1 = result.rows[0]
        XCTAssertEqual(d1.day, "2024-01-15")
        XCTAssertEqual(d1.caloriesIn, 2150.4)
        XCTAssertEqual(d1.proteinG, 148.2)
        // Exact "Carbs (g)" must win over "Net Carbs (g)".
        XCTAssertEqual(d1.carbsG, 210.5)
        XCTAssertEqual(d1.fatG, 72.1)
        XCTAssertNil(d1.weight)

        // Quoted thousands separator parses.
        XCTAssertEqual(result.rows[1].caloriesIn, 1980.0)
    }

    func testCronometerDateHeaderVariant() {
        // Some Cronometer exports use "Date" instead of "Day".
        let csv = """
        Date,Energy (kcal),Protein (g),Carbs (g),Fat (g)
        2024-03-01,1850,120,200,60
        """
        let result = NutritionCsvImporter.parse(text: csv)
        XCTAssertEqual(result.importedDays, 1)
        XCTAssertEqual(result.rows[0].day, "2024-03-01")
        XCTAssertEqual(result.rows[0].caloriesIn, 1850)
    }

    // MARK: - MacroFactor header shape

    func testMacroFactorHeaders() {
        let csv = """
        Date,Calories,Protein,Carbs,Fat
        2024-02-01,2200,150,220,75
        2024-02-02,2100,145,205,70
        2024-02-03,2350,155,240,80
        """
        let result = NutritionCsvImporter.parse(text: csv)

        XCTAssertEqual(result.importedDays, 3)
        XCTAssertEqual(result.skippedRows, 0)
        XCTAssertEqual(result.rows[0].caloriesIn, 2200)
        XCTAssertEqual(result.rows[2].day, "2024-02-03")
        XCTAssertEqual(result.rows[2].proteinG, 155)
        XCTAssertEqual(result.rows[2].carbsG, 240)
        XCTAssertEqual(result.rows[2].fatG, 80)
    }

    // MARK: - Generic case-insensitive fallback (+ optional weight)

    func testGenericHeadersCaseInsensitiveWithWeight() {
        let csv = """
        DAY,kcal,PROTEIN,Total Carbohydrates,Total Fat,Saturated Fat,Body Weight
        2024-04-10,1750.5,110.2,190.4,58.8,20.1,81.3
        """
        let result = NutritionCsvImporter.parse(text: csv)

        XCTAssertEqual(result.importedDays, 1)
        let row = result.rows[0]
        XCTAssertEqual(row.day, "2024-04-10")
        XCTAssertEqual(row.caloriesIn, 1750.5)
        XCTAssertEqual(row.proteinG, 110.2)
        XCTAssertEqual(row.carbsG, 190.4)
        // "Total Fat" must win; "Saturated Fat" is excluded from the fallback.
        XCTAssertEqual(row.fatG, 58.8)
        XCTAssertEqual(row.weight, 81.3)
    }

    // MARK: - Malformed rows are skipped, never fatal

    func testMalformedRowsSkippedAndCounted() {
        let csv = """
        Date,Calories,Protein,Carbs,Fat
        2024-05-01,2000,140,210,68
        15/05/2024,1900,135,200,65
        not a date,1800,130,190,60
        2024-13-40,1700,125,180,55
        2024-05-02,,,,
        2024-05-03,2050,142,215,70
        """
        let result = NutritionCsvImporter.parse(text: csv)

        // Two good rows; bad-date x3 + all-empty-values x1 skipped.
        XCTAssertEqual(result.importedDays, 2)
        XCTAssertEqual(result.skippedRows, 4)
        XCTAssertEqual(result.rows.map(\.day), ["2024-05-01", "2024-05-03"])
        XCTAssertEqual(result.earliestDay, "2024-05-01")
        XCTAssertEqual(result.latestDay, "2024-05-03")
    }

    func testEmptyAndHeaderOnlyInput() {
        let empty = NutritionCsvImporter.parse(text: "")
        XCTAssertEqual(empty.importedDays, 0)
        XCTAssertEqual(empty.skippedRows, 0)
        XCTAssertNil(empty.earliestDay)

        let headerOnly = NutritionCsvImporter.parse(text: "Date,Calories,Protein,Carbs,Fat\n")
        XCTAssertEqual(headerOnly.importedDays, 0)
        XCTAssertEqual(headerOnly.skippedRows, 0)
    }

    // MARK: - Metric-series projection

    func testMetricPointsProjection() {
        let csv = """
        Date,Calories,Protein,Carbs,Fat,Weight
        2024-06-01,2000,140,210,68,80.5
        2024-06-02,1900,,200,,
        """
        let result = NutritionCsvImporter.parse(text: csv)
        let points = result.metricPoints

        // Day 1 emits all five keys; day 2 only the two present values.
        XCTAssertEqual(points.count, 7)

        func value(_ day: String, _ key: String) -> Double? {
            points.first { $0.day == day && $0.key == key }?.value
        }
        XCTAssertEqual(value("2024-06-01", NutritionCsvImporter.Keys.caloriesIn), 2000)
        XCTAssertEqual(value("2024-06-01", NutritionCsvImporter.Keys.proteinG), 140)
        XCTAssertEqual(value("2024-06-01", NutritionCsvImporter.Keys.carbsG), 210)
        XCTAssertEqual(value("2024-06-01", NutritionCsvImporter.Keys.fatG), 68)
        XCTAssertEqual(value("2024-06-01", NutritionCsvImporter.Keys.weight), 80.5)
        XCTAssertEqual(value("2024-06-02", NutritionCsvImporter.Keys.caloriesIn), 1900)
        XCTAssertEqual(value("2024-06-02", NutritionCsvImporter.Keys.carbsG), 200)
        XCTAssertNil(value("2024-06-02", NutritionCsvImporter.Keys.proteinG))

        XCTAssertEqual(NutritionCsvImporter.sourceId, "nutrition-csv")
    }

    // MARK: - Duplicate days: latest value wins (mirrors store upsert)

    func testDuplicateDayLatestWins() {
        let csv = """
        Date,Calories,Protein,Carbs,Fat
        2024-07-01,2000,140,210,68
        2024-07-01,2100,,215,
        """
        let result = NutritionCsvImporter.parse(text: csv)
        XCTAssertEqual(result.importedDays, 1)
        let row = result.rows[0]
        XCTAssertEqual(row.caloriesIn, 2100)   // overwritten by the later row
        XCTAssertEqual(row.proteinG, 140)      // later nil keeps the earlier value
        XCTAssertEqual(row.carbsG, 215)
        XCTAssertEqual(row.fatG, 68)
    }

    // MARK: - Date canonicalisation details

    func testDateTimeSuffixTolerated() {
        XCTAssertEqual(NutritionCsvImporter.canonicalDay("2024-08-01"), "2024-08-01")
        XCTAssertEqual(NutritionCsvImporter.canonicalDay("2024-08-01 07:30"), "2024-08-01")
        XCTAssertEqual(NutritionCsvImporter.canonicalDay("2024-08-01T07:30:00"), "2024-08-01")
        XCTAssertNil(NutritionCsvImporter.canonicalDay("2024-08-015"))
        XCTAssertNil(NutritionCsvImporter.canonicalDay("01-08-2024"))
        XCTAssertNil(NutritionCsvImporter.canonicalDay(""))
    }
}
