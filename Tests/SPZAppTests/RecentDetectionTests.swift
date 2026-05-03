import Testing
import Foundation
import CoreGraphics
@testable import SPZApp

@Suite("RecentDetection vehicle fields")
struct RecentDetectionTests {

    @Test func vehicleFields_defaultNil() {
        let rec = RecentDetection(
            id: 1, timestamp: Date(), cameraName: "vjezd",
            plate: "7ZF1234", region: .cz, confidence: 0.95,
            bbox: .zero, cropImage: nil
        )
        #expect(rec.vehicleType == nil)
        #expect(rec.vehicleColor == nil)
        #expect(rec.vehicleDirection == nil)
    }

    @Test func vehicleFields_mutable() {
        var rec = RecentDetection(
            id: 1, timestamp: Date(), cameraName: "vjezd",
            plate: "7ZF1234", region: .cz, confidence: 0.95,
            bbox: .zero, cropImage: nil
        )
        rec.vehicleType = "suv"
        rec.vehicleColor = "red"
        #expect(rec.vehicleType == "suv")
        #expect(rec.vehicleColor == "red")
    }

    /// Regression test pro merge logic — pozdější detekce s non-nil vehicle
    /// fields musí overridovat předchozí nil nebo staré hodnoty
    /// (first-commit byl daleko → možná špatný asphalt sample → nahrazen později).
    @Test @MainActor func recentBuffer_exactMerge_preservesNewerVehicle() {
        let buf = RecentBuffer(capacity: 10)
        let base = Date()
        var first = RecentDetection(
            id: 1, timestamp: base, cameraName: "vjezd",
            plate: "7ZF1234", region: .cz, confidence: 0.8,
            bbox: .zero, cropImage: nil
        )
        first.vehicleColor = "gray"  // špatný - prvni detekce asphalt
        buf.add(first)

        var second = RecentDetection(
            id: 2, timestamp: base.addingTimeInterval(0.5), cameraName: "vjezd",
            plate: "7ZF1234", region: .cz, confidence: 0.9,
            bbox: .zero, cropImage: nil
        )
        second.vehicleType = "car"
        second.vehicleColor = "red"  // správný - pozdější detekce
        buf.add(second)

        let items = buf.items
        #expect(items.count == 1)  // merged do jednoho
        #expect(items[0].count == 2)
        #expect(items[0].vehicleColor == "red")
        #expect(items[0].vehicleType == "car")
    }

    @Test @MainActor func recentBuffer_substringMerge_upgrade_preservesNewerVehicle() {
        let buf = RecentBuffer(capacity: 10)
        let base = Date()
        var first = RecentDetection(
            id: 1, timestamp: base, cameraName: "vjezd",
            plate: "ZF1234", region: .cz, confidence: 0.7,  // short fragment
            bbox: .zero, cropImage: nil
        )
        first.vehicleColor = "gray"
        buf.add(first)

        var second = RecentDetection(
            id: 2, timestamp: base.addingTimeInterval(1.0), cameraName: "vjezd",
            plate: "7ZF1234", region: .cz, confidence: 0.9,  // longer, superset
            bbox: .zero, cropImage: nil
        )
        second.vehicleType = "suv"
        second.vehicleColor = "blue"
        buf.add(second)

        let items = buf.items
        #expect(items.count == 1)
        #expect(items[0].plate == "7ZF1234")  // longer wins
        #expect(items[0].vehicleColor == "blue")
        #expect(items[0].vehicleType == "suv")
    }
}
