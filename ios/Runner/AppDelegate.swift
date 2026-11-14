//
//  AppDelegate.swift
//  AdShield iOS 端集成说明：
//
//  iOS 受系统限制无法像安卓那样自由建 VPN，本端采用两层方案：
//  1. NEDNSSettingsManager（iOS 14+，无需特殊授权审批即可开发调试）：
//     将系统加密 DNS 指向一个"会过滤的 DoH 服务器"（自托管或第三方过滤 DNS），
//     对 Safari 和走系统 DNS 的 App 生效。
//  2. NEPacketTunnelProvider（见 DnsFilterPacketTunnelProvider.swift）：
//     真正的隧道级过滤，与安卓 FilterVpnService 对等，需要申请
//     Network Extension 能力（付费开发者账号），审核需说明用途。
//
//  Flutter 侧接口与安卓共用同一个 "adshield/native" MethodChannel。
//

import UIKit
import Flutter
import NetworkExtension

@main
@objc class AppDelegate: FlutterAppDelegate {

    private let dnsManager = NEDNSSettingsManager.shared()

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        let controller = window?.rootViewController as? FlutterViewController
        if let channel = FlutterMethodChannel(
            name: "adshield/native", binaryMessenger: controller!.binaryMessenger) {
            channel.setMethodCallHandler { [weak self] call, result in
                self?.handle(call: call, result: result)
            }
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startEngine":
            startDnsFiltering(arguments: call.arguments, result: result)
        case "stopEngine":
            stopDnsFiltering(result: result)
        case "getStatus":
            dnsManager.loadFromPreferences { [weak self] error in
                result((self?.dnsManager.dnsSettings != nil) ? "running" : "off")
            }
        case "getStats":
            // DNS 配置模式下系统不向 App 暴露逐请求统计。
            // 升级为 PacketTunnelProvider 后可在 provider 内计数并通过
            // App Group 共享 UserDefaults 回传（见 DnsFilterPacketTunnelProvider）。
            result([
                "blockedToday": 0,
                "allowedToday": 0,
                "totalBlocked": 0,
            ])
        case "reloadRules":
            result(true) // DNS 配置模式下规则在 DoH 服务端，无需本地重载
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - NEDNSSettingsManager 过滤 DNS

    private func startDnsFiltering(arguments: Any?, result: @escaping FlutterResult) {
        guard #available(iOS 14.0, *) else {
            result(false)
            return
        }
        // 过滤型 DoH 服务器地址（替换为自托管实例，或申请 PacketTunnel 方案）
        let filterDohUrl = "https://dns.example-filter.com/dns-query"

        let settings = NEDNSSettings(doHServer: NEDNSOverHTTPSServer(
            serverName: "dns.example-filter.com",
            serverURL: URL(string: filterDohUrl)!
        ))
        settings.matchDomains = [""] // 空字符串语义：所有域名查询都走该配置
        dnsManager.dnsSettings = settings

        dnsManager.saveToPreferences { [weak self] error in
            if let error = error {
                print("DNS 配置保存失败: \(error.localizedDescription)")
                result(false)
            } else {
                self?.dnsManager.loadFromPreferences { _ in
                    result(true)
                }
            }
        }
    }

    private func stopDnsFiltering(result: @escaping FlutterResult) {
        guard #available(iOS 14.0, *) else {
            result(false)
            return
        }
        dnsManager.dnsSettings = nil
        dnsManager.removeFromPreferences { error in
            result(error == nil)
        }
    }
}
