/// 核心数据模型。
library;

/// VPN / 拦截引擎运行状态。
enum EngineStatus { off, starting, running, stopping, error }

/// 折叠屏折叠姿态（安卓 Jetpack WindowManager 上报）。
enum FoldPosture {
  /// 平铺（完全展开或普通手机）。
  flat,

  /// 半开（类似笔记本桌面模式），布局需要上下分区。
  halfOpened,

  /// 完全合上，外屏模式（等同普通手机窄屏）。
  closed,

  /// 未知 / 非 Android 平台。
  unknown,
}

/// 折叠铰链方向。
enum FoldHingeOrientation { horizontal, vertical, none }

/// 折叠屏状态快照。
class FoldState {
  final FoldPosture posture;
  final FoldHingeOrientation hingeOrientation;

  const FoldState({
    this.posture = FoldPosture.unknown,
    this.hingeOrientation = FoldHingeOrientation.none,
  });

  bool get isHalfOpened => posture == FoldPosture.halfOpened;

  /// 展开为大屏（宽度足够容纳双栏）。
  bool get isBookLike => posture == FoldPosture.flat;

  FoldState copyWith({
    FoldPosture? posture,
    FoldHingeOrientation? hingeOrientation,
  }) {
    return FoldState(
      posture: posture ?? this.posture,
      hingeOrientation: hingeOrientation ?? this.hingeOrientation,
    );
  }

  static FoldState fromNative(Map<Object?, Object?>? args) {
    final p = switch (args?["posture"] as String?) {
      "flat" => FoldPosture.flat,
      "halfOpened" => FoldPosture.halfOpened,
      "closed" => FoldPosture.closed,
      _ => FoldPosture.unknown,
    };
    final o = switch (args?["hingeOrientation"] as String?) {
      "horizontal" => FoldHingeOrientation.horizontal,
      "vertical" => FoldHingeOrientation.vertical,
      _ => FoldHingeOrientation.none,
    };
    return FoldState(posture: p, hingeOrientation: o);
  }
}

/// 拦截统计。
class Stats {
  final int blockedToday;
  final int allowedToday;
  final int totalBlocked;
  final DateTime? updated;

  const Stats({
    required this.blockedToday,
    required this.allowedToday,
    required this.totalBlocked,
    this.updated,
  });

  static const empty = Stats(
    blockedToday: 0,
    allowedToday: 0,
    totalBlocked: 0,
    updated: null,
  );

  Stats fromNative(Map<Object?, Object?> args) => Stats(
        blockedToday: (args["blockedToday"] as num?)?.toInt() ?? 0,
        allowedToday: (args["allowedToday"] as num?)?.toInt() ?? 0,
        totalBlocked: (args["totalBlocked"] as num?)?.toInt() ?? 0,
        updated: DateTime.now(),
      );
}

/// 规则订阅源（url 为主源，mirror 为国内镜像回退，两者内容相同）。
class RuleSubscription {
  final String name;
  final String url;
  final String? mirror;
  final bool enabled;

  const RuleSubscription({
    required this.name,
    required this.url,
    this.mirror,
    this.enabled = true,
  });

  Map<String, Object> toJson() => {
        "name": name,
        "url": url,
        if (mirror != null) "mirror": mirror!,
        "enabled": enabled,
      };

  static RuleSubscription fromJson(Map<Object?, Object?> json) =>
      RuleSubscription(
        name: json["name"] as String? ?? "订阅",
        url: json["url"] as String? ?? "",
        mirror: json["mirror"] as String?,
        enabled: json["enabled"] as bool? ?? true,
      );
}
