import Foundation
import Network

/// Tells OMNIS when this Mac loses its internet connection and when it comes back.
///
/// macOS reports the change; nothing is polled and no site is contacted to find out.
@MainActor
final class ConnectionWatch {
    private let monitor = NWPathMonitor()

    init(changed: @escaping @MainActor (_ offline: Bool) -> Void) {
        if AppEnvironment.forceOffline {
            changed(true)
            return
        }
        monitor.pathUpdateHandler = { path in
            let offline = path.status != .satisfied
            // In the order they are reported, so a quick off-and-on ends up right.
            DispatchQueue.main.async { MainActor.assumeIsolated { changed(offline) } }
        }
        monitor.start(queue: DispatchQueue(label: "omnis.connection"))
    }

    deinit { monitor.cancel() }
}
