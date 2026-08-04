import Foundation
import AVFoundation
import UIKit

/// Service for camera capture and frame delivery.
/// NOT @MainActor: AVCaptureVideoDataOutputSampleBufferDelegate callbacks
/// arrive on a background queue and must not cross actor isolation.
public final class CameraService: NSObject, ObservableObject, @unchecked Sendable {

    public let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.hardlaw.camera", qos: .userInitiated)

    /// Called on every frame with the captured CGImage.
    public var onFrame: ((CGImage) -> Void)?

    /// Whether the camera is currently running.
    public private(set) var isRunning: Bool = false

    /// Check camera permission and start the session.
    public func start() async {
        // Check authorization
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let authorized: Bool
        switch status {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
        }

        guard authorized else {
            print("[HardlawCamera] Camera access denied")
            return
        }

        // Configure session
        session.beginConfiguration()
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            print("[HardlawCamera] Failed to get camera device")
            session.commitConfiguration()
            return
        }

        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)

        session.commitConfiguration()

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
                continuation.resume()
            }
        }

        isRunning = true
        print("[HardlawCamera] Session started")
    }

    /// Stop the camera session.
    public func stop() {
        session.stopRunning()
        isRunning = false
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Convert CVPixelBuffer to CGImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        onFrame?(cgImage)
    }
}
