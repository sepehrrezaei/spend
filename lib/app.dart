import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/platform.dart';
import 'core/providers.dart';
import 'core/theme/app_theme.dart';
import 'features/budgets/budgets_screen.dart';
import 'features/chat/chat_screen.dart';
import 'features/dashboard/dashboard_screen.dart';
import 'features/entry/entry_screen.dart';
import 'features/insights/insights_screen.dart';
import 'features/quick_add/desktop_integration.dart';
import 'features/settings/settings_screen.dart';
import 'features/shell/app_shell.dart';
import 'features/transactions/transactions_screen.dart';

/// The app's destinations, in the order they appear in the navigation rail.
///
/// Declared once and used to build both the router and the rail, so the two
/// cannot drift out of sync.
enum AppDestination {
  dashboard('/dashboard', 'Overview', Icons.pie_chart_outline, Icons.pie_chart),
  entry('/add', 'Add', Icons.add_circle_outline, Icons.add_circle),
  transactions(
    '/transactions',
    'History',
    Icons.receipt_long_outlined,
    Icons.receipt_long,
  ),
  budgets('/budgets', 'Budgets', Icons.savings_outlined, Icons.savings),
  insights('/insights', 'Insights', Icons.lightbulb_outline, Icons.lightbulb),
  chat('/ask', 'Ask', Icons.chat_bubble_outline, Icons.chat_bubble),
  settings('/settings', 'Settings', Icons.settings_outlined, Icons.settings);

  const AppDestination(this.path, this.label, this.icon, this.selectedIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Whether this destination exists on the current platform.
  bool get isAvailable => switch (this) {
    // Chat needs a local model, which only exists on desktop. Everything
    // else works everywhere.
    AppDestination.chat => AppPlatform.supportsLocalAi,
    _ => true,
  };

  /// The destinations to build, in order.
  ///
  /// Both the router's branches and the navigation bar are built from this one
  /// list, so their indices cannot drift apart when a destination is hidden.
  static List<AppDestination> get available =>
      values.where((d) => d.isAvailable).toList(growable: false);
}

final _routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppDestination.dashboard.path,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          for (final d in AppDestination.available)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: d.path,
                  builder: (context, state) => switch (d) {
                    AppDestination.dashboard => const DashboardScreen(),
                    AppDestination.entry => const EntryScreen(),
                    AppDestination.transactions => const TransactionsScreen(),
                    AppDestination.budgets => const BudgetsScreen(),
                    AppDestination.insights => const InsightsScreen(),
                    AppDestination.chat => const ChatScreen(),
                    AppDestination.settings => const SettingsScreen(),
                  },
                ),
              ],
            ),
        ],
      ),
    ],
  );
});

class SpendApp extends ConsumerStatefulWidget {
  const SpendApp({super.key});

  @override
  ConsumerState<SpendApp> createState() => _SpendAppState();
}

class _SpendAppState extends ConsumerState<SpendApp> {
  DesktopIntegration? _desktop;

  @override
  void initState() {
    super.initState();

    if (AppPlatform.supportsMenuBar) {
      _desktop = DesktopIntegration(
        onQuickAdd: _openQuickAdd,
        onShowMain: _openMainWindow,
      )..initialise();
    }

    // Take a snapshot on launch if one is due. Fire and forget: it is a safety
    // net, and the app must start whether or not it succeeds.
    Future.microtask(() async {
      // Resolve the version first, otherwise the snapshot is stamped
      // "unknown" — backupServiceProvider reads it synchronously and the
      // package-info future has not completed this early in startup.
      await ref.read(appVersionProvider.future);
      if (!mounted) return;
      await ref.read(autoBackupProvider).snapshotIfDue();
    });
  }

  @override
  void dispose() {
    _desktop?.dispose();
    super.dispose();
  }

  Future<void> _openQuickAdd() async {
    ref.read(quickAddModeProvider.notifier).enter();
    await WindowModes.enterCompact();
  }

  Future<void> _openMainWindow() async {
    ref.read(quickAddModeProvider.notifier).exit();
    await WindowModes.showNormal();
  }

  @override
  Widget build(BuildContext context) {
    // The capture panel is swapped in inside AppShell rather than replacing
    // the router here. Nesting a second Router under MaterialApp.home would
    // give the app two Navigators, and dialogs would resolve against the wrong
    // one.
    return MaterialApp.router(
      title: 'Spend',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(_routerProvider),
    );
  }
}
