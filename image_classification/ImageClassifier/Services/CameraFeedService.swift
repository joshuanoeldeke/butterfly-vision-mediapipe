// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import AVFoundation

// MARK: CameraFeedServiceDelegate Declaration
protocol CameraFeedServiceDelegate: AnyObject {

  /**
   This method delivers the pixel buffer of the current frame seen by the device's camera.
   */
  func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation)

  /**
   This method initimates that a session runtime error occured.
   */
  func didEncounterSessionRuntimeError()

  /**
   This method initimates that the session was interrupted.
   */
  func sessionWasInterrupted(canResumeManually resumeManually: Bool)

  /**
   This method initimates that the session interruption has ended.
   */
  func sessionInterruptionEnded()

  /**
   Notifies delegate that the camera input/device changed.
   */
  func cameraInputDidChange(to device: AVCaptureDevice)

}

/**
 This class manages all camera related functionality
 */
class CameraFeedService: NSObject {
  /**
   This enum holds the state of the camera initialization.
   */
  enum CameraConfigurationStatus {
    case success
    case failed
    case permissionDenied
  }

  // MARK: Public Instance Variables
  var videoResolution: CGSize {
    get {
      guard let size = imageBufferSize else {
        return CGSize.zero
      }
      let minDimension = min(size.width, size.height)
      let maxDimension = max(size.width, size.height)
      switch UIDevice.current.orientation {
        case .portrait:
          return CGSize(width: minDimension, height: maxDimension)
        case .landscapeLeft:
          fallthrough
        case .landscapeRight:
          return CGSize(width: maxDimension, height: minDimension)
        default:
          return CGSize(width: minDimension, height: maxDimension)
      }
    }
  }

  let videoGravity = AVLayerVideoGravity.resizeAspectFill

  // MARK: Instance Variables
  private let session: AVCaptureSession = AVCaptureSession()
  private lazy var videoPreviewLayer = AVCaptureVideoPreviewLayer(session: session)
  private let sessionQueue = DispatchQueue(label: "com.google.mediapipe.CameraFeedService.sessionQueue")
  private var cameraPosition: AVCaptureDevice.Position = .back
  // Keep reference to current device input so we can switch cameras later.
  private var currentVideoDeviceInput: AVCaptureDeviceInput?
  /// The currently active AVCaptureDevice for the session (if known).
  var currentDevice: AVCaptureDevice? {
    return currentVideoDeviceInput?.device
  }

  private var cameraConfigurationStatus: CameraConfigurationStatus = .failed
  private lazy var videoDataOutput = AVCaptureVideoDataOutput()
  private var isSessionRunning = false
  private var imageBufferSize: CGSize?


  // MARK: CameraFeedServiceDelegate
  weak var delegate: CameraFeedServiceDelegate?

  // MARK: Initializer
  init(previewView: UIView) {
    super.init()

    // Initializes the session
    session.sessionPreset = .high
    setUpPreviewView(previewView)

    attemptToConfigureSession()
    NotificationCenter.default.addObserver(
      self, selector: #selector(orientationChanged),
      name: UIDevice.orientationDidChangeNotification,
      object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func setUpPreviewView(_ view: UIView) {
    videoPreviewLayer.videoGravity = videoGravity
    videoPreviewLayer.connection?.videoOrientation = .portrait
    view.layer.addSublayer(videoPreviewLayer)
  }

  // MARK: notification methods
  @objc func orientationChanged(notification: Notification) {
    switch UIImage.Orientation.from(deviceOrientation: UIDevice.current.orientation) {
    case .up:
      videoPreviewLayer.connection?.videoOrientation = .portrait
    case .left:
      videoPreviewLayer.connection?.videoOrientation = .landscapeRight
    case .right:
      videoPreviewLayer.connection?.videoOrientation = .landscapeLeft
    default:
      break
    }
  }

  // MARK: Session Start and End methods

  /**
   This method starts an AVCaptureSession based on whether the camera configuration was successful.
   */

  func startLiveCameraSession(_ completion: @escaping(_ cameraConfiguration: CameraConfigurationStatus) -> Void) {
    sessionQueue.async {
      switch self.cameraConfigurationStatus {
      case .success:
        self.addObservers()
        self.startSession()
        default:
          break
      }
      completion(self.cameraConfigurationStatus)
    }
  }

  /**
   This method stops a running an AVCaptureSession.
   */
  func stopSession() {
    self.removeObservers()
    sessionQueue.async {
      if self.session.isRunning {
        self.session.stopRunning()
        self.isSessionRunning = self.session.isRunning
      }
    }

  }

  /**
   This method resumes an interrupted AVCaptureSession.
   */
  func resumeInterruptedSession(withCompletion completion: @escaping (Bool) -> ()) {
    sessionQueue.async {
      self.startSession()

      DispatchQueue.main.async {
        completion(self.isSessionRunning)
      }
    }
  }

  func updateVideoPreviewLayer(toFrame frame: CGRect) {
    videoPreviewLayer.frame = frame
  }

  /**
   This method starts the AVCaptureSession
   **/
  private func startSession() {
    self.session.startRunning()
    self.isSessionRunning = self.session.isRunning
  }

  // MARK: Session Configuration Methods.
  /**
   This method requests for camera permissions and handles the configuration of the session and stores the result of configuration.
   */
  private func attemptToConfigureSession() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      self.cameraConfigurationStatus = .success
    case .notDetermined:
      self.sessionQueue.suspend()
      self.requestCameraAccess(completion: { (granted) in
        self.sessionQueue.resume()
      })
    case .denied:
      self.cameraConfigurationStatus = .permissionDenied
    default:
      break
    }

    self.sessionQueue.async {
      self.configureSession()
    }
  }

