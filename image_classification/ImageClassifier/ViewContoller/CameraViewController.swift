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

import AVFoundation
import MediaPipeTasksVision
import UIKit

/**
 * The view controller is responsible for performing classification on incoming frames from the live camera and presenting the frames with the
 * class of the classified objects to the user.
 */
class CameraViewController: UIViewController {
  private struct Constants {
    static let edgeOffset: CGFloat = 2.0
  }
  
  weak var inferenceResultDeliveryDelegate: InferenceResultDeliveryDelegate?
  weak var interfaceUpdatesDelegate: InterfaceUpdatesDelegate?
  
  @IBOutlet weak var previewView: UIView!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!
  @IBOutlet weak var resumeButton: UIButton!
  // Camera switch button (created programmatically)
  private var switchCameraButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setTitle("Front", for: .normal)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
    btn.setTitleColor(.white, for: .normal)
    btn.layer.cornerRadius = 20
    btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    return btn
  }()

  // Zoom style buttons (like the camera app) - simple representation
  private var zoomStackView: UIStackView = {
    let sv = UIStackView()
    sv.axis = .horizontal
    sv.alignment = .center
    sv.distribution = .equalSpacing
    sv.spacing = 8
    sv.translatesAutoresizingMaskIntoConstraints = false
    return sv
  }()

  // Debug overlay to show which camera is used by preview and ML
  private let debugOverlay: UILabel = {
    let l = UILabel()
    l.translatesAutoresizingMaskIntoConstraints = false
    l.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
    l.textColor = .white
    l.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    l.numberOfLines = 0
    l.layer.cornerRadius = 6
    l.clipsToBounds = true
    l.text = "Preview: --\nML: --"
    return l
  }()
  // Selected indicator view for zoom buttons
  private let zoomSelectionIndicator: UIView = {
    let v = UIView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.backgroundColor = UIColor.systemBlue
    v.layer.cornerRadius = 2
    v.alpha = 0.0
    return v
  }()
  
  private var isSessionRunning = false
  private var isObserving = false
  private let backgroundQueue = DispatchQueue(label: "com.google.mediapipe.cameraController.backgroundQueue")
  
  // MARK: Controllers that manage functionality
  // Handles all the camera related functionality
  private lazy var cameraFeedService = CameraFeedService(previewView: previewView)
  
  private let imageClassifierServiceQueue = DispatchQueue(
    label: "com.google.mediapipe.cameraController.imageClassifierServiceQueue",
    attributes: .concurrent)
  
  // Queuing reads and writes to imageClassifierService using the Apple recommended way
  // as they can be read and written from multiple threads and can result in race conditions.
  private var _imageClassifierService: ImageClassifierService?
  private var imageClassifierService: ImageClassifierService? {
    get {
      imageClassifierServiceQueue.sync {
        return self._imageClassifierService
      }
    }
    set {
      imageClassifierServiceQueue.async(flags: .barrier) {
        self._imageClassifierService = newValue
      }
    }
  }

#if !targetEnvironment(simulator)
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    initializeImageClassifierServiceOnSessionResumption()
    cameraFeedService.startLiveCameraSession {[weak self] cameraConfiguration in
      DispatchQueue.main.async {
        switch cameraConfiguration {
          case .failed:
            self?.presentVideoConfigurationErrorAlert()
          case .permissionDenied:
            self?.presentCameraPermissionsDeniedAlert()
          default:
            break
        }
      }        
    }
  }
  
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cameraFeedService.stopSession()
    clearImageClassifierServiceOnSessionInterruption()
  }
  
  override func viewDidLoad() {
    super.viewDidLoad()
    cameraFeedService.delegate = self
    // Do any additional setup after loading the view.
    // Add camera front/back toggle button
    previewView.addSubview(switchCameraButton)
    NSLayoutConstraint.activate([
      switchCameraButton.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 18),
      switchCameraButton.trailingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: -18),
      switchCameraButton.widthAnchor.constraint(equalToConstant: 80),
      switchCameraButton.heightAnchor.constraint(equalToConstant: 40)
    ])
    switchCameraButton.addTarget(self, action: #selector(onTapToggleFrontBack), for: .touchUpInside)

    // Add zoom style buttons; layout will be updated when bottom sheet state is known
    previewView.addSubview(zoomStackView)
    NSLayoutConstraint.activate([
      zoomStackView.centerXAnchor.constraint(equalTo: previewView.centerXAnchor)
    ])
    buildZoomButtons()

  // Add selection indicator under zoom stack
  previewView.addSubview(zoomSelectionIndicator)

  // Add pinch gesture for smooth zooming
  let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
  previewView.addGestureRecognizer(pinch)

    // Listen for bottom sheet open/close to reposition zoom controls
    NotificationCenter.default.addObserver(self, selector: #selector(bottomSheetStateChanged(_:)), name: .bottomSheetStateChanged, object: nil)

    // Add debug overlay
    previewView.addSubview(debugOverlay)
    NSLayoutConstraint.activate([
      debugOverlay.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 12),
      debugOverlay.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 12),
      debugOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
    ])

    // initialize debug overlay text
    refreshDebugOverlay()
  }
  
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
  }
  
  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    cameraFeedService.updateVideoPreviewLayer(toFrame: previewView.bounds)
    // Ensure zoomStack stays above the bottom sheet by defaulting to safe area bottom offset
    positionZoomStack(aboveBottomInset: view.safeAreaInsets.bottom)
    // update selection indicator alpha position if needed
    updateZoomSelectionIndicator()
  }
