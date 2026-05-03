import Foundation
import SwiftUI

/// NetworkDiag — local network interface enumeration helper.
/// Extracted ze SettingsView.swift jako součást big-refactor split (krok #10).

// MARK: - Network diagnostics helper

enum NetworkDiag {
    struct Interface: Identifiable {
        let id = UUID()
        let name: String       // en0, en1, ...
        let kind: String       // "Ethernet", "Wi-Fi"
        let ipv4: String
        var icon: String {
            switch kind {
            case "Ethernet": return "cable.connector"
            case "Wi-Fi": return "wifi"
            case "Loopback": return "arrow.triangle.2.circlepath"
            default: return "network"
            }
        }
        var color: Color {
            switch kind {
            case "Ethernet": return .cyan
            case "Wi-Fi": return .orange
            default: return .gray
            }
        }
    }

    /// Zjistí, přes který interface běží route k dané IP. Runs `/sbin/route -n get <ip>`.
    static func routeInterface(forIP ip: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", ip]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "—" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return "—" }
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                let ifname = t.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return "\(ifname) (\(interfaceKind(ifname)))"
            }
        }
        return "—"
    }

    static func interfaceKind(_ name: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-listallhardwareports"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return "other" }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return "other" }
        let blocks = out.components(separatedBy: "Hardware Port:")
        for b in blocks {
            if b.contains("Device: \(name)") {
                let head = b.split(separator: "\n").first.map(String.init) ?? ""
                let port = head.trimmingCharacters(in: .whitespaces)
                let lower = port.lowercased()
                if lower.contains("ethernet") || lower.contains("thunderbolt") { return "Ethernet" }
                if lower.contains("wi-fi") || lower.contains("wifi") || lower.contains("airport") { return "Wi-Fi" }
                return port.isEmpty ? "other" : port
            }
        }
        return "other"
    }

    static func listInterfaces() -> [Interface] {
        var out: [Interface] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let p = ptr else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            guard let sa = p.pointee.ifa_addr else { continue }
            var family = sa_family_t(AF_UNSPEC)
            family = sa.pointee.sa_family
            guard family == AF_INET else { continue }
            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(sa, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                                &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
            if rc == 0 {
                let ip = String(cString: hostBuf)
                let kind = interfaceKind(name)
                // dedupe by name
                if !out.contains(where: { $0.name == name }) {
                    out.append(Interface(name: name, kind: kind, ipv4: ip))
                }
            }
        }
        return out.sorted { $0.name < $1.name }
    }
}
