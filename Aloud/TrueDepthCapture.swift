import AVFoundation
import CoreVideo
import CoreImage
import os

final class TrueDepthCapture: NSObject, AVCaptureDepthDataOutputDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    static var isSupported: Bool {
        AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) != nil
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.vhalasi.aloud.truedepth")
    private let output = AVCaptureDepthDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext()
    private var videoHandler: ((Data) -> Void)?
    private var lastVideoFrame: TimeInterval = 0
    private let logger = Logger(subsystem: "com.vhalasi.aloud", category: "TrueDepth")
    private var configured = false
    private var active = false
    private var lastFrame: TimeInterval = 0
    private var reportedFormat = false
    private var measurement: ((Float?) -> Void)?
    private var failure: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    guard self.active else { return }
                    self.active = false
                    self.session.stopRunning()
                    self.failure?("TrueDepth camera interrupted. Tap Start to try again.")
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Callbacks run on the capture queue. The caller owns dispatch to the UI.
    func start(measurement: @escaping (Float?) -> Void,
               ready: @escaping () -> Void,
               failure: @escaping (String) -> Void) {
        queue.async {
            self.measurement = measurement
            self.failure = failure
            self.lastFrame = 0
            self.reportedFormat = false
            do {
                if !self.configured { try self.configure() }
                self.active = true
                self.session.startRunning()
                guard self.session.isRunning else {
                    self.active = false
                    failure("TrueDepth could not start. Close other camera apps and try again.")
                    return
                }
                ready()
            } catch {
                self.active = false
                failure("TrueDepth setup failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async {
            self.active = false
            self.session.stopRunning()
            self.measurement = nil
            self.failure = nil
        }
    }

    /// RGB comes from the same front-camera session as depth, avoiding camera contention.
    func setVideoHandler(_ handler: ((Data) -> Void)?) {
        queue.async { self.videoHandler = handler; self.lastVideoFrame = 0 }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active, let videoHandler else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVideoFrame >= 1,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastVideoFrame = now
        let image = CIImage(cvPixelBuffer: buffer)
        guard let jpeg = imageContext.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]) else { return }
        videoHandler(jpeg)
    }

    private func configure() throws {
        guard let camera = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            throw CaptureError.unsupported
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Camera-only capture must not take over the audio session or suppress haptics.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.unsupported }
        session.addInput(input)
        session.addOutput(output)
        session.sessionPreset = .vga640x480
        guard session.canAddOutput(videoOutput) else { throw CaptureError.unsupported }
        session.addOutput(videoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        output.isFilteringEnabled = false
        output.alwaysDiscardsLateDepthData = true
        output.setDelegate(self, callbackQueue: queue)
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        let formats = camera.activeFormat.supportedDepthDataFormats.filter {
            let type = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return type == kCVPixelFormatType_DepthFloat32 || type == kCVPixelFormatType_DepthFloat16
        }
        guard let format = formats.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else { throw CaptureError.unsupported }
        camera.activeDepthDataFormat = format
        configured = true
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        guard active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 0.1 else { return }
        lastFrame = now
        if !reportedFormat {
            logger.info("TrueDepth frames received; accuracy=\(depthData.depthDataAccuracy.rawValue), quality=\(depthData.depthDataQuality.rawValue)")
            reportedFormat = true
        }
        // Never treat a relative/disparity-only estimate as a measured distance.
        guard depthData.depthDataAccuracy == .absolute else {
            measurement?(nil)
            return
        }
        let map = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32).depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else {
            measurement?(nil)
            return
        }
        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        let halfSide = min(width, height) / 6
        var samples: [Float] = []
        var count = 0
        for y in stride(from: height / 2 - halfSide, to: height / 2 + halfSide, by: 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in stride(from: width / 2 - halfSide, to: width / 2 + halfSide, by: 2) {
                count += 1
                samples.append(row[x])
            }
        }
        measurement?(DepthEstimate.metres(samples: samples, totalCount: count))
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didDrop depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection,
                         reason: AVCaptureOutput.DataDroppedReason) {
        if active { measurement?(nil) }
    }

    private enum CaptureError: LocalizedError {
        case unsupported
        var errorDescription: String? { "No supported TrueDepth capture format is available." }
    }
}
