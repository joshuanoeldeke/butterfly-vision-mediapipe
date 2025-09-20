# MediaPipe Tasks Image Classification iOS Demo

### Overview

This is a camera app that continuously classifies the objects (classes and confidence) in the frames seen by your device's back camera, in an image imported from the device gallery,  or in a video imported by the device gallery, with the option to use a quantized [EfficientDet Lite 0](https://storage.googleapis.com/mediapipe-tasks/object_detector/efficientdet_lite0_uint8.tflite), or [EfficientDet Lite2](https://storage.googleapis.com/mediapipe-tasks/object_detector/efficientdet_lite2_uint8.tflite) model.

The model files are downloaded by a pre-written script when you build and run the app. You don't need to do any steps to download TFLite models into the project explicitly unless you wish to use your own models. If you do use your own models, place them into the app's ** directory.

Before running your app, you will need to run `pod install` from the iOS directory under the image_classifier example directory (the one you're reading this from right now!).

This application should be run on a physical iOS device to take advantage of the physical camera, though the gallery tab will enable you to use an emulator for opening locally stored files.

### Prerequisites

*   The **[xCode](https://apps.apple.com/us/app/xcode/id497799835)** IDE. This sample has been tested on xCode 14.3.1.

*   A physical iOS device. This app targets iOS Deployment Target 15

### Building

*   Open xCode. From the Welcome screen, select `Open a project or file`

*   From the window that appears, navigate to and select
    the Runner.xcworkspace file under mediapipe/examples/image_classification/ios directory. Click Open. 

*   From a terminal window, run `pod install`

*   You may need to select a team under *Signing and Capabilities*

### Camera switching

This app now includes a camera switcher button in the live camera preview (top-right). Tap "Switch" to choose from the available physical cameras on your device (front, back wide, ultra-wide, telephoto, etc.). The list only shows cameras that the device supports.

Notes:
- Camera switching requires a physical device (not the simulator).
- If a switch attempt fails, an alert will be shown. Ensure the app has camera permission and no other app is using the camera.

---
ADDITIONS (added by project contributors):

- We added a camera switching UI that mimics the iPhone Camera app behavior:
    - A front/back toggle button appears at the top-right of the live preview.
    - A small zoom-style strip (0.5x, 1x, 2x) is shown; tapping one attempts to pick the camera device that best matches that zoom level (ultra-wide, wide, telephoto). This is an app-level convenience UI and will show only the matched devices available on your hardware.

- Logging & debug overlay:
    - The app now prints which physical device is being used for capture in the Xcode console from `CameraFeedService` (e.g. "[CameraFeedService] captureOutput using device: Back Ultra Wide Camera").
    - We added an on-screen debug overlay (top-left) that shows "Preview: <device>\nML: <device>" so you can verify visually which camera is shown to the user and which is being provided to the ML pipeline.

- ML feed assurance:
    - When a camera switch occurs we notify the view controller and re-initialize the image classifier service so the ML pipeline uses the newly active camera device. We also log the camera changes to the console.

- Duplicate device entries (Dual/Triple):
    - Some devices expose multiple aggregate device types (e.g., "Back Dual Camera" or "Back Triple Camera") which represent logical groupings of multiple physical cameras. These entries can be redundant in a selection UI. We now deduplicate devices by device type + position when building the selection list so you won't see both "Back Wide Camera" and "Back Dual Camera" for the same physical capability.

If you'd like different UX (for example icons, pinch-to-zoom, or an expanded camera picker), tell me which style and I can implement it.

---