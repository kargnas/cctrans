import Foundation
import ServiceManagement

struct LoginItemState: Encodable {
    var supported: Bool
    var enabled: Bool
    var status: String
    var message: String
}

enum LoginItemController {
    static func status() -> LoginItemState {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return LoginItemState(
                supported: false,
                enabled: false,
                status: "unsupported",
                message: "Open the installed CCTrans.app bundle to manage login startup."
            )
        }

        return state(for: SMAppService.mainApp.status)
    }

    static func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return status()
        }

        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled && service.status != .requiresApproval {
                try service.register()
            }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }

        return state(for: service.status)
    }

    private static func state(for status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:
            LoginItemState(
                supported: true,
                enabled: true,
                status: "enabled",
                message: "CCTrans will open automatically when you sign in."
            )
        case .notRegistered:
            LoginItemState(
                supported: true,
                enabled: false,
                status: "notRegistered",
                message: "CCTrans is not set to open at login."
            )
        case .requiresApproval:
            LoginItemState(
                supported: true,
                enabled: true,
                status: "requiresApproval",
                message: "Approve CCTrans in System Settings > General > Login Items."
            )
        case .notFound:
            LoginItemState(
                supported: true,
                enabled: false,
                status: "notFound",
                message: "The login item could not be found. Run CCTrans from its app bundle."
            )
        @unknown default:
            LoginItemState(
                supported: true,
                enabled: false,
                status: "unknown",
                message: "The login item status is unknown."
            )
        }
    }
}
