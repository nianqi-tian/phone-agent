import Foundation
import UIKit
import Combine
import CoreImage
import CoreMedia
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

struct ScreenFrame {
    let image: UIImage
    let jpeg: Data
    let capturedAt: Date
    // Pixel capture time and stream confirmation time differ on an unchanged screen.
    let confirmedAt: Date
    let captureID: UUID?
    let sourceWidth: Int
    let sourceHeight: Int
    let fullDisplay: Bool
    var width: Int { image.cgImage?.width ?? 0 }
    var height: Int { image.cgImage?.height ?? 0 }

    init(image: UIImage, jpeg: Data, capturedAt: Date, sourceWidth: Int,
         sourceHeight: Int, fullDisplay: Bool, confirmedAt: Date? = nil, captureID: UUID? = nil) {
        self.image = image; self.jpeg = jpeg; self.capturedAt = capturedAt
        self.confirmedAt = confirmedAt ?? capturedAt; self.captureID = captureID
        self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight; self.fullDisplay = fullDisplay
    }
}

@MainActor
final class CaptureService: ObservableObject {
    @Published private(set) var frame: ScreenFrame?
    private(set) var lastBackgroundFrame: ScreenFrame?
    @Published private(set) var state = "尚未开始捕获"
    @Published private(set) var running = false
    @Published private(set) var fps = 0.0
    @Published private(set) var error = ""
    @Published private(set) var waitingForPicker = false
    var onStop: (() -> Void)?
    var maxSide = 1280
    private var session = UUID()
    private var lastUpdateSequence: UInt64 = 0
    #if canImport(ScreenCaptureKit)
    private var nativeCaptureBox: AnyObject?
    #endif
    private var broadcast: BroadcastCapture?
    func start() {
        guard !running && !waitingForPicker else { return }
        error = ""; frame = nil; lastBackgroundFrame = nil; waitingForPicker = true
        let token = UUID(); session = token; lastUpdateSequence = 0
        if #available(iOS 27, *) {
            state = "请在系统选择器中共享整屏"
            startNative(token: token)
        } else {
            state = "请点按开始整屏广播"
            startBroadcast(token: token)
        }
    }
    func stop() {
        session = UUID()
        if #available(iOS 27, *) { stopNative() }
        broadcast?.stop(); broadcast = nil
        running = false; waitingForPicker = false; frame = nil; lastBackgroundFrame = nil; state = "捕获已停止"; onStop?()
    }
    private func apply(_ update: CaptureUpdate, token: UUID, generation: UUID, sequence: UInt64, accepts: @escaping () -> Bool) {
        Task { @MainActor in
            guard session == token, accepts(), sequence > lastUpdateSequence else { return }
            lastUpdateSequence = sequence
            waitingForPicker = false
            switch update {
            case .frame(let frame, let fps):
                self.frame = frame; self.fps = fps; self.running = true; self.error = ""
                if UIApplication.shared.applicationState == .background { self.lastBackgroundFrame = frame }
                self.state = frame.fullDisplay ? "整屏捕获中" : "仅当前应用，不能执行整屏 Agent"
            case .waiting(let status):
                self.frame = nil; self.lastBackgroundFrame = nil; self.fps = 0
                self.running = true; self.state = status
            case .state(let running, let status, let error):
                self.running = running; self.state = status; self.error = error ?? ""
                if !running { self.frame = nil; self.lastBackgroundFrame = nil; self.fps = 0; self.onStop?() }
            }
        }
    }
    @available(iOS 27, *)
    private func startNative(token: UUID) {
        #if canImport(ScreenCaptureKit)
        let capture = NativeCapture(maxSide: maxSide, onUpdate: { [weak self] update, generation, sequence in
            guard let self else { return }
            self.apply(update, token: token, generation: generation, sequence: sequence) {
                (self.nativeCaptureBox as? NativeCapture)?.accepts(generation) == true
            }
        })
        nativeCaptureBox = capture; capture.present()
        #else
        waitingForPicker = false
        error = "模拟器不支持此屏幕框架，请使用真机"
        #endif
    }
    @available(iOS 27, *)
    private func stopNative() {
        #if canImport(ScreenCaptureKit)
        (nativeCaptureBox as? NativeCapture)?.stop(); nativeCaptureBox = nil
        #endif
    }
    private func startBroadcast(token: UUID) {
        let capture = BroadcastCapture(maxSide: maxSide, onUpdate: { [weak self] update, generation, sequence in
            guard let self else { return }
            self.apply(update, token: token, generation: generation, sequence: sequence) {
                self.broadcast?.accepts(generation) == true
            }
        })
        broadcast = capture
        capture.start()
    }
}

