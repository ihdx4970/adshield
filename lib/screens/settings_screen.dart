import "package:flutter/material.dart";
import "package:provider/provider.dart";
import "package:shared_preferences/shared_preferences.dart";

import "../models/models.dart";
import "../services/app_state.dart";

/// 设置页：上游 DNS、订阅源管理、关于与平台说明。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _upstreamOptions = {
    "114.114.114.114": "114 DNS（国内）",
    "223.5.5.5": "阿里 DNS（国内）",
    "119.29.29.29": "腾讯 DNSPod（国内）",
    "8.8.8.8": "Google DNS（国际）",
    "1.1.1.1": "Cloudflare（国际）",
  };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final fold = app.fold;

    return Scaffold(
      appBar: AppBar(title: const Text("设置")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("上游 DNS 服务器",
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text("放行的域名将转发至该服务器解析"),
                  const SizedBox(height: 8),
                  _UpstreamPicker(app: app, options: _upstreamOptions),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("设备形态", style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.devices_fold),
                    title: const Text("折叠姿态"),
                    trailing: Text(switch (fold.posture) {
                      FoldPosture.halfOpened => "半开（桌面模式）",
                      FoldPosture.flat => "平铺展开",
                      FoldPosture.closed => "合上",
                      _ => "未知 / 普通",
                    }),
                  ),
                  const Text(
                    "本应用已适配折叠屏：展开态双栏布局、"
                    "半开态上下分区（铰链上方操作 / 下方浏览）、"
                    "合上态等同普通手机界面。",
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("平台说明", style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  const Text(
                    "· 安卓：通过本地 VPN 在隧道层过滤广告域名，"
                    "无需 Root，首次开启需授予 VPN 权限。\n"
                    "· iOS：受系统限制，通过 DNS 配置进行过滤"
                    "（对 Safari 及使用系统 DNS 的应用生效），"
                    "完整隧道过滤需安装 Network Extension 能力。\n"
                    "· 拦截方式为 DNS 解析层过滤，无法拦截已内置"
                    "且不走域名解析的广告位。",
                    style: TextStyle(fontSize: 12, height: 1.6),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UpstreamPicker extends StatefulWidget {
  final AppState app;
  final Map<String, String> options;
  const _UpstreamPicker({required this.app, required this.options});

  @override
  State<_UpstreamPicker> createState() => _UpstreamPickerState();
}

class _UpstreamPickerState extends State<_UpstreamPicker> {
  String? _current;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _current = prefs.getString("upstream_dns") ?? "223.5.5.5");
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final e in widget.options.entries)
          RadioListTile<String>(
            dense: true,
            value: e.key,
            groupValue: _current,
            title: Text(e.value),
            subtitle: Text(e.key),
            onChanged: (v) async {
              setState(() => _current = v);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString("upstream_dns", v!);
              await widget.app.reloadRules();
            },
          ),
      ],
    );
  }
}
