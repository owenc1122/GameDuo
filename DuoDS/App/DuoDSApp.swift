import SwiftUI
import UIKit

@main
struct DuoDSApp: App {
    @UIApplicationDelegateAdaptor(DuoAppDelegate.self) private var appDelegate
    @StateObject private var session = EmulatorSession()
    @StateObject private var proEntitlement = DuoProEntitlement()
    @StateObject private var proStore = DuoProStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .environmentObject(proEntitlement)
                .environmentObject(proStore)
        }
    }
}

@MainActor
final class DuoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        DuoOrientation.allowed
    }
}

@MainActor
enum DuoOrientation {
    private(set) static var allowed: UIInterfaceOrientationMask = .allButUpsideDown
    private static var previousOrientation: UIInterfaceOrientation = .portrait
    static let isDuoDevice: Bool = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == "iPhone19,4"
        #else
        var system = utsname()
        uname(&system)
        let identifier = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        return identifier == "iPhone19,4"
        #endif
    }()

    static func setPSPGameplay(_ active: Bool) {
        guard !isDuoDevice, UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })
        else { return }
        let wasLocked = allowed == .landscape
        guard active != wasLocked else { return }
        if active { previousOrientation = scene.interfaceOrientation }
        allowed = active ? .landscape : .allButUpsideDown
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        let destination: UIInterfaceOrientationMask
        if active {
            destination = scene.interfaceOrientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        } else {
            destination = previousOrientation == .landscapeLeft ? .landscapeLeft
                : previousOrientation == .landscapeRight ? .landscapeRight : .portrait
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: destination)) { error in
            print("DUO_ORIENTATION_REQUEST_FAILED: \(error.localizedDescription)")
        }
    }
}
