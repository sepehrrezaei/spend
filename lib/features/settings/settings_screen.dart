import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform.dart';
import '../../core/providers.dart';
import '../shell/content_width.dart';
import 'ai_section.dart';
import 'data_section.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// Currencies offered in the picker. Deliberately short — the app is
  /// single-currency by design, and this only changes how amounts are
  /// formatted, never converts anything.
  static const _currencies = ['EUR', 'GBP', 'USD', 'CHF', 'SEK', 'NOK', 'DKK'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final db = ref.watch(databaseProvider);
    final currency = ref.watch(currencyProvider).value ?? 'EUR';
    final themeMode = ref.watch(themeModeSettingProvider).value ?? 'system';
    final weekStart = ref.watch(weekStartsOnProvider);
    final version = ref.watch(appVersionProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), centerTitle: false),
      body: ContentWidth(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
          children: [
            Text('Appearance', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.brightness_6_outlined, size: 20),
                    title: const Text('Theme'),
                    trailing: SegmentedButton<String>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      segments: const [
                        ButtonSegment(value: 'system', label: Text('Auto')),
                        ButtonSegment(value: 'light', label: Text('Light')),
                        ButtonSegment(value: 'dark', label: Text('Dark')),
                      ],
                      selected: {themeMode},
                      onSelectionChanged: (s) =>
                          db.setSetting(SettingKeys.themeMode, s.first),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.euro_symbol, size: 20),
                    title: const Text('Currency'),
                    subtitle: const Text(
                      'Formatting only — amounts are never converted',
                    ),
                    trailing: DropdownButton<String>(
                      value: _currencies.contains(currency) ? currency : 'EUR',
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final c in _currencies)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) => v == null
                          ? null
                          : db.setSetting(SettingKeys.currency, v),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.calendar_view_week, size: 20),
                    title: const Text('Week starts on'),
                    trailing: DropdownButton<int>(
                      value: weekStart,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: DateTime.monday,
                          child: Text('Monday'),
                        ),
                        DropdownMenuItem(
                          value: DateTime.sunday,
                          child: Text('Sunday'),
                        ),
                        DropdownMenuItem(
                          value: DateTime.saturday,
                          child: Text('Saturday'),
                        ),
                      ],
                      onChanged: (v) => v == null
                          ? null
                          : db.setSetting(SettingKeys.weekStartsOn, '$v'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            const DataSection(),
            const SizedBox(height: 22),
            // No local model is reachable from a phone or tablet, so there is
            // nothing here to configure.
            if (AppPlatform.supportsLocalAi) ...[
              const AiSection(),
              const SizedBox(height: 22),
            ],
            Text('About', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Spend${version == null ? "" : " $version"}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Everything is stored in a single SQLite file on this '
                      'Mac. Nothing is sent anywhere.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
