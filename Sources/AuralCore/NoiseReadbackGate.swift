/// 已排队不等于已写出；避免先前刷新读数提前结束尚未执行的 SET。
struct NoiseReadbackGate {
    private(set) var desired: NoiseMode?
    private var writeSent = false
    private var verificationSent = false

    mutating func begin(_ mode: NoiseMode) {
        desired = mode
        writeSent = false
        verificationSent = false
    }

    mutating func didSendWrite() { if desired != nil { writeSent = true } }
    mutating func didSendVerification() { if writeSent { verificationSent = true } }

    func confirms(_ mode: NoiseMode) -> Bool {
        desired == mode && writeSent && verificationSent
    }

    mutating func clear() { self = NoiseReadbackGate() }
}
