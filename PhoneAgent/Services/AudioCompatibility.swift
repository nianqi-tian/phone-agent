import AVFoundation

enum AudioCompatibility {
    static var inactivityNotification: Notification.Name {
        if #available(iOS 27, *) {
            return AVAudioSession.didBecomeInactiveNotification
        }
        return AVAudioSession.interruptionNotification
    }

    static func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if #available(iOS 27, *) {
            return AVAudioPCMBuffer(copying: source)
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: max(source.frameCapacity, source.frameLength)) else {
            return nil
        }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(from.count, to.count) {
            guard let src = from[index].mData, let dst = to[index].mData else { continue }
            memcpy(dst, src, Int(from[index].mDataByteSize))
        }
        return copy
    }

    static func installTap(on node: AVAudioNode, bufferSize: AVAudioFrameCount, format: AVAudioFormat?, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if #available(iOS 27, *) {
            try node.installAudioTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                handler(AVAudioPCMBuffer(copying: buffer))
            }
        } else {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
                guard let copy = copyPCMBuffer(buffer) else { return }
                handler(copy)
            }
        }
    }

    static func connect(_ engine: AVAudioEngine, _ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat?) throws {
        if #available(iOS 27, *) {
            try engine.connectNode(source, to: destination, format: format)
        } else {
            engine.connect(source, to: destination, format: format)
        }
    }

    static func play(_ player: AVAudioPlayerNode) throws {
        if #available(iOS 27, *) {
            try player.playAudio()
        } else {
            player.play()
        }
    }
}
