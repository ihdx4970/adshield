import "dart:async";

import "package:flutter/services.dart";

import "../models/models.dart";

/// 与原生层（安卓 VPN 服务 / iOS DNS 配置）通信的唯一通道。
class NativeBridge {
  static const _method = MethodChannel("adshield/native");
  static const _foldEvents = EventChannel("adshield/fold");

  NativeBridge._();
  static final NativeBridge instance = NativeBridge._();

  Stream<FoldState>? _foldStream;

  // ---------- VPN 引擎 ----------

  Future<bool> startEngine() async {
    try {
      return await _method.invokeMethod<bool>("startEngine") ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> stopEngine() async {
    try {
      return await _method.invokeMethod<bool>("stopEngine") ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<EngineStatus> getStatus() async {
    try {
      final s = await _method.invokeMethod<String>("getStatus") ?? "off";
      return EngineStatus.values.firstWhere(
        (e) => e.name == s,
        orElse: () => EngineStatus.off,
      );
    } on PlatformException {
      return EngineStatus.off;
    }
  }

  Future<Stats> getStats() async {
    try {
      final args = await _method
          .invokeMethod<Map<Object?, Object?>>("getStats");
      if (args == null) return Stats.empty;
      return Stats(
        blockedToday: (args["blockedToday"] as num?)?.toInt() ?? 0,
        allowedToday: (args["allowedToday"] as num?)?.toInt() ?? 0,
        totalBlocked: (args["totalBlocked"] as num?)?.toInt() ?? 0,
        updated: DateTime.now(),
      );
    } on PlatformException {
      return Stats.empty;
    }
  }

  /// 通知原生层重载规则文件（Dart 侧已把 blocklist.txt 写入应用文件目录）。
  Future<bool> reloadRules() async {
    try {
      return await _method.invokeMethod<bool>("reloadRules") ?? false;
    } on PlatformException {
      return false;
    }
  }

  // ---------- 折叠屏姿态 ----------

  Stream<FoldState> foldStateStream() {
    _foldStream ??= _foldEvents
        .receiveBroadcastStream()
        .map((event) => FoldState.fromNative(event as Map<Object?, Object?>?));
    return _foldStream!;
  }
}