  /**
   This method requests for camera permissions.
   */
  private func requestCameraAccess(completion: @escaping (Bool) -> ()) {
    AVCaptureDevice.requestAccess(for: .video) { (granted) in
      if !granted {
        self.cameraConfigurationStatus = .permissionDenied
      }
      else {
        self.cameraConfigurationStatus = .success
      }
      completion(granted)
    }
  }


  /**
   This method handles all the steps to configure an AVCaptureSession.
   */
  private func configureSession() {

    guard cameraConfigurationStatus == .success else {
      return
    }
    session.beginConfiguration()

    // Tries to add an AVCaptureDeviceInput.
    guard addVideoDeviceInput() == true else {
      self.session.commitConfiguration()
      self.cameraConfigurationStatus = .failed
      return
    }

    // Tries to add an AVCaptureVideoDataOutput.
    guard addVideoDataOutput() else {
      self.session.commitConfiguration()
      self.cameraConfigurationStatus = .failed
      return
    }

    session.commitConfiguration()
    self.cameraConfigurationStatus = .success
  }

  /**
   This method tries to an AVCaptureDeviceInput to the current AVCaptureSession.
   */
  private func addVideoDeviceInput() -> Bool {
    // Try to get a camera that matches the requested position. Prefer wide-angle if available.
    guard let camera = selectDevice(for: cameraPosition) else {
      return false
    }

    do {
      let videoDeviceInput = try AVCaptureDeviceInput(device: camera)
      // Remove existing input if present (shouldn't happen during initial config but safe to handle).
      if let existing = currentVideoDeviceInput {
        session.removeInput(existing)
        currentVideoDeviceInput = nil
      }

      if session.canAddInput(videoDeviceInput) {
        session.addInput(videoDeviceInput)
        currentVideoDeviceInput = videoDeviceInput
        return true
      } else {
        return false
      }
    } catch {
      fatalError("Cannot create video device input: \(error)")
    }
  }

  // MARK: - Device selection & switching
  /// Returns the first matching device for a position, preferring wide angle, then ultraWide, then telephoto.
  private func selectDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
    // Prefer types in this order for back cameras, and wide angle for front.
    let deviceTypesOrder: [AVCaptureDevice.DeviceType] = position == .front ? [.builtInWideAngleCamera] : [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInTripleCamera]

