import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../services/app_state.dart";
import "home_screen.dart";
import "rules_screen.dart";
import "settings_screen.dart";
import "stats_screen.dart";

/// 自适应外壳 —— 折叠屏适配核心：
///
/// 1. 窄屏（手机 / 折叠态外屏，宽度 < 840）：底部导航栏；
/// 2. 宽屏（折叠机展开后的内屏 / 平板横屏，宽度 >= 840）：左侧 NavigationRail 双栏；
/// 3. 安卓折叠姿态为"半开"（HALF_OPENED）时：内容上下分区，
///    上半屏固定在铰链上方操作，下半屏浏览数据，符合桌面（Tabletop）模式交互。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    NavigationRailDestination(
      icon: Icon(Icons.shield_outlined),
      selectedIcon: Icon(Icons.shield),
      label: Text("拦截"),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.bar_chart_outlined),
      selectedIcon: Icon(Icons.bar_chart),
      label: Text("统计"),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.rule_outlined),
      selectedIcon: Icon(Icons.rule),
      label: Text("规则"),
    ),
    NavigationRailDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
      label: Text("设置"),
    ),
  ];

  static const _tabs = ["拦截", "统计", "规则", "设置"];

  Widget _page() => switch (_index) {
        0 => const HomeScreen(),
        1 => const StatsScreen(),
        2 => const RulesScreen(),
        _ => const SettingsScreen(),
      };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 840; // 展开态 / 平板
    final halfOpen = app.fold.isHalfOpened; // 半开桌面模式

    if (wide && !halfOpen) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: _destinations,
            ),
            const VerticalDivider(width: 1),
            Expanded(child: _page()),
          ],
        ),
      );
    }

    if (halfOpen) {
      // 半开模式：顶部导航 chips + 上下分区内容
      return Scaffold(
        appBar: AppBar(
          title: Text("AdShield · ${_tabs[_index]}"),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Chip(
                avatar: const Icon(Icons.table_restaurant, size: 16),
                label: const Text("桌面模式"),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  for (var i = 0; i < _tabs.length; i++)
                    ChoiceChip(
                      label: Text(_tabs[i]),
                      selected: _index == i,
                      onSelected: (_) => setState(() => _index = i),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _page()),
          ],
        ),
      );
    }

    // 常规窄屏：底部导航
    return Scaffold(
      body: _page(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: d.icon,
              selectedIcon: d.selectedIcon,
              label: (d.label as Text).data ?? "",
            ),
        ],
      ),
    );
  }
}
