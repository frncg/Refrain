import Foundation

/// The "System Audio Recording" permission, via private TCC calls: there's no public API for it.
enum SystemAudioPermission {
    enum Status { case unknown, authorized, denied }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    static var status: Status {
        guard let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(false) }
        unsafeBitCast(symbol, to: Request.self)(service, nil, completion)
    }
}
