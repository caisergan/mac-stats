import Foundation

/// Geolocation for one remote IP, from the bundled-or-downloaded MaxMind
/// GeoLite2 database. Absent fields stay nil; the UI hides them.
public struct GeoInfo: Sendable, Equatable {
    public var countryCode: String?
    public var countryName: String?
    public var cityName: String?
}

/// Reads MaxMind `.mmdb` files directly: the format is a binary search tree
/// over IP prefixes followed by a data section of self-describing values, and
/// the subset GeoLite2 uses (pointers, strings, maps, unsigned integers) is
/// small enough that the repo takes no dependency for it. Only Country/City
/// databases are expected; anything else fails to open and every consumer
/// degrades to hidden columns.
///
/// Thread-safe: the file is read once at init and never mutated, and the
/// lookup cache is lock-guarded. Opening reads (and copies) the whole database,
/// which is ~9 MB for Country and far more for City, so construct it off the
/// main thread.
public final class GeoLocator {
    /// Default location for the downloaded database.
    public static func defaultDatabaseURL() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent("MacPerformanceMonitor", isDirectory: true)
            .appendingPathComponent("GeoLite2-Country.mmdb")
    }

    public let databaseDate: Date?

    private let data: [UInt8]
    private let nodeCount: Int
    private let recordSizeBits: Int
    private let nodeBytes: Int
    private let treeBytes: Int
    private let dataStart: Int

    public init?(url: URL) {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](raw)
        // The metadata is a data-section value whose start is marked by
        // 0xAB 0xCD 0xEF + "MaxMind.com", in the file's tail.
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        let scanStart = max(0, bytes.count - 200_000)
        var metadataStart: Int?
        if bytes.count >= marker.count {
            var index = bytes.count - marker.count
            while index >= scanStart {
                // Compare in place: allocating an Array per candidate offset
                // walked ~200k throwaway allocations before finding the marker.
                var matched = true
                for offset in 0..<marker.count where bytes[index + offset] != marker[offset] {
                    matched = false
                    break
                }
                if matched {
                    metadataStart = index + marker.count
                    break
                }
                index -= 1
            }
        }
        guard let metaStart = metadataStart else { return nil }
        self.data = bytes

        // Decode the metadata map from its start; data-section pointers inside
        // the metadata are relative to that start.
        var offset = metaStart
        guard case .map(let fields)? = Self.decode(bytes, &offset, base: metaStart) else {
            return nil
        }
        func field(_ key: String) -> Value? { fields.first { $0.0 == key }?.1 }
        guard case .uint(let recordSizeRaw)? = field("record_size"),
            case .uint(let nodeCountRaw)? = field("node_count"),
            case .uint(let version)? = field("binary_format_major_version"), version == 2
        else { return nil }
        self.recordSizeBits = Int(recordSizeRaw)
        self.nodeCount = Int(nodeCountRaw)
        self.databaseDate = {
            if case .uint(let epoch)? = field("build_epoch") {
                return Date(timeIntervalSince1970: TimeInterval(epoch))
            }
            return nil
        }()
        self.nodeBytes = recordSizeBits * 2 / 8
        self.treeBytes = nodeCount * nodeBytes
        self.dataStart = treeBytes + 16
    }

    /// Every address looked up so far, hits and misses alike. The connection
    /// table asks for a row's country every time the row is drawn, so an
    /// uncached lookup walked the prefix tree once per row per frame.
    private let cacheLock = NSLock()
    private var cache: [String: GeoInfo?] = [:]

    /// Look up one IPv4/IPv6 address. Unknown or private addresses return nil.
    /// Cached, so repeated lookups of the same address are a dictionary hit.
    public func lookup(_ ip: String) -> GeoInfo? {
        cacheLock.lock()
        if let cached = cache[ip] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let info = uncachedLookup(ip)
        cacheLock.lock()
        // A session browsing many hosts must not grow this without limit;
        // wholesale reset on overflow is fine for a display cache.
        if cache.count >= 4_096 { cache.removeAll(keepingCapacity: true) }
        cache[ip] = .some(info)
        cacheLock.unlock()
        return info
    }

    private func uncachedLookup(_ ip: String) -> GeoInfo? {
        var address = in_addr()
        var address6 = in6_addr()
        var bytes: [UInt8]
        let bits: Int
        if inet_pton(AF_INET, ip, &address) == 1 {
            bytes = withUnsafeBytes(of: &address) { Array($0) }
            bits = 32
        } else if inet_pton(AF_INET6, ip, &address6) == 1 {
            bytes = withUnsafeBytes(of: &address6) { Array($0) }
            bits = 128
        } else {
            return nil
        }
        // An IPv4 address in an IPv6 tree starts after the ::/96 hole.
        var node = 0
        let bitCount = recordSizeBits == 32 ? bits : 96 + bits
        var value: Int = 0
        for bit in 0..<bitCount {
            if node == nodeCount { return nil }  // not in the database
            if node > nodeCount {
                value = node
                break
            }
            let byte = bit / 8 < bytes.count ? bytes[bit / 8] : 0
            let bitSet = Int((byte >> (7 - bit % 8)) & 1)
            let offset = node * nodeBytes + bitSet * recordSizeBits / 8
            node = readInteger(offset, recordSizeBits / 8)
        }
        if node > nodeCount { value = node }
        guard value >= nodeCount else { return nil }
        var offset = value - nodeCount + treeBytes
        guard case .map(let fields)? = Self.decode(data, &offset, base: dataStart) else {
            return nil
        }
        func countryField(_ path: [String]) -> Value? {
            var current: Value = .map(fields)
            for key in path {
                guard case .map(let entries) = current,
                    let next = entries.first(where: { $0.0 == key })?.1
                else { return nil }
                current = next
            }
            return current
        }
        func string(_ value: Value?) -> String? {
            guard case .string(let string)? = value else { return nil }
            return string
        }
        return GeoInfo(
            countryCode: string(countryField(["country", "iso_code"])),
            countryName: string(countryField(["country", "names", "en"])),
            cityName: string(countryField(["city", "names", "en"])))
    }

    private func readInteger(_ offset: Int, _ width: Int) -> Int {
        var value = 0
        for index in 0..<width {
            value = value << 8 | Int(data[offset + index])
        }
        return value
    }

    // MARK: - Data-section decoding

    /// Self-describing values, tagged for the decoder.
    fileprivate enum Value {
        case uint(UInt64)
        case string(String)
        case map([(String, Value)])
    }

    /// Decode one value at `offset` (advanced past it). `base` is where
    /// pointers are relative to (metadata start or data-section start).
    fileprivate static func decode(_ bytes: [UInt8], _ offset: inout Int, base: Int) -> Value? {
        guard offset < bytes.count else { return nil }
        let control = bytes[offset]
        offset += 1
        var type = Int((control >> 5) & 0x7)
        if type == 1 {  // pointer
            let pointerSize = Int((control >> 3) & 0x3)
            let packed = Int(control & 0x7)
            guard offset + pointerSize + 1 <= bytes.count else { return nil }
            var pointer = 0
            switch pointerSize {
            case 0:
                pointer = (packed << 8) + Int(bytes[offset])
                offset += 1
            case 1:
                pointer = (packed << 16) + Int(bytes[offset]) << 8 + Int(bytes[offset + 1]) + 2_048
                offset += 2
            case 2:
                pointer =
                    (packed << 24) + Int(bytes[offset]) << 16 + Int(bytes[offset + 1]) << 8
                    + Int(bytes[offset + 2]) + 526_336
                offset += 3
            default:
                pointer = readUInt32(bytes, offset)
                offset += 4
            }
            // Re-decode from the pointed-to position.
            var pointerOffset = base + pointer
            return decode(bytes, &pointerOffset, base: base)
        }
        if type == 0 {  // extended type
            guard offset < bytes.count else { return nil }
            type = Int(bytes[offset]) + 7
            offset += 1
        }
        var size = Int(control & 0x1F)
        switch size {
        case 29:
            guard offset < bytes.count else { return nil }
            size = Int(bytes[offset]) + 29
            offset += 1
        case 30:
            guard offset + 1 < bytes.count else { return nil }
            size = Int(bytes[offset]) << 8 + Int(bytes[offset + 1]) + 285
            offset += 2
        case 31:
            guard offset + 2 < bytes.count else { return nil }
            size =
                Int(bytes[offset]) << 16 + Int(bytes[offset + 1]) << 8 + Int(bytes[offset + 2])
                + 65_821
            offset += 3
        default:
            break
        }
        switch type {
        case 2:  // utf8 string
            guard offset + size <= bytes.count else { return nil }
            let string = String(decoding: bytes[offset..<offset + size], as: UTF8.self)
            offset += size
            return .string(string)
        case 7:  // map
            var entries: [(String, Value)] = []
            entries.reserveCapacity(min(size, 64))
            for _ in 0..<size {
                guard case .string(let key)? = decode(bytes, &offset, base: base) else {
                    return nil
                }
                guard let value = decode(bytes, &offset, base: base) else { return nil }
                entries.append((key, value))
            }
            return .map(entries)
        case 14:  // boolean
            return .uint(size == 1 ? 1 : 0)
        case 5, 6, 8, 9:  // uint16/32, int32, uint64
            guard offset + size <= bytes.count else { return nil }
            var value: UInt64 = 0
            for index in 0..<size {
                value = value << 8 | UInt64(bytes[offset + index])
            }
            offset += size
            return .uint(value)
        default:
            // Doubles, floats, arrays, containers and dates are not needed for
            // the country/city fields this reader extracts; skip generically.
            offset += size
            return size == 0 ? .uint(0) : nil
        }
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
    }
}