    let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypesOrder, mediaType: .video, position: position)
    // Return the first device from discovery session; DiscoverySession already filters by deviceTypes order.
    return discoverySession.devices.first ?? AVCaptureDevice.default(for: .video)
  }

  /// Returns a list of available video devices grouped by position and type.
  func availableVideoDevices() -> [AVCaptureDevice] {
    var results: [AVCaptureDevice] = []
    let allDeviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera, .builtInDualCamera, .builtInTripleCamera]
    let positions: [AVCaptureDevice.Position] = [.back, .front]
    var seenKeys = Set<String>()
    for position in positions {
      let ds = AVCaptureDevice.DiscoverySession(deviceTypes: allDeviceTypes, mediaType: .video, position: position)
      for device in ds.devices {
        // Use deviceType + position to dedupe entries like Dual/Triple when a more specific type exists.
        let key = "\(device.deviceType.rawValue)-\(device.position.rawValue)"
        if seenKeys.contains(key) { continue }
        seenKeys.insert(key)
        results.append(device)
      }
    }
    return results
  }

  /// Returns a list of lens options (device, nominalZoom) where nominalZoom is relative to the default wide lens (1.0).
  /// We try to compute nominal zoom using `activeFormat.videoFieldOfView` when available; otherwise fall back to a mapping by deviceType.
  func availableLensOptions() -> [(device: AVCaptureDevice, nominalZoom: CGFloat)] {
    var results: [(AVCaptureDevice, CGFloat)] = []
    let devices = availableVideoDevices()
    // Determine a reference FOV (prefer wide angle on the back if present)
    var referenceFOV: CGFloat? = nil
    if let ref = devices.first(where: { $0.deviceType == .builtInWideAngleCamera && $0.position == .back }) {
      referenceFOV = CGFloat(ref.activeFormat.videoFieldOfView)
    }
    // fallback to any wide-angle device
    if referenceFOV == nil, let ref = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
      referenceFOV = CGFloat(ref.activeFormat.videoFieldOfView)
    }

    for device in devices {
      var zoom: CGFloat = 1.0
      let fov: Float = device.activeFormat.videoFieldOfView
      if fov > 0, let refF = referenceFOV {
        // smaller FOV => more zoom, so nominalZoom = refFOV / fov
        zoom = refF / CGFloat(fov)
      } else {
        // fallback mapping by type
        switch device.deviceType {
        case .builtInUltraWideCamera:
          zoom = 0.5
        case .builtInTelephotoCamera:
          zoom = 3.0
        default:
          zoom = 1.0
        }
      }
      results.append((device, zoom))
    }
    // Sort by nominal zoom ascending
    results.sort(by: { (a: (AVCaptureDevice, CGFloat), b: (AVCaptureDevice, CGFloat)) -> Bool in
      return a.1 < b.1
    })
    return results
  }

  /// Finds the best device whose nominalZoom is closest to the requestedZoom.
  func deviceForRequestedZoom(_ requestedZoom: CGFloat, position: AVCaptureDevice.Position? = nil) -> AVCaptureDevice? {
    let options = availableLensOptions()
    let filtered = options.filter { position == nil ? true : $0.device.position == position }
    guard !filtered.isEmpty else { return nil }
    let best = filtered.min(by: { abs($0.nominalZoom - requestedZoom) < abs($1.nominalZoom - requestedZoom) })
    return best?.device
  }

  // MARK: Zoom control helpers
  /// Returns the current device videoZoomFactor (1.0 default)
  func currentZoomFactor() -> CGFloat {
    guard let device = currentDevice else { return 1.0 }
    return CGFloat(device.videoZoomFactor)
  }

  /// Returns the supported zoom range for the current device (min, max)
  func supportedZoomRange() -> (min: CGFloat, max: CGFloat)? {
    guard let device = currentDevice else { return nil }
    return (min: CGFloat(device.minAvailableVideoZoomFactor), max: CGFloat(device.maxAvailableVideoZoomFactor))
  }

  /// Set the device zoom factor (clamped to supported range). Completion on main queue.
  func setZoomFactor(_ factor: CGFloat, completion: @escaping (Bool) -> Void) {
    sessionQueue.async {
      guard let device = self.currentDevice else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      do {
        try device.lockForConfiguration()
  let clamped = max(CGFloat(device.minAvailableVideoZoomFactor), min(factor, CGFloat(device.maxAvailableVideoZoomFactor)))
  device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        DispatchQueue.main.async { completion(true) }
      } catch {
        print("[CameraFeedService] failed to set zoom: \(error)")
        DispatchQueue.main.async { completion(false) }
      }
    }
  }

  /// Switches camera to the provided device (if available). Completion is called on main queue with success flag.
  func switchCamera(to device: AVCaptureDevice, completion: @escaping (Bool) -> Void) {
    sessionQueue.async {
      guard self.session.isRunning || !self.session.isRunning else {
        // not expected, but bail
        DispatchQueue.main.async { completion(false) }
        return
      }

      self.session.beginConfiguration()
      // Remove current input
      if let currentInput = self.currentVideoDeviceInput {
        self.session.removeInput(currentInput)
        self.currentVideoDeviceInput = nil
      }

      do {
        let newInput = try AVCaptureDeviceInput(device: device)
        if self.session.canAddInput(newInput) {
          self.session.addInput(newInput)
          self.currentVideoDeviceInput = newInput
          self.cameraPosition = device.position
        } else {
          // revert if can't add
          if let prev = self.currentVideoDeviceInput {
            self.session.addInput(prev)
          }
          self.session.commitConfiguration()
          DispatchQueue.main.async { completion(false) }
          return
        }
      } catch {
        print("Error switching camera: \(error)")
        self.session.commitConfiguration()
        DispatchQueue.main.async { completion(false) }
        return
      }

      // Update mirroring if front camera
      if let connection = self.videoDataOutput.connection(with: .video) {
        connection.isVideoMirrored = (self.cameraPosition == .front)
      }

      self.session.commitConfiguration()
      // Notify delegate that the input changed
      if let device = self.currentDevice {
        DispatchQueue.main.async {
          self.delegate?.cameraInputDidChange(to: device)
          completion(true)
        }
      } else {
        DispatchQueue.main.async { completion(true) }
      }
    }
  }

  /**
   This method tries to an AVCaptureVideoDataOutput to the current AVCaptureSession.
   */
  private func addVideoDataOutput() -> Bool {

    let sampleBufferQueue = DispatchQueue(label: "sampleBufferQueue")
    videoDataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)
    videoDataOutput.alwaysDiscardsLateVideoFrames = true
    videoDataOutput.videoSettings = [ String(kCVPixelBufferPixelFormatTypeKey) : kCMPixelFormat_32BGRA]

    if session.canAddOutput(videoDataOutput) {
      session.addOutput(videoDataOutput)
      videoDataOutput.connection(with: .video)?.videoOrientation = .portrait
      if videoDataOutput.connection(with: .video)?.isVideoOrientationSupported == true
          && cameraPosition == .front {
        videoDataOutput.connection(with: .video)?.isVideoMirrored = true
      }
      return true
    }
    return false
  }

  // MARK: Notification Observer Handling
  private func addObservers() {
    NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedService.sessionRuntimeErrorOccured(notification:)), name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
    NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedService.sessionWasInterrupted(notification:)), name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
    NotificationCenter.default.addObserver(self, selector: #selector(CameraFeedService.sessionInterruptionEnded), name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
  }

  private func removeObservers() {
    NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionRuntimeError, object: session)
    NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionWasInterrupted, object: session)
    NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVCaptureSessionInterruptionEnded, object: session)
  }

  // MARK: Notification Observers
  @objc func sessionWasInterrupted(notification: Notification) {

    if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
       let reasonIntegerValue = userInfoValue.integerValue,
       let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
      print("Capture session was interrupted with reason \(reason)")

      var canResumeManually = false
      if reason == .videoDeviceInUseByAnotherClient {
        canResumeManually = true
      } else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
        canResumeManually = false
      }

      self.delegate?.sessionWasInterrupted(canResumeManually: canResumeManually)

    }
  }

  @objc func sessionInterruptionEnded(notification: Notification) {
    self.delegate?.sessionInterruptionEnded()
  }

  @objc func sessionRuntimeErrorOccured(notification: Notification) {
    guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else {
      return
    }

    print("Capture session runtime error: \(error)")

    guard error.code == .mediaServicesWereReset else {
      self.delegate?.didEncounterSessionRuntimeError()
      return
    }

    sessionQueue.async {
      if self.isSessionRunning {
        self.startSession()
      } else {
        DispatchQueue.main.async {
          self.delegate?.didEncounterSessionRuntimeError()
        }
      }
    }
  }
}

/**
 AVCaptureVideoDataOutputSampleBufferDelegate
 */
extension CameraFeedService: AVCaptureVideoDataOutputSampleBufferDelegate {

  /** This method delegates the CVPixelBuffer of the frame seen by the camera currently.
   */
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
      let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)!
      if (imageBufferSize == nil) {
        imageBufferSize = CGSize(width: CVPixelBufferGetHeight(imageBuffer), height: CVPixelBufferGetWidth(imageBuffer))
      }
    // Log which device is currently active for capture (helps confirm ML feed device)
    if let deviceName = currentDevice?.localizedName {
      print("[CameraFeedService] captureOutput using device: \(deviceName)")
    } else {
      print("[CameraFeedService] captureOutput using unknown device")
    }

    delegate?.didOutput(sampleBuffer: sampleBuffer, orientation: UIImage.Orientation.from(deviceOrientation: UIDevice.current.orientation))
  }
}

// MARK: UIImage.Orientation Extension
extension UIImage.Orientation {
  static func from(deviceOrientation: UIDeviceOrientation) -> UIImage.Orientation {
    switch deviceOrientation {
      case .portrait:
        return .up
      case .landscapeLeft:
        return .left
      case .landscapeRight:
        return .right
      default:
        return .up
    }
  }
}
