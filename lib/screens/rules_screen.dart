import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "../services/app_state.dart";

/// 规则页：订阅更新 + 白名单管理。
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  bool _updating = false;
  String? _result;

  Future<void> _updateSubs(AppState app) async {
    setState(() => _updating = true);
    final msg = await app.ruleService?.updateSubscriptions();
    setState(() {
      _updating = false;
      _result = msg ?? "更新失败";
    });
  }

  Future<void> _addAllowDomain(AppState app) async {
    final controller = TextEditingController();
    final domain = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("添加白名单域名"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: "例如: example.com",
            helperText: "该域名的请求将不再被拦截",
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("取消")),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text.trim().toLowerCase()),
              child: const Text("添加")),
        ],
      ),
    );
    if (domain != null && domain.isNotEmpty) {
      await app.ruleService?.addAllowDomain(domain);
      await app.reloadRules();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final rules = app.ruleService;

    return Scaffold(
      appBar: AppBar(title: const Text("规则")),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("广告域名规则库",
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text("已收录 ${rules?.blockCount ?? 0} 条拦截规则"),
                  if (rules?.lastUpdate != null)
                    Text(
                      "上次订阅更新：${rules!.lastUpdate!.toLocal().toString().substring(0, 16)}",
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _updating ? null : () => _updateSubs(app),
                        icon: _updating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : const Icon(Icons.cloud_download),
                        label: const Text("在线更新订阅"),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => app.reloadRules(),
                        icon: const Icon(Icons.refresh),
                        label: const Text("重载到拦截引擎"),
                      ),
                    ],
                  ),
                  if (_result != null) ...[
                    const SizedBox(height: 8),
                    Text(_result!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text("白名单"),
                  subtitle: Text("${rules?.allowDomains.length ?? 0} 个域名"),
                  trailing: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () => _addAllowDomain(app),
                  ),
                ),
                if ((rules?.allowDomains.length ?? 0) > 0)
                  const Divider(height: 1),
                for (final d in (rules?.allowDomains ?? {}))
                  ListTile(
                    dense: true,
                    title: Text(d),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () async {
                        await app.ruleService?.removeAllowDomain(d);
                        await app.reloadRules();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
