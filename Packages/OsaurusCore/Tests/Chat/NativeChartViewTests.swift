import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct NativeChartViewTests {
    @Test
    func pieDataPointsUseCategoriesAsSliceNames() throws {
        let series = ChartSeries(name: "Revenue", data: [10, 20, nil, 40])

        let points = NativeChartView.chartDataPoints(
            for: series,
            chartType: "pie",
            categories: ["Hardware", "Software"]
        )

        let dicts = try dictionaries(from: points)
        #expect(dicts.count == 4)
        #expect(dicts[0]["name"] as? String == "Hardware")
        #expect((dicts[0]["y"] as? NSNumber)?.doubleValue == 10)
        #expect(dicts[1]["name"] as? String == "Software")
        #expect((dicts[1]["y"] as? NSNumber)?.doubleValue == 20)
        #expect(dicts[2]["name"] as? String == "Slice 3")
        #expect(dicts[2]["y"] is NSNull)
        #expect(dicts[3]["name"] as? String == "Slice 4")
        #expect((dicts[3]["y"] as? NSNumber)?.doubleValue == 40)
    }

    @Test
    func pieDataPointsFallBackWhenCategoriesAreMissingOrBlank() throws {
        let series = ChartSeries(name: "Mix", data: [1, 2])

        let points = NativeChartView.chartDataPoints(
            for: series,
            chartType: "pie",
            categories: ["", "  "]
        )

        let dicts = try dictionaries(from: points)
        #expect(dicts.map { $0["name"] as? String } == ["Slice 1", "Slice 2"])
    }

    @Test(arguments: ["bar", "line", "area", "scatter"])
    func nonPieDataPointsRemainScalarArrays(chartType: String) {
        let series = ChartSeries(name: "Values", data: [1.5, nil, 3.25])

        let points = NativeChartView.chartDataPoints(
            for: series,
            chartType: chartType,
            categories: ["Ignored", "Also ignored", "Still ignored"]
        )

        #expect(points.count == 3)
        #expect(points.allSatisfy { !($0 is NSDictionary) })
        #expect((points[0] as? NSNumber)?.doubleValue == 1.5)
        #expect(points[1] is NSNull)
        #expect((points[2] as? NSNumber)?.doubleValue == 3.25)
    }

    private func dictionaries(from points: [AnyObject]) throws -> [NSDictionary] {
        try points.map { point in
            try #require(point as? NSDictionary)
        }
    }
}
