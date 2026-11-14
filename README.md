# AdShield — 跨平台广告拦截应用

本地 VPN + DNS 过滤方案的广告拦截器，**Flutter 跨平台（Android + iOS）**，并针对**折叠屏手机**做了完整自适应。

> **v1.1.0 升级亮点**
> - **规则库升级**：接入 GitHub 开源 [217heidai/adblockfilters](https://github.com/217heidai/adblockfilters)（256,670 条域名、聚合 AdGuard 中文过滤/EasyList China/AWAvenue 等 15 个源、每 8 小时更新），主源失败自动切换 gh-proxy 国内镜像；
> - **IPv6 DNS 拦截**：新增 IPv6 双栈劫持（Google/Cloudflare/阿里/DNSPod 等硬编码 IPv6 DNS 一并拦截），堵住旧版绕过漏洞；
> - **iOS 云构建**：通过 GitHub Actions macOS runner 产出未签名 IPA（`.github/workflows/ios.yml`）。

## 仓库与安装包

- GitHub 仓库：https://github.com/ihdx4970/adshield
- Android：`AdShield-v1.1.0.apk`（Release 构建，可直接安装）
- iOS：`AdShield-ios-unsigned.ipa`（GitHub Actions 产出，**未签名**，需侧载）

### iOS 安装说明（重要）

iOS 无法像 APK 一样直接安装，未签名 IPA 的安装途径：
1. **AltStore / Sideloadly**：连接电脑用个人 Apple ID 重签（免费证书 7 天有效期，可续签）；
2. **TrollStore**（旧系统适用）：永久签名免越狱安装；
3. 有付费开发者账号（$99/年）可用 Xcode 签名分发。
需要完整签名分发时，把仓库中 `ios_native/DnsFilterPacketTunnelProvider.swift` 按 Xcode 步骤加入 Runner Target 并配置签名即可。

## 项目结构

```
adshield/
├── pubspec.yaml               # Flutter 依赖与资源声明
├── lib/
│   ├── main.dart              # 入口
│   ├── models/models.dart     # 引擎状态 / 统计 / 折叠姿态模型
│   ├── services/
│   │   ├── app_state.dart     # 全局状态（开关、统计轮询、姿态订阅）
│   │   ├── native_bridge.dart # MethodChannel / EventChannel 封装
│   │   ├── rule_service.dart  # 内置规则 + 订阅更新 + 白名单 + 原生同步
│   │   └── stats_service.dart # 统计轮询与 7 日历史持久化
│   └── screens/
│       ├── home_shell.dart    # ★ 折叠屏自适应外壳
│       ├── home_screen.dart   # 拦截开关首页（半开态上下分区）
│       ├── stats_screen.dart  # 统计与趋势图
│       ├── rules_screen.dart  # 订阅更新与白名单
│       └── settings_screen.dart
├── assets/blocklist.txt       # 内置精简广告域名库（约 140 条，可在线更新）
├── android_native/            # 安卓原生（合并进 flutter create 生成的工程）
│   ├── MainActivity.kt        # 方法通道 + Jetpack WindowManager 折叠姿态上报
│   ├── FilterVpnService.kt    # ★ 本地 VPN + DNS 过滤核心
│   ├── AndroidManifest.xml    # 权限与 Service 声明
│   └── build.gradle.additions # 依赖合并片段
└── ios_native/                # iOS 原生（合并进 flutter create 生成的工程）
    ├── AppDelegate.swift      # NEDNSSettingsManager 过滤 DNS 接入
    └── DnsFilterPacketTunnelProvider.swift # 隧道级过滤扩展（对等安卓方案）
```

## 拦截原理（安卓）

1. 建立一个**只路由 DNS 流量**的本地 VPN（假 DNS `10.111.222.3` + 常见硬编码 DNS IP 也一并劫持，防绕过）；
2. 从 tun 读取 UDP/53 包 → 解析出域名 → 命中黑名单返回 **NXDOMAIN**，放行的转发上游 DNS；
3. 非 DNS 流量不进隧道，**不影响网速、无需 Root**。

## 折叠屏适配（三层形态全覆盖）

| 形态 | 触发条件 | 界面 |
|---|---|---|
| 展开（平板式内屏） | 宽度 ≥ 840 且姿态 FLAT | 左侧 NavigationRail + 右侧内容双栏 |
| 半开（桌面/Tabletop） | 安卓 `HALF_OPENED` 姿态 | 顶部导航 chips，首页按铰链**上下分区**：上半屏开关、下半屏实时数据 |
| 合上 / 普通手机 | 窄屏 | 底部导航栏 |

- 姿态数据由 Jetpack WindowManager 经 `adshield/fold` EventChannel 实时上报；
- `MainActivity` 声明了完整的 `configChanges`，展开/合上瞬间 Activity **不重建**；
- Manifest 声明 `resizeable_activity`，支持多窗口/分屏。

## 构建运行

```bash
cd adshield
flutter create .          # 生成 android/ ios/ 平台工程
flutter pub get

# 安卓合并原生文件
cp android_native/MainActivity.kt android/app/src/main/kotlin/com/adshield/app/
cp android_native/AndroidManifest.xml android/app/src/main/
# 按 android_native/build.gradle.additions 合并依赖与 minSdk 配置

flutter run               # 安卓真机测试（拦截需真机，模拟器 VPN 受限）
```

安卓要求 `minSdk 24`；首次开启拦截时系统会弹出 VPN 权限授权框。

### iOS 说明

```bash
cp ios_native/AppDelegate.swift ios/Runner/
```

iOS 受系统限制：
- **默认路径**：`NEDNSSettingsManager` 把系统加密 DNS 指向过滤型 DoH 服务器（见 AppDelegate，需替换为你自托管/订阅的过滤 DNS 地址），对 Safari 及走系统 DNS 的应用生效，开发调试无需特殊能力；
- **完整隧道过滤**（与安卓对等）：按 `DnsFilterPacketTunnelProvider.swift` 顶部注释，在 Xcode 添加 Network Extensions 能力并创建 Packet Tunnel Provider Extension Target，需付费开发者账号，上架审核时需在审核备注中说明用途。

## 已知边界（诚实声明）

- DNS 层拦截无法处理"广告素材与应用同域名/不经过 DNS"的场景（如部分 App 内嵌广告位），该类场景只有 MITM 方案，不在本项目范围内；
- iOS 的 NEDNSSettingsManager 路径下系统不向 App 暴露逐请求统计（统计页在 iOS 上需 PacketTunnel 方案才有数据）；
- 内置规则为精简版，建议在"规则"页点"在线更新订阅"拉取 AdGuard 完整列表。
