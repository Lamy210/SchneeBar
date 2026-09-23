import Foundation

public func githubDeviceFlowAuthorizationHost(
    _ verificationURI: URL
) -> String {
    guard let host = verificationURI.host else {
        return verificationURI.absoluteString
    }
    if let port = verificationURI.port {
        return "\(host):\(port)"
    }
    return host
}

public func githubDeviceFlowAntiPhishingMessage(
    verificationURI: URL
) -> String {
    let host = githubDeviceFlowAuthorizationHost(verificationURI)
    return "Only enter this code at \(host) after starting this authorization in SchneeBar. Never approve a device code received through chat, email, a ticket, or another app."
}
