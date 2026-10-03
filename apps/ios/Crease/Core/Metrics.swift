import Foundation
import MetricKit
import os

/// MetricKit, on the device only (2026-10-03).
///
/// iOS hands the app one metrics payload a day (launch time, hangs, memory,
/// CPU) and a diagnostics payload after a crash, hang, CPU or disk-write
/// blowup. Nothing here leaves the phone: Crease's App Privacy label does not
/// declare Performance Data or Crash Data, so sending these to the backend
/// would need the label changed first (owner's call). Each payload is logged
/// under the "metrics" category, readable from a TestFlight phone with
///
///     log stream --predicate 'subsystem == "com.divinedavis.crease" && category == "metrics"'
///
/// (Console.app, phone attached). The same numbers from every phone whose owner
/// shares analytics with developers reach the Xcode Organizer without any of
/// this; scripts/organizer-report.py prints them on every ship.
final class Metrics: NSObject, MXMetricManagerSubscriber {
    static let shared = Metrics()
    private let log = Logger(subsystem: "com.divinedavis.crease", category: "metrics")

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            log.notice("metrics \(p.latestApplicationVersion, privacy: .public): \(String(decoding: p.jsonRepresentation(), as: UTF8.self), privacy: .public)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            let crashes = p.crashDiagnostics?.count ?? 0, hangs = p.hangDiagnostics?.count ?? 0
            log.error("diagnostics: \(crashes) crash(es), \(hangs) hang(s): \(String(decoding: p.jsonRepresentation(), as: UTF8.self), privacy: .public)")
        }
    }
}
