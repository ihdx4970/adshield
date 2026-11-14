import "dart:async";

import "package:shared_preferences/shared_preferences.dart";

import "../models/models.dart";
import "native_bridge.dart";

/// 统计服务：轮询原生层的拦截计数并持久化最近一次数值。
class StatsService {
  final SharedPreferences _prefs;
  Timer? _timer;

  StatsService(this._prefs);

  static Future<StatsService> load() async {
    final prefs = await SharedPreferences.getInstance();
    return StatsService(prefs);
  }

  Future<Stats> fetch() async {
    final s = await NativeBridge.instance.getStats();
    await _prefs.setInt("stats_blocked_today", s.blockedToday);
    await _prefs.setInt("stats_total_blocked", s.totalBlocked);
    return s;
  }

  /// 开始每 2 秒轮询（VPN 运行时调用）。
  void startPolling(Function(Stats) onUpdate) {
    stopPolling();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      onUpdate(await fetch());
    });
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  // ---------- 每日历史 ----------

  /// 记录某天的累计拦截数（当日数据实时覆盖写入）。
  Future<void> recordDaily(String day, int blocked) async {
    if (_prefs.getInt("hist_$day") == blocked) return;
    await _prefs.setInt("hist_$day", blocked);
    // 清理 30 天前的历史，避免无限增长
    final cutoff = DateTime.now()
        .subtract(const Duration(days: 30))
        .toIso8601String()
        .substring(0, 10);
    for (final key in _prefs.getKeys()) {
      if (key.startsWith("hist_") &&
          key.substring(5).compareTo(cutoff) < 0) {
        await _prefs.remove(key);
      }
    }
  }

  /// 读取最近 n 天历史（含今天），按日期升序返回。
  Map<String, int> readLastDays(int n) {
    final result = <String, int>{};
    final now = DateTime.now();
    for (var i = n - 1; i >= 0; i--) {
      final day = now.subtract(Duration(days: i)).toIso8601String().substring(0, 10);
      final v = _prefs.getInt("hist_$day") ?? 0;
      result[day] = v;
    }
    return result;
  }

  Future<void> clearHistory() async {
    for (final key in _prefs.getKeys().where((k) => k.startsWith("hist_"))) {
      await _prefs.remove(key);
    }
  }
}
