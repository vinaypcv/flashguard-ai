import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FlashGuardVolumeBridge") {
      let channel = FlutterMethodChannel(
        name: "com.sandisk.flashguard/volume",
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { call, result in
        if call.method == "getVolumeStats" {
          // A future adapter must resolve a persisted security-scoped bookmark,
          // start access, and query URLResourceValues for that selected volume.
          result(FlutterError(
            code: "VOLUME_API_NOT_WIRED",
            message: "iOS security-scoped volume adapter is pending",
            details: nil
          ))
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
