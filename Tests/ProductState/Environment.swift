// Offline environment for the production AgentEngine. No phone, model or BLE calls.
import Foundation
import CoreGraphics

struct UIImage {
    let cgImage: CGImage? = {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }()
}
struct ScreenFrame {
    let image = UIImage(), jpeg = Data()
    let capturedAt = Date(), fullDisplay = true
    var confirmedAt: Date { capturedAt }
    let captureID: UUID? = nil
    let width = 2, height = 2, sourceWidth = 2, sourceHeight = 2
}
@MainActor final class CaptureService {
    var running = true
    var frame: ScreenFrame? { running ? ScreenFrame() : nil }
}
@MainActor final class OfflineBLE {
    var ready = true, keyboardReady = true
    var selectedID: String? = "offline-device"
    var releases = 0
    func release() async { releases += 1; try? await Task.sleep(nanoseconds: 20_000_000) }
}
@MainActor final class MouseExecutor {
    let ble = OfflineBLE()
    var actions: [AgentAction.Kind] = []
    var actionDelay: UInt64 = 0
    func invalidatePosition() {}
    func validateCalibration(frame: ScreenFrame?) throws { if !ble.ready { throw AgentError.message("offline disconnect") } }
    func execute(_ action: AgentAction, frame: ScreenFrame, mappedHomeAvailable: Bool) async throws {
        actions.append(action.kind)
        if actionDelay > 0 { try await Task.sleep(nanoseconds: actionDelay) }
    }
}
enum SettingsStore { static func apiKey(for endpoint: String? = nil) -> String { "offline-placeholder" } }
enum ModelEndpointPolicy { static func url(_ endpoint: String) throws -> URL { URL(string: endpoint)! } }
@MainActor enum ModelProbe {
    static var calls = 0
    static var goals: [String] = []
    static var delay: UInt64 = 0
    static var action = AgentAction(kind: .finish, reason: "offline result")
}
@MainActor struct VisionClient {
    let settings: AgentSettings, apiKey: String
    func nextAction(task: String, jpeg: Data, width: Int, height: Int, history: [AgentLogEntry],
                    keyboardAvailable: Bool, mappedHomeAvailable: Bool,
                    tokenLimit: Int? = nil, formatRetry: Bool = false, memoryContext: String = "") async throws -> AgentAction {
        ModelProbe.calls += 1
        ModelProbe.goals.append(task)
        if ModelProbe.delay > 0 { try await Task.sleep(nanoseconds: ModelProbe.delay) }
        return ModelProbe.action
    }
}
