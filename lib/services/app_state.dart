import "dart:async";

import "package:flutter/foundation.dart";

import "../models/models.dart";
import "native_bridge.dart";
import "rule_service.dart";
import "stats_service.dart";

/// 全局应用状态：引擎开关、统计、折叠姿态、规则库。
class AppState extends ChangeNotifier {
  final NativeBridge _native = NativeBridge.instance;

  EngineStatus engineStatus = EngineStatus.off;
  Stats stats = Stats.empty;
  FoldState fold = const FoldState();
  RuleService? ruleService;
  StatsService? statsService;
  String? lastMessage;

  StreamSubscription<FoldState>? _foldSub;
  bool _initializing = false;

  Future<void> init() async {
    if (_initializing) return;
    _initializing = true;
    try {
      ruleService = await RuleService.load();
      statsService = await StatsService.load();
      await ruleService!.syncToNative();
      engineStatus = await _native.getStatus();
      stats = await statsService!.fetch();
      if (engineStatus == EngineStatus.running) {
        statsService!.startPolling(_onStats);
      }
      _foldSub = _native.foldStateStream().listen((f) {
        fold = f;
        notifyListeners();
      });
      notifyListeners();
    } finally {
      _initializing = false;
    }
  }

  void _onStats(Stats s) {
    stats = s;
    _recordHistory(s.blockedToday);
    notifyListeners();
  }

  /// 按日期持久化拦截历史（近 7 日趋势图数据源）。
  void _recordHistory(int blockedToday) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final service = statsService;
    if (service == null) return;
    service.recordDaily(today, blockedToday);
  }

  Map<String, int> get statsHistory => statsService?.readLastDays(7) ?? {};

  Future<void> clearHistory() async {
    await statsService?.clearHistory();
    notifyListeners();
  }

  Future<void> toggleEngine() async {
    if (engineStatus == EngineStatus.running) {
      engineStatus = EngineStatus.stopping;
      notifyListeners();
      final ok = await _native.stopEngine();
      engineStatus = ok ? EngineStatus.off : EngineStatus.running;
      statsService?.stopPolling();
    } else {
      engineStatus = EngineStatus.starting;
      notifyListeners();
      // 打开前同步一次规则，保证 VPN 服务拿到最新域名表
      await ruleService?.syncToNative();
      final ok = await _native.startEngine();
      if (ok) {
        engineStatus = EngineStatus.running;
        statsService?.startPolling(_onStats);
      } else {
        engineStatus = EngineStatus.off;
        lastMessage = "启动失败：请检查是否授予 VPN 权限（安卓）";
      }
    }
    notifyListeners();
  }

  Future<void> reloadRules() async {
    await ruleService?.syncToNative();
    final ok = await _native.reloadRules();
    lastMessage = ok ? "规则已重载（${ruleService?.blockCount ?? 0} 条）" : "规则重载失败";
    notifyListeners();
  }

  @override
  void dispose() {
    _foldSub?.cancel();
    statsService?.stopPolling();
    super.dispose();
  }
}
