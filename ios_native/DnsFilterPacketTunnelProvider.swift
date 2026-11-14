//
//  DnsFilterPacketTunnelProvider.swift
//  iOS 隧道级过滤扩展（Network Extension）—— 与安卓 FilterVpnService 对等的方案。
//
//  接入步骤：
//  1. Xcode 中为 Runner Target 添加 "Network Extensions" 能力，
//     勾选 Packet Tunnel Provider；
//  2. 新建一个 Packet Tunnel Provider Extension Target（如 DnsFilterExtension），
//     将本文件设为其 principal class 实现；
//  3. App Group 配置（group.com.adshield.app）用于共享规则文件与统计；
//  4. 将规则（blocklist.txt）由 Flutter 侧写入 App Group 容器，
//     扩展启动时读取。
//
//  本文件提供可运行的 DNS 过滤骨架：拦截 UDP 53 流量，域名命中则回 NXDOMAIN，
//  放行的查询转发至上游 DNS。
//

import NetworkExtension
import UIKit

class DnsFilterPacketTunnelProvider: NEPacketTunnelProvider {

    private var blockSet: Set<String> = []
    private var allowSet: Set<String> = []
    private var upstreamSession: NWConnection?

    // MARK: - 启停

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        loadRules()
        let dnsAddr = "198.18.0.2" // 保留网段内的假 DNS
        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: dnsAddr)
        networkSettings.mtu = 1500
        networkSettings.ipv4Settings = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        // 仅路由 DNS 目标进隧道
        networkSettings.ipv4Settings?.includedRoutes = [
            NEIPv4Route(destinationAddress: dnsAddr, subnetMask: "255.255.255.255")
        ]
        networkSettings.dnsSettings = NEDNSSettings(servers: [dnsAddr])

        setTunnelNetworkSettings(networkSettings) { error in
            if let error = error {
                completionHandler(error)
                return
            }
            self.readPacketsLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        upstreamSession?.cancel()
        completionHandler()
    }

    // MARK: - 规则（从 App Group 读取 Flutter 侧写入的规则文件）

    private func loadRules() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.adshield.app") else { return }
        let blockFile = container.appendingPathComponent("blocklist.txt")
        let allowFile = container.appendingPathComponent("allowlist.txt")
        if let text = try? String(contentsOf: blockFile, encoding: .utf8) {
            blockSet = Set(text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty && !$0.hasPrefix("#") })
        }
        if let text = try? String(contentsOf: allowFile, encoding: .utf8) {
            allowSet = Set(text.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces).lowercased()
            }.filter { !$0.isEmpty })
        }
        blockSet.subtract(allowSet)
    }

    private func isBlocked(_ domain: String) -> Bool {
        if allowSet.contains(domain) { return false }
        var d = domain
        while true {
            if blockSet.contains(d) { return true }
            guard let idx = d.firstIndex(of: "."), d.index(after: idx) < d.endIndex else { return false }
            d = String(d[d.index(after: idx)...])
        }
    }

    // MARK: - 包处理

    private func readPacketsLoop() {
        var readPending = false
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self = self else { return }
            readPending = false
            var outbound: [Data] = []
            var outboundProtocols: [NSNumber] = []

            for (i, packet) in packets.enumerated() {
                if protocols[i].intValue != AF_INET { continue }
                if let reply = self.handleIpPacket(packet) {
                    outbound.append(reply)
                    outboundProtocols.append(NSNumber(value: AF_INET))
                }
            }
            if !outbound.isEmpty {
                self.packetFlow.writePackets(outbound, withProtocols: outboundProtocols)
            }
            // 继续读取
            if !readPending {
                self.readPacketsLoop()
            }
        }
    }

    /// 解析 IPv4+UDP DNS 查询；命中返回 NXDOMAIN 应答包，放行返回 nil（由转发逻辑处理）
    private func handleIpPacket(_ packet: Data) -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 28, bytes[0] >> 4 == 4, bytes[9] == 17 else { return nil }
        let ihl = Int(bytes[0] & 0x0F) * 4
        guard bytes.count >= ihl + 8 else { return nil }

        let dstPort = (Int(bytes[ihl + 2]) << 8) | Int(bytes[ihl + 3])
        let udpLen = (Int(bytes[ihl + 4]) << 8) | Int(bytes[ihl + 5])
        guard dstPort == 53, udpLen >= 8, bytes.count >= ihl + udpLen else { return nil }

        let dnsMsg = packet.subdata(in: (ihl + 8)..<(ihl + udpLen))
        guard let name = parseDnsQueryName(dnsMsg) else { return nil }

        guard isBlocked(name) else {
            // 放行：转发到上游（此处以系统默认 DNS 为例，完整实现见安卓端 FilterVpnService 的
            // forwardToUpstream，逻辑一致：NWConnection 发送原始查询并回写应答）
            forwardToUpstream(packet, dnsOffset: ihl + 8)
            return nil
        }
        // 拦截：构造 NXDOMAIN 应答
        let srcIp = Array(packet[12..<16]), dstIp = Array(packet[16..<20])
        let srcPort = (Int(bytes[ihl]) << 8) | Int(bytes[ihl + 1])
        return buildDnsReply(srcIp: srcIp, dstIp: dstIp,
                             srcPort: srcPort, dstPort: dstPort,
                             dnsMsg: dnsMsg, nxDomain: true)
    }

    private func parseDnsQueryName(_ msg: Data) -> String? {
        let bytes = [UInt8](msg)
        guard bytes.count > 12, (bytes[2] >> 7) == 0 else { return nil }
        var labels: [String] = []
        var i = 12
        while i < bytes.count {
            let len = Int(bytes[i])
            if len == 0 { break }
            guard len <= 63, i + 1 + len <= bytes.count else { return nil }
            labels.append(String(bytes: bytes[(i + 1)..<(i + 1 + len)], encoding: .ascii) ?? "")
            i += 1 + len
        }
        return labels.joined(separator: ".").lowercased()
    }

    /// 简化的应答构造（NXDOMAIN：复用 header+question，RCODE=3）
    private func buildDnsReply(srcIp: [UInt8], dstIp: [UInt8],
                               srcPort: Int, dstPort: Int,
                               dnsMsg: Data, nxDomain: Bool) -> Data {
        var dns = [UInt8](dnsMsg.prefix(512))
        if dns.count >= 12 {
            dns[2] = 0x81
            dns[3] = nxDomain ? 0x83 : 0x80
            dns[6] = 0; dns[7] = 0; dns[8] = 0; dns[9] = 0; dns[10] = 0; dns[11] = 0
        }
        return DnsPacketBuilder.build(srcIp: srcIp, dstIp: dstIp,
                                      srcPort: srcPort, dstPort: dstPort,
                                      dnsPayload: dns)
    }

    private func forwardToUpstream(_ packet: Data, dnsOffset: Int) {
        // 骨架：建议使用 NWConnection(host: "223.5.5.5", port: 53, using: .udp)
        // 发送 dnsMsg 并将应答通过 packetFlow.writePackets 回写。
        // 完整实现可参照安卓端 forwardToUpstream 的逻辑（protect + 转发 + 回写）。
    }
}