enum CaptureUpdate {
    case frame(ScreenFrame, fps: Double)
    case waiting(String)
    case state(running: Bool, status: String, error: String?)
}

#if canImport(ScreenCaptureKit)
// Owned by the main actor; frame processing runs on a serial callback queue.
@available(iOS 27, *)
private final class NativeCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private let onUpdate: (CaptureUpdate, UUID, UInt64) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maxSide: Int
    private var stream: SCStream?
    // These values are confined to framesQueue, including resets between streams.
    private var framesGeneration: UUID?
    private var lastFrame: ScreenFrame?
    private struct PendingFrame {
        let buffer: CVPixelBuffer
        let capturedAt: Date
    }
    private var pendingFrame: PendingFrame?
    private var lastPublishedAt = Date.distantPast
    private var lastWaitingStatus: String?
    private var times: [Date] = []
    private var fullDisplay = false
    private var stopped = false
    private var generation = UUID()
    private var updateSequence: UInt64 = 0
    private let framesQueue = DispatchQueue(label: "PhoneAgent.capture.frames")
    private let metadataLock = NSLock()
    init(maxSide: Int, onUpdate: @escaping (CaptureUpdate, UUID, UInt64) -> Void) {
        self.maxSide = max(640, min(2048, maxSide)); self.onUpdate = onUpdate
        super.init()
    }
    func accepts(_ token: UUID) -> Bool {
        metadataLock.lock(); defer { metadataLock.unlock() }
        return !stopped && generation == token
    }
    private func publish(_ update: CaptureUpdate, generation token: UUID) {
        metadataLock.lock()
        guard !stopped && generation == token else { metadataLock.unlock(); return }
        updateSequence += 1; let sequence = updateSequence
        metadataLock.unlock()
        onUpdate(update, token, sequence)
    }
    func present() {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else {
            publish(.state(running: false, status: "系统不允许屏幕捕获", error: "检查屏幕录制限制"), generation: generation)
            return
        }
        picker.add(self); picker.isActive = true; picker.present(using: .display)
    }
    func stop() {
        metadataLock.lock(); stopped = true; generation = UUID()
        let previous = stream; stream = nil; metadataLock.unlock()
        let picker = SCContentSharingPicker.shared; picker.remove(self); picker.isActive = false
        previous?.stopCapture { _ in }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        metadataLock.lock()
        guard !stopped else { metadataLock.unlock(); return }
        fullDisplay = filter.style == .display
        generation = UUID(); let token = generation
        let previous = self.stream; self.stream = nil
        metadataLock.unlock()
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        let native = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        config.width = max(1, Int(native.width * scale))
        config.height = max(1, Int(native.height * scale))
        // Updating the system selection replaces the existing stream rather than leaking another one.
        previous?.stopCapture { _ in }
        let next = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try next.addStreamOutput(self, type: .screen, sampleHandlerQueue: framesQueue)
            metadataLock.lock()
            guard !stopped && generation == token else { metadataLock.unlock(); return }
            self.stream = next; metadataLock.unlock()
            publish(.waiting("共享已更新，等待完整画面"), generation: token)
            next.startCapture { [weak self] error in
                guard let self else { return }
                if let error {
                    self.endStream(next, status: "捕获启动失败", error: error.localizedDescription)
                } else {
                    self.publish(.state(running: true, status: "捕获已开始", error: nil), generation: token)
                }
            }
        } catch { publish(.state(running: false, status: "捕获启动失败", error: error.localizedDescription), generation: token) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        metadataLock.lock(); let empty = self.stream == nil; let token = generation; metadataLock.unlock()
        if empty { publish(.state(running: false, status: "已取消屏幕共享", error: nil), generation: token) }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        metadataLock.lock(); let token = generation; metadataLock.unlock()
        publish(.state(running: false, status: "共享选择器失败", error: error.localizedDescription), generation: token)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        endStream(stream, error: error.localizedDescription)
    }
    private func endStream(_ stream: SCStream, status: String = "系统已停止屏幕共享", error: String?) {
        metadataLock.lock()
        guard stream === self.stream && !stopped else { metadataLock.unlock(); return }
        self.stream = nil; generation = UUID(); let token = generation
        metadataLock.unlock()
        publish(.state(running: false, status: status, error: error), generation: token)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        metadataLock.lock(); let valid = stream === self.stream && !stopped
        let isFullDisplay = fullDisplay; let token = generation; metadataLock.unlock()
        guard valid, type == .screen else { return }
        if framesGeneration != token {
            framesGeneration = token; lastFrame = nil; pendingFrame = nil
            lastPublishedAt = .distantPast; lastWaitingStatus = nil; times = []
        }
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            waitForFrame("等待可用的屏幕画面", generation: token)
            return
        }
        let now = Date()
        switch status {
        case .idle:
            // The final changed frame may have arrived during the render throttle.
            // Render those pixels before accepting any idle confirmation.
            if let pending = pendingFrame {
                pendingFrame = nil
                render(pending.buffer, capturedAt: pending.capturedAt, confirmedAt: now,
                       fullDisplay: isFullDisplay, generation: token)
                return
            }
            // Only an actual idle callback confirms that these pixels remain current.
            // Never renew freshness from a timer or from blank/suspended buffers.
            guard let previous = lastFrame, now.timeIntervalSince(lastPublishedAt) >= 0.25 else { return }
            let frame = ScreenFrame(image: previous.image, jpeg: previous.jpeg, capturedAt: previous.capturedAt,
                sourceWidth: previous.sourceWidth, sourceHeight: previous.sourceHeight, fullDisplay: isFullDisplay,
                confirmedAt: now, captureID: token)
            lastFrame = frame; lastPublishedAt = now; lastWaitingStatus = nil
            publish(.frame(frame, fps: 0), generation: token)
            return
        case .complete:
            lastFrame = nil
        case .blank, .suspended, .started:
            waitForFrame(status == .blank ? "屏幕暂不可用，等待画面恢复" : "等待屏幕画面恢复", generation: token)
            return
        case .stopped:
            lastFrame = nil; pendingFrame = nil
            endStream(stream, error: nil)
            return
        @unknown default:
            waitForFrame("等待可用的屏幕画面", generation: token)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            waitForFrame("等待完整的屏幕画面", generation: token)
            return
        }
        times.append(now); times.removeAll { now.timeIntervalSince($0) > 2 }
        // minimumFrameInterval is unavailable on iOS. Keep the newest complete
        // buffer while throttling expensive image conversion locally to 4 FPS.
        guard now.timeIntervalSince(lastPublishedAt) >= 0.25 else {
            pendingFrame = PendingFrame(buffer: buffer, capturedAt: now)
            return
        }
        pendingFrame = nil
        render(buffer, capturedAt: now, confirmedAt: now, fullDisplay: isFullDisplay, generation: token)
    }
    private func waitForFrame(_ status: String, generation token: UUID) {
        lastFrame = nil; pendingFrame = nil
        guard lastWaitingStatus != status else { return }
        lastWaitingStatus = status
        publish(.waiting(status), generation: token)
    }
    private func render(_ buffer: CVPixelBuffer, capturedAt: Date, confirmedAt: Date,
                        fullDisplay: Bool, generation token: UUID) {
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let s = min(1, CGFloat(maxSide) / max(source.extent.width, source.extent.height))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
                waitForFrame("等待完整的屏幕画面", generation: token)
                return
            }
            let image = UIImage(cgImage: cg)
            guard let jpeg = image.jpegData(compressionQuality: 0.72) else {
                waitForFrame("等待完整的屏幕画面", generation: token)
                return
            }
            let duration = confirmedAt.timeIntervalSince(times.first ?? confirmedAt)
            let fps = duration > 0 ? Double(max(0, times.count - 1)) / duration : 0
            let frame = ScreenFrame(image: image, jpeg: jpeg, capturedAt: capturedAt,
                sourceWidth: CVPixelBufferGetWidth(buffer), sourceHeight: CVPixelBufferGetHeight(buffer),
                fullDisplay: fullDisplay, confirmedAt: confirmedAt, captureID: token)
            lastFrame = frame; lastPublishedAt = confirmedAt; lastWaitingStatus = nil
            publish(.frame(frame, fps: fps), generation: token)
        }
    }
}
#endif
