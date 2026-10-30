import Foundation
import UIKit
import Network
import ReplayKit
import SwiftUI

enum BroadcastCaptureConfig {
    static let host = "127.0.0.1"
    static let port: UInt16 = 18765
    static let extensionBundleID = "com.benbenqi.phoneagent.broadcast"
    static let frame: UInt8 = 0
    static let idle: UInt8 = 1
}

final class BroadcastCapture {
    private let onUpdate: (CaptureUpdate, UUID, UInt64) -> Void
    private let maxSide: Int
    private let queue = DispatchQueue(label: "PhoneAgent.broadcast.listener")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var pending = Data()
    private var lastFrame: ScreenFrame?
    private var lastPublishedAt = Date.distantPast
    private var times: [Date] = []
    private var stopped = false
    private var generation = UUID()
    private var updateSequence: UInt64 = 0
    private let lock = NSLock()

    init(maxSide: Int, onUpdate: @escaping (CaptureUpdate, UUID, UInt64) -> Void) {
        self.maxSide = max(640, min(2048, maxSide))
        self.onUpdate = onUpdate
    }

    func accepts(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped && generation == token
    }

    func start() {
        lock.lock()
        stopped = false
        generation = UUID()
        updateSequence = 0
        let token = generation
        lock.unlock()
        queue.async { self.startListener(generation: token) }
    }

    func stop() {
        lock.lock()
        stopped = true
        generation = UUID()
        lock.unlock()
        queue.async { self.teardown() }
    }

    private func startListener(generation token: UUID) {
        teardown()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(BroadcastCaptureConfig.host),
                port: NWEndpoint.Port(rawValue: BroadcastCaptureConfig.port)!
            )
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.attach(connection, generation: token) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.publish(.state(running: false, status: "无法开始本机捕获通道", error: error.localizedDescription), generation: token)
                }
            }
            listener.start(queue: queue)
            publish(.waiting("请点按开始整屏广播"), generation: token)
        } catch {
            publish(.state(running: false, status: "无法监听屏幕帧", error: error.localizedDescription), generation: token)
        }
    }

    private func attach(_ next: NWConnection, generation token: UUID) {
        connection?.cancel()
        connection = next
        pending.removeAll(keepingCapacity: false)
        lastFrame = nil
        lastPublishedAt = .distantPast
        times = []
        next.stateUpdateHandler = { [weak self] state in
            self?.queue.async {
                switch state {
                case .ready:
                    self?.receive(generation: token)
                    self?.publish(.state(running: true, status: "捕获已开始", error: nil), generation: token)
                case .failed, .cancelled:
                    self?.handleDisconnect(generation: token)
                default:
                    break
                }
            }
        }
        next.start(queue: queue)
    }

    private func receive(generation token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self else { return }
                if let data, !data.isEmpty { self.consume(data, generation: token) }
                if isComplete || error != nil {
                    self.handleDisconnect(generation: token)
                    return
                }
                self.receive(generation: token)
            }
        }
    }

    private func consume(_ data: Data, generation token: UUID) {
        pending.append(data)
        while pending.count >= 4 {
            let length = pending.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard length >= 17, length <= 6_000_000 else {
                pending.removeAll(keepingCapacity: false)
                return
            }
            let total = 4 + Int(length)
            guard pending.count >= total else { return }
            let payload = pending.subdata(in: 4..<total)
            pending.removeSubrange(0..<total)
            decode(payload, generation: token)
        }
    }

    private func decode(_ payload: Data, generation token: UUID) {
        let width = payload.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let height = payload.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        let timestamp = payload.subdata(in: 8..<16).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        let flags = payload[16]
        let capturedAt = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let now = Date()
        if flags == BroadcastCaptureConfig.idle {
            guard let previous = lastFrame, now.timeIntervalSince(lastPublishedAt) >= 0.25 else { return }
            let frame = ScreenFrame(
                image: previous.image, jpeg: previous.jpeg, capturedAt: previous.capturedAt,
                sourceWidth: previous.sourceWidth, sourceHeight: previous.sourceHeight,
                fullDisplay: true, confirmedAt: now, captureID: token
            )
            lastFrame = frame
            lastPublishedAt = now
            publish(.frame(frame, fps: 0), generation: token)
            return
        }
        let jpeg = payload.subdata(in: 17..<payload.count)
        guard let image = UIImage(data: jpeg) else { return }
        times.append(now)
        times.removeAll { now.timeIntervalSince($0) > 2 }
        let duration = now.timeIntervalSince(times.first ?? now)
        let fps = duration > 0 ? Double(max(0, times.count - 1)) / duration : 0
        let frame = ScreenFrame(
            image: image, jpeg: jpeg, capturedAt: capturedAt,
            sourceWidth: Int(width), sourceHeight: Int(height),
            fullDisplay: true, confirmedAt: now, captureID: token
        )
        lastFrame = frame
        lastPublishedAt = now
        publish(.frame(frame, fps: fps), generation: token)
    }

    private func handleDisconnect(generation token: UUID) {
        connection?.cancel()
        connection = nil
        pending.removeAll(keepingCapacity: false)
        lastFrame = nil
        lock.lock(); let live = !stopped && generation == token; lock.unlock()
        if live {
            publish(.state(running: false, status: "系统已停止屏幕共享", error: nil), generation: token)
        }
    }

    private func teardown() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        pending.removeAll(keepingCapacity: false)
        lastFrame = nil
        times = []
    }

    private func publish(_ update: CaptureUpdate, generation token: UUID) {
        lock.lock()
        guard !stopped && generation == token else { lock.unlock(); return }
        updateSequence += 1
        let sequence = updateSequence
        lock.unlock()
        onUpdate(update, token, sequence)
    }
}

struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = BroadcastCaptureConfig.extensionBundleID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = BroadcastCaptureConfig.extensionBundleID
        for subview in uiView.subviews {
            if let button = subview as? UIButton {
                button.setImage(nil, for: .normal)
                button.setTitle(nil, for: .normal)
                button.backgroundColor = .clear
            }
        }
    }
}

struct BroadcastStartControl: View {
    var enabled = true
    var title = "开始整屏广播"
    var body: some View {
        ZStack {
            Label(title, systemImage: "rectangle.on.rectangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(AgentPalette.accent.opacity(enabled ? 1 : 0.38), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            BroadcastPickerView()
                .frame(maxWidth: .infinity, minHeight: 48)
                .opacity(0.02)
                .allowsHitTesting(enabled)
        }
        .accessibilityLabel(title)
    }
}