#endif
  
  // Resume camera session when click button resume
  @IBAction func onClickResume(_ sender: Any) {
    cameraFeedService.resumeInterruptedSession {[weak self] isSessionRunning in
      if isSessionRunning {
        self?.resumeButton.isHidden = true
        self?.cameraUnavailableLabel.isHidden = true
        self?.initializeImageClassifierServiceOnSessionResumption()
      }
    }
  }

  @objc private func onTapToggleFrontBack() {
    // Toggle between front and back by selecting a device with the opposite position.
    // Prefer wide-angle / best available.
    let wantPosition: AVCaptureDevice.Position = (cameraFeedService.currentDevice?.position == .front) ? .back : .front
    // Find first device for that position
    let devices = cameraFeedService.availableVideoDevices().filter { $0.position == wantPosition }
    guard let device = devices.first else { return }
    cameraFeedService.switchCamera(to: device) { [weak self] success in
      if success {
        DispatchQueue.main.async {
          // update toggle title
          self?.switchCameraButton.setTitle((wantPosition == .front) ? "Front" : "Back", for: .normal)
          self?.refreshDebugOverlay()
          // Reinitialize classifier to ensure ML uses the new feed
          self?.clearAndInitializeImageClassifierService()
        }
      }
    }
  }

  @objc private func onTapZoomButton(_ sender: UIButton) {
    guard let title = sender.title(for: .normal), let requestedZoom = Double(title.replacingOccurrences(of: "x", with: "")) else { return }
    // Look up a device close to the requested zoom for the current position
    let pos = cameraFeedService.currentDevice?.position ?? .back
    if let targetDevice = cameraFeedService.deviceForRequestedZoom(CGFloat(requestedZoom), position: pos) {
      cameraFeedService.switchCamera(to: targetDevice) { [weak self] success in
        if success {
          DispatchQueue.main.async {
            self?.refreshDebugOverlay()
            self?.clearAndInitializeImageClassifierService()
          }
        }
      }
    }
  }

  @objc private func bottomSheetStateChanged(_ notification: Notification) {
    let user = notification.userInfo ?? [:]
    let isOpen = (user["isOpen"] as? Bool) ?? false
    let bottomHeight = (user["bottomHeight"] as? CGFloat) ?? 0.0
    // Place zoom controls just above the bottom sheet if it's open, otherwise above safe area bottom
    if isOpen {
      positionZoomStack(aboveBottomInset: bottomHeight)
    } else {
      positionZoomStack(aboveBottomInset: view.safeAreaInsets.bottom)
    }
  }

  /// Position the zoom stack centered horizontally and `aboveBottomInset` above the bottom of previewView.
  private func positionZoomStack(aboveBottomInset: CGFloat) {
    // Remove any bottom constraint then add a new one
    for c in previewView.constraints where c.firstItem as? UIStackView == zoomStackView || c.secondItem as? UIStackView == zoomStackView {
      previewView.removeConstraint(c)
    }
    zoomStackView.translatesAutoresizingMaskIntoConstraints = false
    let bottomConstant: CGFloat = -(aboveBottomInset + 20)
    NSLayoutConstraint.activate([
      zoomStackView.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
      zoomStackView.bottomAnchor.constraint(equalTo: previewView.bottomAnchor, constant: bottomConstant)
    ])
  }

  /// Rebuild the zoom buttons based on available lens options from the device.
  private func buildZoomButtons() {
    // Remove existing
    for v in zoomStackView.arrangedSubviews { zoomStackView.removeArrangedSubview(v); v.removeFromSuperview() }
    let options = cameraFeedService.availableLensOptions()
    // If no options, provide a default 1x
    if options.isEmpty {
      let b = makeZoomButton(title: "1x")
      zoomStackView.addArrangedSubview(b)
      return
    }
    // Build buttons using nominalZoom rounded to single-digit (e.g., 0.5x, 1x, 3x)
    // We'll construct segmented-style buttons for each lens option.
    for (index, opt) in options.enumerated() {
      let zoomVal = round(opt.nominalZoom * 10) / 10.0
      let title = String(format: "%g", zoomVal) + "x"
      let b = makeZoomButton(title: title)
      b.tag = index
      zoomStackView.addArrangedSubview(b)
    }
    // After building, update visual selection to match current zoom
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.animateSelectionToClosestZoom()
    }
  }

  private func makeZoomButton(title: String) -> UIButton {
    let b = UIButton(type: .system)
    b.setTitle(title, for: .normal)
    b.setTitleColor(.white, for: .normal)
    b.backgroundColor = UIColor(white: 0.0, alpha: 0.35)
    b.layer.cornerRadius = 18
    b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    b.addTarget(self, action: #selector(onTapZoomButton(_:)), for: .touchUpInside)
    return b
  }

  private func updateZoomSelectionIndicator() {
    // Place the indicator under the selected zoom button if visible
    guard let first = zoomStackView.arrangedSubviews.first else { zoomSelectionIndicator.alpha = 0.0; return }
    // Find approximate selected based on current zoom factor
    let currentZoom = cameraFeedService.currentZoomFactor()
    // Find button whose title matches closest nominal zoom
    var closestButton: UIView? = nil
    var closestDelta: CGFloat = .greatestFiniteMagnitude
    for v in zoomStackView.arrangedSubviews {
      if let btn = v as? UIButton, let title = btn.title(for: .normal) {
        let valStr = title.replacingOccurrences(of: "x", with: "")
        if let val = Double(valStr) {
          let delta = abs(CGFloat(val) - currentZoom)
          if delta < closestDelta {
            closestDelta = delta
            closestButton = btn
          }
        }
      }
    }
    guard let sel = closestButton else { zoomSelectionIndicator.alpha = 0.0; return }
    // animate indicator under sel
    let targetFrame = CGRect(x: sel.frame.midX - 18, y: sel.frame.maxY + 8, width: 36, height: 4)
    UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseOut, animations: {
      self.zoomSelectionIndicator.alpha = 0.95
      self.zoomSelectionIndicator.frame = targetFrame
    }, completion: nil)
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    guard let range = cameraFeedService.supportedZoomRange() else { return }
    let current = cameraFeedService.currentZoomFactor()
    let newZoom = current * gesture.scale
    if gesture.state == .changed {
      // live adjust
      cameraFeedService.setZoomFactor(newZoom) { [weak self] _ in
        DispatchQueue.main.async { self?.updateZoomSelectionIndicator() }
      }
      gesture.scale = 1.0
    } else if gesture.state == .ended {
      // On end, decide whether to automatically switch lenses based on threshold
      let finalZoom = max(range.min, min(newZoom, range.max))
      // If the final requested zoom is closer to another lens's nominal zoom by > 0.3x, switch lens
      if let targetDevice = cameraFeedService.deviceForRequestedZoom(finalZoom, position: cameraFeedService.currentDevice?.position) {
        if targetDevice.uniqueID != cameraFeedService.currentDevice?.uniqueID {
          // switch camera to the target device
          cameraFeedService.switchCamera(to: targetDevice) { [weak self] success in
            if success {
              // set the zoom factor on new device to the requested value (clamped)
              self?.cameraFeedService.setZoomFactor(finalZoom) { _ in
                DispatchQueue.main.async { self?.animateSelectionToClosestZoom() }
              }
            }
          }
        } else {
          // same device, just ensure zoom is set
          cameraFeedService.setZoomFactor(finalZoom) { [weak self] _ in
            DispatchQueue.main.async { self?.animateSelectionToClosestZoom() }
          }
        }
      }
      gesture.scale = 1.0
    }
  }

  private func animateSelectionToClosestZoom() {
    // animate the indicator to the button closest to current zoom
    UIView.animate(withDuration: 0.12) { [weak self] in
      self?.updateZoomSelectionIndicator()
    }
  }

  private func refreshDebugOverlay() {
    let previewName = cameraFeedService.currentDevice?.localizedName ?? "--"
    // We'll assume ML feed is same as currentDevice in CameraFeedService; show it explicitly
    let mlName = cameraFeedService.currentDevice?.localizedName ?? "--"
    debugOverlay.text = "Preview: \(previewName)\nML: \(mlName)"
  }
  
  private func presentCameraPermissionsDeniedAlert() {
    let alertController = UIAlertController(
      title: "Camera Permissions Denied",
      message:
        "Camera permissions have been denied for this app. You can change this by going to Settings",
      preferredStyle: .alert)
    
    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
      UIApplication.shared.open(
        URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
    alertController.addAction(cancelAction)
    alertController.addAction(settingsAction)
    
    present(alertController, animated: true, completion: nil)
  }
  
  private func presentVideoConfigurationErrorAlert() {
    let alert = UIAlertController(
      title: "Camera Configuration Failed",
      message: "There was an error while configuring camera.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
    
    self.present(alert, animated: true)
  }
  
  private func initializeImageClassifierServiceOnSessionResumption() {
    clearAndInitializeImageClassifierService()
    startObserveConfigChanges()
  }
  
  @objc private func clearAndInitializeImageClassifierService() {
    imageClassifierService = nil
    imageClassifierService = ImageClassifierService
        .liveStreamClassifierService(
          model: InferenceConfigurationManager.sharedInstance.model,
          scoreThreshold: InferenceConfigurationManager.sharedInstance.scoreThreshold,
          maxResult: InferenceConfigurationManager.sharedInstance.maxResults,
          liveStreamDelegate: self,
          delegate: InferenceConfigurationManager.sharedInstance.delegate)
  }
  
  private func clearImageClassifierServiceOnSessionInterruption() {
    stopObserveConfigChanges()
    imageClassifierService = nil
  }
  
  private func startObserveConfigChanges() {
    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(clearAndInitializeImageClassifierService),
                   name: InferenceConfigurationManager.notificationName,
                   object: nil)
    isObserving = true
  }
  
  private func stopObserveConfigChanges() {
    if isObserving {
      NotificationCenter.default
        .removeObserver(self,
                        name: InferenceConfigurationManager.notificationName,
                        object: nil)
    }
    isObserving = false
  }
}

