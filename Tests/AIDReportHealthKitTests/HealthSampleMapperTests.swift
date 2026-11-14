import AIDReportHealthKit
import AIDReportKit
import XCTest

final class HealthSampleMapperTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_767_225_600)

    func testGlucoseKinds() {
        XCTAssertEqual(HealthSampleMapper.glucose(HealthSample(start: t0, value: 120)).kind, .sensor)
        XCTAssertEqual(HealthSampleMapper.glucose(HealthSample(start: t0, value: 120, wasUserEntered: true)).kind, .fingerstick)
        XCTAssertEqual(HealthSampleMapper.glucose(HealthSample(start: t0, value: 120, isDisplayOnly: true)).kind, .calibration)
    }

    func testSyncIdentifierIsPreferredAsSourceID() {
        let uuid = UUID()
        XCTAssertEqual(HealthSampleMapper.glucose(HealthSample(start: t0, value: 1, uuid: uuid, syncIdentifier: "sync-1")).sourceID, "sync-1")
        XCTAssertEqual(HealthSampleMapper.glucose(HealthSample(start: t0, value: 1, uuid: uuid)).sourceID, uuid.uuidString)
    }

    func testInsulinDeliveryReasons() {
        let basal = HealthSampleMapper.insulin(HealthSample(start: t0, end: t0 + 1800, value: 0.4, insulinDeliveryReason: .basal))
        XCTAssertEqual(basal.kind, .basal)
        XCTAssertEqual(basal.units, 0.4)
        XCTAssertEqual(basal.duration, 1800)

        let temp = HealthSampleMapper.insulin(HealthSample(start: t0, end: t0 + 1800, value: 0.6, insulinDeliveryReason: .basal, isAutomatic: true))
        XCTAssertEqual(temp.kind, .tempBasal)
        XCTAssertTrue(temp.isAutomatic)

        let suspend = HealthSampleMapper.insulin(HealthSample(start: t0, end: t0 + 900, value: 0, insulinDeliveryReason: .basal, isSuspend: true))
        XCTAssertEqual(suspend.kind, .suspend)

        let smb = HealthSampleMapper.insulin(HealthSample(start: t0, value: 0.3, insulinDeliveryReason: .bolus, isAutomatic: true))
        XCTAssertEqual(smb.kind, .bolus)
        XCTAssertTrue(smb.isAutomatic)

        let pen = HealthSampleMapper.insulin(HealthSample(start: t0, value: 4, insulinDeliveryReason: .bolus, isManuallyEntered: true))
        XCTAssertTrue(pen.isExternal)
    }

    func testCarbs() {
        let entry = HealthSampleMapper.carbs(HealthSample(start: t0, value: 42, absorptionTime: 10800))
        XCTAssertEqual(entry.grams, 42)
        XCTAssertEqual(entry.absorptionTime, 10800)
        XCTAssertFalse(entry.isFatProteinEquivalent)
    }
}
