import ReplayKit
import Network
import CoreImage
import UIKit

@objc(SampleHandler)
final class SampleHandler: RPBroadcastSampleHandler {
    private let queue = DispatchQueue(label: "PhoneAgent.broadcast")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maxSide = 1280
    private var connection: NWConnection?
    private var lastSent = Date.distantPast
    private var lastHash: UInt64 = 0
    private var sending = false
    private var started = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        queue.async { self.connect(attempt: 0) }
    }

    override func broadcastFinished() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.started = false
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        queue.sync { handle(sampleBuffer) }
    }

    private func connect(attempt: Int) {
        connection?.cancel()
        let connection = NWConnection(
            host: NWEndpoint.Host(BroadcastWire.host),
            port: NWEndpoint.Port(rawValue: BroadcastWire.port)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.started = true
                case .failed(let error):
                    connection.cancel()
                    if attempt < 8 {
                        self.queue.asyncAfter(deadline: .now() + 0.4) { self.connect(attempt: attempt + 1) }
                    } else {
                        self.finishBroadcastWithError(error)
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard started, connection?.state == .ready, !sending else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSent) >= 0.5 else { return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let hash = fingerprint(buffer)
        let width = UInt32(CVPixelBufferGetWidth(buffer))
        let height = UInt32(CVPixelBufferGetHeight(buffer))
        let timestamp = UInt64(now.timeIntervalSince1970 * 1000)
        if lastHash != 0, hash == lastHash {
            lastSent = now
            send(BroadcastWire.packet(width: width, height: height, timestamp: timestamp, flags: BroadcastWire.idle, jpeg: Data()))
            return
        }
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, CGFloat(maxSide) / max(source.extent.width, source.extent.height))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return }
            let image = UIImage(cgImage: cg)
            guard let jpeg = image.jpegData(compressionQuality: 0.6) else { return }
            lastHash = hash
            lastSent = now
            send(BroadcastWire.packet(width: width, height: height, timestamp: timestamp, flags: BroadcastWire.frame, jpeg: jpeg))
        }
    }

    private func send(_ data: Data) {
        guard let connection, connection.state == .ready else { return }
        sending = true
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if error != nil {
                    self.finishBroadcastWithError(error ?? NSError(
                        domain: "PhoneAgentBroadcast", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "屏幕帧发送失败"]
                    ))
                }
            }
        })
    }

    private func fingerprint(_ buffer: CVPixelBuffer) -> UInt64 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        // ReplayKit delivers bi-planar YUV (420f); sample the luma plane there, BGRA otherwise.
        let planar = CVPixelBufferIsPlanar(buffer)
        let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        guard let base else { return 0 }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let bytesPerPixel = planar ? 1 : 4
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var hash: UInt64 = 14_695_981_039_346_656_037
        // A 32x32 grid catches small changes such as a toggled switch or a typed character.
        let stepY = max(1, height / 32)
        let stepX = max(1, width / 32)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * stride + min(x * bytesPerPixel, max(0, stride - bytesPerPixel))
                for channel in 0..<min(3, bytesPerPixel) {
                    hash ^= UInt64(bytes[offset + channel])
                    hash &*= 1_099_511_628_211
                }
                x += stepX
            }
            y += stepY
        }
        hash ^= UInt64(width)
        hash ^= UInt64(height) &<< 16
        return hash
    }
}

enum BroadcastWire {
    static let host = "127.0.0.1"
    static let port: UInt16 = 18765
    static let frame: UInt8 = 0
    static let idle: UInt8 = 1

    static func packet(width: UInt32, height: UInt32, timestamp: UInt64, flags: UInt8, jpeg: Data) -> Data {
        var payload = Data()
        payload.append(be32(width))
        payload.append(be32(height))
        payload.append(be64(timestamp))
        payload.append(flags)
        payload.append(jpeg)
        var packet = be32(UInt32(payload.count))
        packet.append(payload)
        return packet
    }

    static func be32(_ value: UInt32) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 4)
    }

    static func be64(_ value: UInt64) -> Data {
        var big = value.bigEndian
        return Data(bytes: &big, count: 8)
    }
}
