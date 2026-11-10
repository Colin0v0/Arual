import Foundation

/// 音频路由与耳机控制目标分离，但控制目标只能来自已确认路由的真实成员。
/// 同一路由中的可控耳机全部参与控制，不再维护单一的手选目标。
public struct HeadphoneControlSelection: Equatable {
    public private(set) var candidates: [AudioOutput] = []
    public init() {}

    public mutating func update(confirmed: ConfirmedOutputRoute?, snapshot: SystemAudioSnapshot,
                                supports: (AudioOutput) -> Bool) {
        guard let confirmed,
              snapshot.selectedID == confirmed.output.id,
              snapshot.outputs.contains(where: { $0.id == confirmed.output.id && $0.uid == confirmed.output.uid }) else {
            candidates = []
            return
        }
        let members = confirmed.aggregate?.outputs ?? [confirmed.output]
        candidates = members.filter { member in
            member.isBluetooth && snapshot.outputs.contains { $0.id == member.id && $0.uid == member.uid } && supports(member)
        }
    }
}