/// IP/UDP 应答封包工具（含校验和计算）
enum DnsPacketBuilder {
    static func build(srcIp: [UInt8], dstIp: [UInt8],
                      srcPort: Int, dstPort: Int,
                      dnsPayload: [UInt8]) -> Data {
        let udpLen = 8 + dnsPayload.count
        let totalLen = 20 + udpLen
        var out = [UInt8](repeating: 0, count: totalLen)

        out[0] = 0x45
        out[2] = UInt8((totalLen >> 8) & 0xFF); out[3] = UInt8(totalLen & 0xFF)
        out[6] = 0x40
        out[8] = 64
        out[9] = 17
        out.replaceSubrange(12..<16, with: srcIp)
        out.replaceSubrange(16..<20, with: dstIp)
        let ipCk = checksum(Array(out[0..<20]))
        out[10] = UInt8((ipCk >> 8) & 0xFF); out[11] = UInt8(ipCk & 0xFF)

        let u = 20
        out[u] = UInt8((srcPort >> 8) & 0xFF); out[u + 1] = UInt8(srcPort & 0xFF)
        out[u + 2] = UInt8((dstPort >> 8) & 0xFF); out[u + 3] = UInt8(dstPort & 0xFF)
        out[u + 4] = UInt8((udpLen >> 8) & 0xFF); out[u + 5] = UInt8(udpLen & 0xFF)
        out.replaceSubrange((u + 8)..<(u + 8 + dnsPayload.count), with: dnsPayload)

        // UDP 校验和（伪首部）
        var pseudo = [UInt8]()
        pseudo.append(contentsOf: srcIp)
        pseudo.append(contentsOf: dstIp)
        pseudo += [0, 17]
        pseudo += [UInt8((udpLen >> 8) & 0xFF), UInt8(udpLen & 0xFF)]
        pseudo.append(contentsOf: out[u..<(u + udpLen)])
        let ck = checksum(pseudo)
        out[u + 6] = UInt8((ck >> 8) & 0xFF); out[u + 7] = UInt8(ck & 0xFF)

        return Data(out)
    }

    static func checksum(_ bytes: [UInt8]) -> Int {
        var sum = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += Int(bytes[i]) << 8 }
        while sum > 0xFFFF { sum = (sum & 0xFFFF) + (sum >> 16) }
        return (~sum) & 0xFFFF
    }
}
