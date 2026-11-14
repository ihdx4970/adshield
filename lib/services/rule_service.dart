import "dart:convert";
import "dart:io";

import "package:flutter/services.dart" show rootBundle;
import "package:path_provider/path_provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../models/models.dart";

/// 规则管理：
/// - 内置规则：assets/blocklist.txt（首次启动导入本地文件）
/// - 订阅规则：在线拉取 hosts 格式广告域名列表
/// - 白名单：用户手动放行的域名
/// 最终合并写入应用文件目录下的 blocklist.txt，供安卓 VPN 服务读取。
class RuleService {
  static const _kBlockDomainsKey = "block_domains";
  static const _kAllowDomainsKey = "allow_domains";
  static const _kSubscriptionsKey = "subscriptions";
  static const _kLastUpdateKey = "last_rule_update";

  final SharedPreferences _prefs;

  Set<String> _blockDomains = {};
  final Set<String> _allowDomains = {};
  final List<RuleSubscription> _subscriptions = [];

  RuleService(this._prefs);

  static Future<RuleService> load() async {
    final prefs = await SharedPreferences.getInstance();
    final svc = RuleService(prefs);
    await svc._init();
    return svc;
  }

  Future<void> _init() async {
    _blockDomains =
        (prefsList(_kBlockDomainsKey)).toSet();
    _allowDomains.addAll(prefsList(_kAllowDomainsKey));
    final subsJson = prefsList(_kSubscriptionsKey);
    for (final s in subsJson) {
      try {
        _subscriptions
            .add(RuleSubscription.fromJson(jsonDecode(s) as Map<Object?, Object?>));
      } catch (_) {}
    }
    if (_subscriptions.isEmpty) {
      // GitHub 开源规则源：主源直连 GitHub，镜像走国内加速
      _subscriptions.addAll([
        const RuleSubscription(
          name: "adblockfilters 国内合并规则（25.6 万域名，每 8 小时更新）",
          url: "https://github.com/217heidai/adblockfilters/releases/download/rule/adblockdomain.txt",
          mirror: "https://gh-proxy.com/https://github.com/217heidai/adblockfilters/releases/download/rule/adblockdomain.txt",
        ),
        const RuleSubscription(
          name: "AdGuard DNS 精简国际规则",
          url: "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt",
        ),
      ]);
    }
    // 首次启动：内置规则导入本地存储
    if (_blockDomains.isEmpty) {
      try {
        final raw = await rootBundle.loadString("assets/blocklist.txt");
        _blockDomains = parseHostsList(raw);
        await _saveBlockDomains();
      } catch (_) {}
    }
  }

  List<String> prefsList(String key) =>
      _prefs.getStringList(key) ?? const <String>[];

  /// 解析 hosts / adblock 域名列表格式（每行一个域名或 `||domain^` / `0.0.0.0 domain`）。
  static Set<String> parseHostsList(String raw) {
    final result = <String>{};
    for (final line in raw.split("\n")) {
      var l = line.trim();
      if (l.isEmpty || l.startsWith("#") || l.startsWith("!")) continue;
      l = l.split(RegExp(r"\s+")).last; // hosts 格式 "0.0.0.0 domain"
      if (l.startsWith("||")) l = l.substring(2);
      if (l.startsWith("@@")) continue;
      if (l.endsWith("^")) l = l.substring(0, l.length - 1);
      if (l.contains("/") || l.contains("*") || l.contains("\$")) continue;
      if (l.contains(".") && l.length > 3) result.add(l.toLowerCase());
    }
    return result;
  }

  Future<void> _saveBlockDomains() async {
    await _prefs.setStringList(_kBlockDomainsKey, _blockDomains.toList());
  }

  // ---------- 访问器 ----------

  int get blockCount => _blockDomains.length;
  Set<String> get allowDomains => Set.unmodifiable(_allowDomains);
  List<RuleSubscription> get subscriptions => List.unmodifiable(_subscriptions);
  DateTime? get lastUpdate {
    final ms = _prefs.getInt(_kLastUpdateKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  // ---------- 白名单 ----------

  Future<void> addAllowDomain(String domain) async {
    final d = domain.trim().toLowerCase();
    if (d.isEmpty) return;
    _allowDomains.add(d);
    _blockDomains.remove(d);
    await _prefs.setStringList(_kAllowDomainsKey, _allowDomains.toList());
    await _saveBlockDomains();
    await syncToNative();
  }

  Future<void> removeAllowDomain(String domain) async {
    _allowDomains.remove(domain);
    await _prefs.setStringList(_kAllowDomainsKey, _allowDomains.toList());
    await syncToNative();
  }

  // ---------- 订阅更新 ----------

  Future<String> updateSubscriptions() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final merged = <String>{};
    var successCount = 0;
    for (final sub in _subscriptions) {
      if (!sub.enabled || sub.url.isEmpty) continue;
      // 主源失败时自动回退到国内镜像
      final urls = [sub.url, if (sub.mirror != null) sub.mirror!];
      String? fetched;
      for (final url in urls) {
        try {
          final req = await client.getUrl(Uri.parse(url));
          final res = await req.close();
          if (res.statusCode != 200) continue;
          final body = await res.transform(utf8.decoder).join();
          fetched = body;
          break;
        } catch (_) {
          continue;
        }
      }
      if (fetched != null) {
        merged.addAll(parseHostsList(fetched));
        successCount++;
      }
    }
    client.close();
    if (merged.isEmpty) {
      return "订阅更新失败或无有效数据，已保留当前规则";
    }
    _blockDomains = merged.difference(_allowDomains);
    await _saveBlockDomains();
    await _prefs.setInt(
        _kLastUpdateKey, DateTime.now().millisecondsSinceEpoch);
    await syncToNative();
    return "更新完成（$successCount 个订阅源成功），共 ${_blockDomains.length} 条规则";
  }

  // ---------- 与原生层同步 ----------

  /// 把合并后的规则写入应用支持目录（安卓上即 filesDir），并通知原生服务重载。
  /// 注意：不用 getApplicationDocumentsDirectory，因为安卓上它是 filesDir/app_flutter，
  /// 与 Kotlin 侧 context.filesDir 不一致。
  Future<bool> syncToNative() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File("${dir.path}/blocklist.txt");
      final buffer = StringBuffer();
      buffer.writeln("# AdShield blocklist - do not edit manually");
      buffer.writeln("# generated: ${DateTime.now().toIso8601String()}");
      for (final d in _blockDomains) {
        buffer.writeln(d);
      }
      await file.writeAsString(buffer.toString(), flush: true);
      final allowFile = File("${dir.path}/allowlist.txt");
      await allowFile.writeAsString(_allowDomains.join("\n"), flush: true);
      // 原生层配置（上游 DNS 等）
      final configFile = File("${dir.path}/config.json");
      await configFile.writeAsString(
        jsonEncode({
          "upstreamDns": _prefs.getString("upstream_dns") ?? "223.5.5.5",
        }),
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
