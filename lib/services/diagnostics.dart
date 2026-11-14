import "dart:io";

import "package:flutter/foundation.dart";
import "package:path_provider/path_provider.dart";

/// 轻量诊断日志：写入应用支持目录 diagnostics.log。
/// 崩溃/启动异常会被记录，并在下次启动时展示给用户（无需 adb）。
class Diagnostics {
  static const _maxBytes = 64 * 1024; // 超过 64KB 轮转覆盖

  static Future<File> _logFile() async {
    final dir = await getApplicationSupportDirectory();
    return File("${dir.path}/diagnostics.log");
  }

  static Future<void> log(String msg) async {
    try {
      final f = await _logFile();
      if (await f.exists() && await f.length() > _maxBytes) {
        await f.writeAsString("");
      }
      await f.writeAsString(
          "[${DateTime.now().toIso8601String()}] $msg\n",
          mode: FileMode.append);
    } catch (_) {}
  }

  /// 读取日志尾部（供界面展示/复制）。
  static Future<String> readTail([int maxChars = 2000]) async {
    try {
      final f = await _logFile();
      if (!await f.exists()) return "";
      final s = await f.readAsString();
      return s.length > maxChars ? s.substring(s.length - maxChars) : s;
    } catch (_) {
      return "";
    }
  }

  static Future<void> clear() async {
    try {
      final f = await _logFile();
      if (await f.exists()) await f.writeAsString("");
    } catch (_) {}
  }

  /// 安装全局异常钩子，在 main() 里调用。
  static void installHooks() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      log("FlutterError: ${details.exceptionAsString()}\n"
          "${details.stack?.toString() ?? ""}");
    };
  }
}
