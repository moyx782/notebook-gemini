import 'package:flutter/material.dart';

import 'state/notebook_controller.dart';
import 'ui/adaptive_notebook_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SyncCanvasApp());
}

class SyncCanvasApp extends StatefulWidget {
  const SyncCanvasApp({
    super.key,
    this.controller,
  });

  final NotebookController? controller;

  @override
  State<SyncCanvasApp> createState() => _SyncCanvasAppState();
}

class _SyncCanvasAppState extends State<SyncCanvasApp> {
  late final NotebookController _controller;
  late final bool _ownsController;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? NotebookController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final shortestSide = MediaQuery.sizeOf(context).shortestSide;
      _controller.initialize(shortestSideLogicalPixels: shortestSide);
    }
  }

  @override
  void dispose() {
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F46E5),
      brightness: Brightness.light,
      surface: const Color(0xFFF8FAFC),
    );

    return MaterialApp(
      title: 'SyncCanvas Notebook · 三端共享画板笔记',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF0F172A),
          elevation: 0,
        ),
      ),
      home: AdaptiveNotebookShell(controller: _controller),
    );
  }
}
