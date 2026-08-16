import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'inspector_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const RecompositionInspectorApp());
}

class RecompositionInspectorApp extends StatelessWidget {
  const RecompositionInspectorApp({
    super.key,
    this.client,
    this.enablePreview = true,
  });

  final InspectorClient? client;
  final bool enablePreview;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF06080A);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFF5A624),
      brightness: Brightness.dark,
      surface: const Color(0xFF0C1013),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Recomposition Viewer',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        fontFamily: 'Sora',
        dividerColor: const Color(0x14FFFFFF),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0x0DFFFFFF),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x24FFFFFF)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0x24FFFFFF)),
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF0C1013),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0x14FFFFFF)),
          ),
        ),
      ),
      home: InspectorPage(client: client, enablePreview: enablePreview),
    );
  }
}
