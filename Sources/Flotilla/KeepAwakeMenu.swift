import SwiftUI
import FlotillaCore

/// Keep Awake for a host (Q44's time-bounded lease, built 10 October): an hour, four, or until nine
/// tomorrow morning — never more than a day — or stop. The host refuses on battery and says so; both
/// Macs show until when. One menu, used by the host's page and its row menu in Hosts.
struct KeepAwakeMenu: View {
    let model: AppModel
    let fingerprint: PeerFingerprint
    @State private var failure: String?

    private var until: Date? { model.hostMode.facts[fingerprint]?.keepAwakeUntil.flatMap { $0 > Date() ? $0 : nil } }

    var body: some View {
        Menu("Keep Awake") {
            Button("For 1 Hour") { ask(3600) }
            Button("For 4 Hours") { ask(4 * 3600) }
            Button("Until 9:00 Tomorrow") { ask(Self.secondsUntilNineTomorrow()) }
            Divider()
            Button("Stop Keeping Awake") { ask(0) }.disabled(until == nil)
        }
        .help(until.map { "Kept awake until \($0.formatted(date: .omitted, time: .shortened))" }
              ?? "Ask this Mac to stay awake for a while; it says no on battery")
        .alert("Couldn't keep it awake", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func ask(_ seconds: Int) {
        Task { failure = await model.keepAwake(fingerprint, seconds: seconds) }
    }

    /// Until nine tomorrow morning, capped at a day.
    static func secondsUntilNineTomorrow(now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? now
        return min(HostCall.maxKeepAwakeSeconds, max(60, Int(nine.timeIntervalSince(now))))
    }
}
