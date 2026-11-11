import Foundation

/// 控制对象来自全部已连接输出，与当前播放路由、聚合成员及音量可写性无关。
/// supports 只确认协议驱动能力，不能用“可调音量”代替耳机控制能力。
public struct HeadphoneControlSelection: Equatable {
    public private(set) var candidates: [AudioOutput] = []
    public init() {}

    public mutating func update(snapshot: SystemAudioSnapshot, supports: (AudioOutput) -> Bool) {
        candidates = snapshot.outputs.filter { $0.isBluetooth && supports($0) }
    }
}
