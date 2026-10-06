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
    let sourceWidth: Int
    let sourceHeight: Int
    let fullDisplay: Bool
    var width: Int { image.cgImage?.width ?? 0 }
    var height: Int { image.cgImage?.height ?? 0 }
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
    #if canImport(ScreenCaptureKit)
    private var capture: NativeCapture?
    #endif
    func start() {
        guard !running && !waitingForPicker else { return }
        #if canImport(ScreenCaptureKit)
        error = ""; frame = nil; lastBackgroundFrame = nil; waitingForPicker = true; state = "请在系统选择器中共享整屏"
        let token = UUID(); session = token
        let capture = NativeCapture(maxSide: maxSide, onFrame: { [weak self] frame, fps in
            Task { @MainActor in
                guard self?.session == token else { return }
                self?.frame = frame; self?.fps = fps; self?.running = true
                if UIApplication.shared.applicationState == .background { self?.lastBackgroundFrame = frame }
                self?.waitingForPicker = false; self?.state = frame.fullDisplay ? "整屏捕获中" : "仅当前应用，不能执行整屏 Agent"
            }
        }, onState: { [weak self] running, status, error in
            Task { @MainActor in
                guard let self else { return }
                guard self.session == token else { return }
                self.running = running; self.waitingForPicker = false; self.state = status; self.error = error ?? ""
                if !running { self.frame = nil; self.lastBackgroundFrame = nil; self.onStop?() }
            }
        })
        self.capture = capture; capture.present()
        #else
        error = "模拟器不支持此屏幕框架，请使用 iOS 27 真机"
        #endif
    }
    func stop() {
        session = UUID()
        #if canImport(ScreenCaptureKit)
        capture?.stop(); capture = nil
        #endif
        running = false; waitingForPicker = false; frame = nil; lastBackgroundFrame = nil; state = "捕获已停止"; onStop?()
    }
}

#if canImport(ScreenCaptureKit)
// Owned by the main actor; frame processing runs on a serial callback queue.
final class NativeCapture: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    private let onFrame: (ScreenFrame, Double) -> Void
    private let onState: (Bool, String, String?) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maxSide: Int
    private var stream: SCStream?
    private var lastFrameAt = Date.distantPast
    private var times: [Date] = []
    private var fullDisplay = false
    private var stopped = false
    private var generation = UUID()
    private let framesQueue = DispatchQueue(label: "PhoneAgent.capture.frames")
    private let metadataLock = NSLock()
    init(maxSide: Int, onFrame: @escaping (ScreenFrame, Double) -> Void,
         onState: @escaping (Bool, String, String?) -> Void) {
        self.maxSide = max(640, min(2048, maxSide)); self.onFrame = onFrame; self.onState = onState
        super.init()
    }
    func present() {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { onState(false, "系统不允许屏幕捕获", "检查屏幕录制限制"); return }
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
            next.startCapture { [weak self] error in
                guard let self else { return }
                self.metadataLock.lock(); let valid = !self.stopped && self.generation == token; self.metadataLock.unlock()
                guard valid else { return }
                self.onState(error == nil, error == nil ? "捕获已开始" : "捕获启动失败", error?.localizedDescription)
            }
        } catch { onState(false, "捕获启动失败", error.localizedDescription) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        metadataLock.lock(); let empty = self.stream == nil; metadataLock.unlock()
        if empty { onState(false, "已取消屏幕共享", nil) }
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) { onState(false, "共享选择器失败", error.localizedDescription) }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        metadataLock.lock(); let valid = stream === self.stream && !stopped; metadataLock.unlock()
        guard valid else { return }
        onState(false, "系统已停止屏幕共享", error.localizedDescription)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        metadataLock.lock(); let valid = stream === self.stream && !stopped; let isFullDisplay = fullDisplay; metadataLock.unlock()
        guard valid, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = Date()
        times.append(now); times.removeAll { now.timeIntervalSince($0) > 2 }
        guard now.timeIntervalSince(lastFrameAt) >= 0.25 else { return }
        lastFrameAt = now
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let s = min(1, CGFloat(maxSide) / max(source.extent.width, source.extent.height))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return }
            let image = UIImage(cgImage: cg)
            guard let jpeg = image.jpegData(compressionQuality: 0.72) else { return }
            let duration = now.timeIntervalSince(times.first ?? now)
            let fps = duration > 0 ? Double(max(0, times.count - 1)) / duration : 0
            onFrame(ScreenFrame(image: image, jpeg: jpeg, capturedAt: now,
                sourceWidth: CVPixelBufferGetWidth(buffer), sourceHeight: CVPixelBufferGetHeight(buffer),
                fullDisplay: isFullDisplay), fps)
        }
    }
}
#endif
