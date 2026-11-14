import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../models/models.dart";
import "../services/app_state.dart";

/// 首页：拦截总开关 + 状态卡片。
/// 半开折叠模式下按铰链上下分区：上半屏放开关（好按压），下半屏放实时数据。
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final halfOpen = app.fold.isHalfOpened;
    final scheme = Theme.of(context).colorScheme;
    final running = app.engineStatus == EngineStatus.running;

    final toggleCard = Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              running ? Icons.shield : Icons.shield_outlined,
              size: 72,
              color: running ? scheme.primary : scheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              switch (app.engineStatus) {
                EngineStatus.running => "拦截运行中",
                EngineStatus.starting => "正在启动…",
                EngineStatus.stopping => "正在停止…",
                EngineStatus.error => "异常",
                EngineStatus.off => "已关闭",
              },
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 32, vertical: 14),
              ),
              icon: Icon(running ? Icons.stop : Icons.play_arrow),
              label: Text(running ? "停止拦截" : "开启拦截"),
              onPressed: app.engineStatus == EngineStatus.starting ||
                      app.engineStatus == EngineStatus.stopping
                  ? null
                  : () => app.toggleEngine(),
            ),
            if (app.lastMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                app.lastMessage!,
                style: TextStyle(color: scheme.error, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );

    final statusRows = Column(
      children: [
        _row("今日已拦截", "${app.stats.blockedToday} 次",
            Icons.block, scheme.error),
        _row("今日放行", "${app.stats.allowedToday} 次",
            Icons.check_circle_outline, scheme.primary),
        _row("累计拦截", "${app.stats.totalBlocked} 次",
            Icons.history, scheme.secondary),
        _row("规则数量", "${app.ruleService?.blockCount ?? 0} 条",
            Icons.rule, scheme.tertiary),
        _row(
          "当前形态",
          switch (app.fold.posture) {
            FoldPosture.halfOpened => "折叠 · 半开（桌面模式）",
            FoldPosture.flat => "展开",
            FoldPosture.closed => "合上（外屏）",
            _ => "普通手机",
          },
          Icons.devices_fold,
          scheme.primary,
        ),
      ],
    );

    if (halfOpen) {
      // 桌面模式：开关固定在上方屏幕，数据在下方屏幕
      return Scaffold(
        body: Column(
          children: [
            Expanded(child: Center(child: toggleCard)),
            const Divider(height: 1),
            Expanded(child: Center(child: statusRows)),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("AdShield 广告拦截")),
      body: ListView(
        children: [
          Center(child: toggleCard),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(child: Padding(padding: const EdgeInsets.all(8), child: statusRows)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _row(String label, String value, IconData icon, Color color) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label),
      trailing: Text(value,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      dense: true,
    );
  }
}
