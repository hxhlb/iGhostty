import Darwin
import Foundation

/// What this host is called in the Bonjour advertisement and on the other
/// device's screen: the name its owner gave it.
enum RemoteHostName {
    static func current() -> String {
        #if os(macOS)
            if let name = Host.current().localizedName, !name.isEmpty {
                return RemoteAccess.sanitizedName(name)
            }
        #else
            if let name = mobileGestaltDeviceName(), !name.isEmpty {
                return RemoteAccess.sanitizedName(name)
            }
        #endif
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            var name = String(cString: buffer)
            if name.hasSuffix(".local") {
                name.removeLast(6)
            }
            return RemoteAccess.sanitizedName(name)
        }
        return "iGhostVT"
    }

    #if !os(macOS)
        /// The name the owner gave the device in Settings. Outside an app
        /// there is no UIDevice; MobileGestalt answers the same question.
        private static func mobileGestaltDeviceName() -> String? {
            guard let handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY),
                  let symbol = dlsym(handle, "MGCopyAnswer")
            else { return nil }
            typealias CopyAnswer = @convention(c) (CFString) -> Unmanaged<CFTypeRef>?
            let copyAnswer = unsafeBitCast(symbol, to: CopyAnswer.self)
            guard let value = copyAnswer("UserAssignedDeviceName" as CFString)?.takeRetainedValue() else {
                return nil
            }
            return value as? String
        }
    #endif
}
