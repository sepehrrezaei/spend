import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app.dart';
import '../../core/platform.dart';
import '../../core/providers.dart';
import '../quick_add/quick_add_panel.dart';

/// The persistent navigation chrome around every screen.
///
/// This widget is the *only* place the app branches on platform. Desktop gets
/// a always-visible navigation rail; a phone gets a bottom bar. Every feature
/// screen below is written once and is unaware of which it is inside, which is
/// what makes the eventual iOS build a rebuild rather than a rewrite.
class AppShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const AppShell({required this.navigationShell, super.key});

  void _go(int index) => navigationShell.goBranch(
    index,
    // Tapping the current destination returns to that branch's root rather
    // than doing nothing, matching how native tab bars behave.
    initialLocation: index == navigationShell.currentIndex,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The compact capture panel replaces the whole shell rather than sitting
    // on top of it, so the window can shrink to 460x300 without the rail and
    // dashboard trying to lay out in that space.
    if (ref.watch(quickAddModeProvider)) return const QuickAddPanel();

    final destinations = AppDestination.available;

    if (!AppPlatform.isDesktop) {
      return Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _go,
          destinations: [
            for (final d in destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Shortcuts(
      shortcuts: {
        // Cmd+1..9 jumps straight to a destination, the way a Mac app should.
        // Bounded by the key list as well as the destinations, so adding a
        // tenth screen degrades to "no shortcut" rather than crashing.
        for (var i = 0; i < destinations.length && i < _digitKeys.length; i++)
          SingleActivator(_digitKeys[i], meta: true): _GoToBranchIntent(i),
        // Resolved against the filtered list, not the enum's declaration
        // index — those only coincide while nothing before Add is hidden.
        SingleActivator(LogicalKeyboardKey.keyN, meta: true): _GoToBranchIntent(
          destinations.indexOf(AppDestination.entry),
        ),
      },
      child: Actions(
        actions: {
          _GoToBranchIntent: CallbackAction<_GoToBranchIntent>(
            onInvoke: (intent) {
              _go(intent.index);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: navigationShell.currentIndex,
                  onDestinationSelected: _go,
                  leading: const _RailHeader(),
                  destinations: [
                    for (final d in destinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: navigationShell),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const _digitKeys = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
  LogicalKeyboardKey.digit6,
  LogicalKeyboardKey.digit7,
  LogicalKeyboardKey.digit8,
  LogicalKeyboardKey.digit9,
];

class _GoToBranchIntent extends Intent {
  final int index;
  const _GoToBranchIntent(this.index);
}

class _RailHeader extends StatelessWidget {
  const _RailHeader();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // Leaves room for the traffic-light window buttons above the rail.
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Icon(
        Icons.account_balance_wallet,
        color: scheme.primary,
        size: 26,
      ),
    );
  }
}
