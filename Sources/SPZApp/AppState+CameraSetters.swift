import Foundation
import SwiftUI
import CoreGraphics

/// AppState camera ROI setters + updateCamera — extension AppState.
/// Extracted ze AppState.swift jako součást big-refactor split (krok #10).
/// Drží jen methods co používají `cameras` (@Published) + `save()` —
/// žádné stored properties (Swift extension limit), žádné private state.
/// Storage methods (saveCamerasImmediately, loadFromDisk, defaultCameras)
/// + camerasSaveTimer + configURL ZŮSTÁVAJÍ v root AppState.swift.

@MainActor
extension AppState {
    func updateCamera(_ cam: CameraConfig) {
        if let idx = cameras.firstIndex(where: { $0.name == cam.name }) {
            cameras[idx] = cam
        } else {
            cameras.append(cam)
        }
        save()
    }

    func setRoi(name: String, roi: CGRect?) {
        if let idx = cameras.firstIndex(where: { $0.name == name }) {
            let currentRot = cameras[idx].roi?.rotationDeg ?? 0
            cameras[idx].roi = roi.map { RoiBox(rect: $0, rotationDeg: currentRot) }
            save()
        }
    }

    /// Zachová velikost/pozici ROI, mění jen rotaci kolem středu.
    func setRoiRotation(name: String, degrees: Double) {
        guard let idx = cameras.firstIndex(where: { $0.name == name }) else { return }
        guard var roi = cameras[idx].roi else { return }
        roi.rotationDeg = degrees
        cameras[idx].roi = roi
        save()
    }

    /// Nastaví (nebo smaže) perspektivní korekci na ROI. Pokud se perspective
    /// ZMĚNÍ (ne pouze scale/strength tuning ale reálně rohy), detectionQuad se
    /// automaticky resetuje — jeho souřadnice v rámci ROI by po novém warpu
    /// ukazovaly na jinou část scény.
    func setRoiPerspective(name: String, perspective: PerspectiveConfig?) {
        guard let idx = cameras.firstIndex(where: { $0.name == name }) else { return }
        guard var roi = cameras[idx].roi else { return }
        // Detekce změny rohů (= corners shifted, ne jen scale). Pokud ano,
        // zneplatni detection quad — jinak ukazuje na nesprávné místo v scéně.
        let oldCorners = roi.perspective.map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }
        let newCorners = perspective.map { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }
        let cornersChanged: Bool = {
            guard let o = oldCorners, let n = newCorners else {
                return (oldCorners == nil) != (newCorners == nil)
            }
            for i in 0..<4 where abs(o[i].x - n[i].x) > 0.001 || abs(o[i].y - n[i].y) > 0.001 {
                return true
            }
            return false
        }()
        roi.perspective = perspective
        if cornersChanged {
            var resets: [String] = []
            if roi.detectionQuad != nil {
                roi.detectionQuad = nil
                resets.append("detectionQuad")
            }
            if !roi.exclusionMasks.isEmpty {
                roi.exclusionMasks = []
                resets.append("exclusionMasks")
            }
            if !resets.isEmpty {
                FileHandle.safeStderrWrite(
                    "[AppState] perspective corners changed → \(resets.joined(separator: ",")) reset\n".data(using: .utf8)!)
            }
        }
        cameras[idx].roi = roi
        save()
    }

    /// Nastaví (nebo smaže) oblast detekce uvnitř korigovaného ROI.
    func setRoiDetectionQuad(name: String, quad: [CGPoint]?) {
        guard let idx = cameras.firstIndex(where: { $0.name == name }) else { return }
        guard var roi = cameras[idx].roi else { return }
        roi.detectionQuad = quad
        cameras[idx].roi = roi
        save()
    }

    /// Nastaví (nebo smaže) interaktivní 8-DOF perspektivní kalibraci.
    /// Aplikuje se POSLEDNÍ ve stacku (rotace → existing perspective → tato calibrace).
    /// nil = bez calibrace.
    func setRoiPerspectiveCalibration(name: String, calibration: PerspectiveCalibration?) {
        guard let idx = cameras.firstIndex(where: { $0.name == name }) else { return }
        guard var roi = cameras[idx].roi else { return }
        let calibrationChanged = roi.perspectiveCalibration != calibration
        roi.perspectiveCalibration = calibration
        if calibrationChanged {
            var resets: [String] = []
            if roi.detectionQuad != nil {
                roi.detectionQuad = nil
                resets.append("detectionQuad")
            }
            if !roi.exclusionMasks.isEmpty {
                roi.exclusionMasks = []
                resets.append("exclusionMasks")
            }
            if !resets.isEmpty {
                FileHandle.safeStderrWrite(
                    "[AppState] 8DOF calibration changed → \(resets.joined(separator: ",")) reset\n".data(using: .utf8)!)
            }
        }
        cameras[idx].roi = roi
        save()
    }

    /// Nastaví exclusion mask rects v normalized [0,1] TL-origin souřadnicích.
    /// Masks se aplikují PO perspective + detectionQuad (tedy coords jsou relative
    /// k post-processed workspace, ne k raw kamera framu). OCR text observations
    /// uvnitř kterékoli mask se ignorují. Use case: trvalé nápisy nad bránou
    /// (banner "Generic Signboard Text") co Vision čte jako fake plate.
    func setRoiExclusionMasks(name: String, masks: [CGRect]) {
        guard let idx = cameras.firstIndex(where: { $0.name == name }) else { return }
        guard var roi = cameras[idx].roi else { return }
        // Validate — reject malformed rects (0 area, out-of-bounds).
        let clean = masks.filter { r in
            r.width > 0.01 && r.height > 0.01 &&
            r.minX >= 0 && r.maxX <= 1 &&
            r.minY >= 0 && r.maxY <= 1
        }
        roi.exclusionMasks = clean
        cameras[idx].roi = roi
        save()
    }

    /// Per-camera MIN filtr (Vision min observation height fraction).
    func setCameraMinObs(name: String, value: Double) {
        guard let idx = cameras.firstIndex(where: { $0.name == name }) else { return }
        cameras[idx].ocrMinObsHeightFraction = max(0.012, min(0.25, value))
        save()
    }

}
