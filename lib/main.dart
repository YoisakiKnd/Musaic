import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_tokens.dart';
import 'app/router.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MusaicApp()));
}

class MusaicApp extends ConsumerWidget {
  const MusaicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'Musaic',
      debugShowCheckedModeBanner: false,
      theme: AppTokens.lightTheme,
      darkTheme: AppTokens.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
