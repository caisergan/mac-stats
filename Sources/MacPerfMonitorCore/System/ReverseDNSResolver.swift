import Darwin
import Foundation

/// Lazy, cached reverse DNS for the Connection History table.
///
/// Resolution happens per visible row on demand (never on the collection
/// path): a PTR lookup can take hundreds of milliseconds and the history table
/// can show hundreds of remote IPs. Results, including misses (many remote
/// addresses simply have no PTR), are cached for the process lifetime in a
/// bounded dictionary, so scrolling a populated table costs nothing.
public final class ReverseDNSResolver {
    public static let shared = ReverseDNSResolver()

    /// Bounded so a long session browsing many hosts cannot grow it without
    /// limit; wholesale reset on overflow is fine for a UI cache.
    private let capacity = 1_024
    private var cache: [String: String?] = [:]
    private let lock = NSLock()

    public init() {}

    /// The cached answer if this IP has been resolved before: `.some(name)` for
    /// a hit, `.some(nil)` for a cached miss, `nil` when it has never been
    /// looked up. The two nils must stay distinguishable, or a miss (which most
    /// remote addresses are, since few have a PTR record) re-dispatches a
    /// `getnameinfo` every time the row is drawn.
    public func cachedAnswer(for ip: String) -> String?? {
        lock.lock()
        defer { lock.unlock() }
        return cache[ip]
    }

    /// The cached hostname, or nil when unresolved or the OS has no PTR.
    public func cachedHostname(for ip: String) -> String? {
        cachedAnswer(for: ip) ?? nil
    }

    /// Resolve off the caller's thread and report back. The completion runs on
    /// an arbitrary background queue; hop to main before touching views.
    public func resolve(_ ip: String, completion: @escaping @Sendable (String?) -> Void) {
        if let cached = cachedAnswer(for: ip) {
            completion(cached)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let hostname = Self.lookup(ip)
            self.store(ip, hostname)
            completion(hostname)
        }
    }

    private func store(_ ip: String, _ hostname: String?) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count >= capacity { cache.removeAll(keepingCapacity: true) }
        cache[ip] = .some(hostname)
    }

    /// Reverse-resolve `ip` via `getnameinfo`, strict: no PTR record means nil
    /// rather than a numeric fallback (the caller already has the IP).
    static func lookup(_ ip: String) -> String? {
        var addr4 = sockaddr_in()
        var addr6 = sockaddr_in6()
        let family: Int32
        let length: socklen_t
        if inet_pton(AF_INET, ip, &addr4.sin_addr) == 1 {
            family = AF_INET
            addr4.sin_family = sa_family_t(AF_INET)
            addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        } else if inet_pton(AF_INET6, ip, &addr6.sin6_addr) == 1 {
            family = AF_INET6
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            return nil
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result =
            family == AF_INET
            ? withUnsafeMutablePointer(to: &addr4) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo(
                        $0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
            : withUnsafeMutablePointer(to: &addr6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo(
                        $0, length, &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        guard result == 0 else { return nil }
        let name = String(cString: host)
        return name.isEmpty ? nil : name
    }
}
