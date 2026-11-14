import "package:flutter/material.dart";
import "package:provider/provider.dart";

import "services/app_state.dart";
import "screens/home_shell.dart";

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AdShieldApp());
}

class AdShieldApp extends StatelessWidget {
  const AdShieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: MaterialApp(
        title: "AdShield 广告拦截",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0)),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF1565C0),
            brightness: Brightness.dark,
          ),
          brightness: Brightness.dark,
        ),
        home: const HomeShell(),
      ),
    );
  }
}