extension CameraViewController {
  @objc private func onTapSwitchCamera() {
    // Get available devices and present an action sheet
    let devices = cameraFeedService.availableVideoDevices()
    guard !devices.isEmpty else { return }

    let alert = UIAlertController(title: "Select Camera", message: nil, preferredStyle: .actionSheet)
    for device in devices {
      // Use localizedName to display e.g. "Back Wide Camera" or similar
      let title = device.localizedName
      alert.addAction(UIAlertAction(title: title, style: .default, handler: { [weak self] _ in
        self?.cameraFeedService.switchCamera(to: device) { success in
          if !success {
            DispatchQueue.main.async {
              let err = UIAlertController(title: "Switch Failed", message: "Unable to switch camera.", preferredStyle: .alert)
              err.addAction(UIAlertAction(title: "OK", style: .cancel))
              self?.present(err, animated: true)
            }
          }
        }
      }))
    }

    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    // For iPad present properly
    if let popover = alert.popoverPresentationController {
      popover.sourceView = switchCameraButton
      popover.sourceRect = switchCameraButton.bounds
    }

    present(alert, animated: true)
  }
}

extension CameraViewController: CameraFeedServiceDelegate {
  
  func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation) {
    let currentTimeMs = Date().timeIntervalSince1970 * 1000
    // Pass the pixel buffer to mediapipe
    backgroundQueue.async { [weak self] in
      self?.imageClassifierService?.classifyAsync(
        sampleBuffer: sampleBuffer,
        orientation: orientation,
        timeStamps: Int(currentTimeMs))
    }
  }
  
  // MARK: Session Handling Alerts
  func sessionWasInterrupted(canResumeManually resumeManually: Bool) {
    // Updates the UI when session is interupted.
    if resumeManually {
      resumeButton.isHidden = false
    } else {
      cameraUnavailableLabel.isHidden = false
    }
    clearImageClassifierServiceOnSessionInterruption()
  }
  
  func sessionInterruptionEnded() {
    // Updates UI once session interruption has ended.
    cameraUnavailableLabel.isHidden = true
    resumeButton.isHidden = true
    initializeImageClassifierServiceOnSessionResumption()
  }
  
  func didEncounterSessionRuntimeError() {
    // Handles session run time error by updating the UI and providing a button if session can be
    // manually resumed.
    resumeButton.isHidden = false
    clearImageClassifierServiceOnSessionInterruption()
  }

  func cameraInputDidChange(to device: AVCaptureDevice) {
    // Update debug overlay and reinit classifier to ensure ML feed is using new device
    DispatchQueue.main.async { [weak self] in
      self?.refreshDebugOverlay()
      self?.clearAndInitializeImageClassifierService()
      print("[CameraViewController] cameraInputDidChange -> \(device.localizedName)")
    }
  }
}

// MARK: ImageClassifierServiceLiveStreamDelegate
extension CameraViewController: ImageClassifierServiceLiveStreamDelegate {

  func imageClassifierService(_ imageClassifierService: ImageClassifierService, didFinishClassification result: ResultBundle?, error: Error?) {
    DispatchQueue.main.async { [weak self] in
      self?.inferenceResultDeliveryDelegate?.didPerformInference(result: result)
    }
  }
}

// MARK: - AVLayerVideoGravity Extension
extension AVLayerVideoGravity {
  var contentMode: UIView.ContentMode {
    switch self {
      case .resizeAspectFill:
        return .scaleAspectFill
      case .resizeAspect:
        return .scaleAspectFit
      case .resize:
        return .scaleToFill
      default:
        return .scaleAspectFill
    }
  }
}

