import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../services/app_state.dart";

/// 统计页：拦截概览 + 近 7 日简易柱状图（本地持久化数据）。
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final stats = app.stats;
    final history = _readHistory(app);

    return Scaffold(
      appBar: AppBar(
        title: const Text("统计"),
        actions: [
          IconButton(
            tooltip: "清空历史",
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _clearHistory(app),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              _bigCard(context, "今日拦截", "${stats.blockedToday}",
                  Colors.red.shade400, Icons.block),
              const SizedBox(width: 12),
              _bigCard(context, "今日放行", "${stats.allowedToday}",
                  Colors.blue.shade400, Icons.check_circle_outline),
            ],
          ),
          const SizedBox(height: 12),
          _bigCard(context, "累计拦截", "${stats.totalBlocked}",
              Colors.orange.shade400, Icons.history),
          const SizedBox(height: 24),
          Text("近 7 日拦截趋势", style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                height: 160,
                child: _BarChart(history),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigCard(
      BuildContext context, String label, String value, Color color, IconData icon) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(icon, color: color),
              const SizedBox(height: 8),
              Text(value,
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  /// 从 AppState 读近 7 日历史（AppState 持久化 stats_history）
  List<MapEntry<String, int>> _readHistory(AppState app) {
    final raw = app.statsHistory;
    return raw.entries
        .map((e) => MapEntry(e.key, e.value))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
  }

  Future<void> _clearHistory(AppState app) async {
    await app.clearHistory();
    if (mounted) setState(() {});
  }
}

/// 极简柱状图（无第三方图表依赖）。
class _BarChart extends StatelessWidget {
  final List<MapEntry<String, int>> data;
  const _BarChart(this.data);

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const Center(child: Text("暂无历史数据"));
    }
    final maxV = data.map((e) => e.value).fold(1, (a, b) => a > b ? a : b);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (final e in data)
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text("${e.value}",
                    style: const TextStyle(fontSize: 10)),
                const SizedBox(height: 4),
                Flexible(
                  child: FractionallySizedBox(
                    heightFactor: e.value / maxV,
                    child: Container(
                      width: 22,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(6)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(e.key.substring(5), style: const TextStyle(fontSize: 10)),
              ],
            ),
          ),
      ],
    );
  }
}
