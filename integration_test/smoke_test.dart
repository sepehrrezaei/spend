import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Proves the harness itself before anything is built on it: that this suite
/// runs inside a real app process with plugins registered, which is the whole
/// reason for it existing separately from `flutter test`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the integration harness has real plugins and a real disk', (
    tester,
  ) async {
    // path_provider is a platform channel. Under `flutter test` this throws,
    // which is why test/widget_test.dart stubs everything that touches it.
    final support = await getApplicationSupportDirectory();
    expect(support.existsSync(), isTrue);

    final probe = File('${support.path}/e2e-probe.txt');
    await probe.writeAsString('written by the integration harness');
    expect(await probe.readAsString(), contains('integration harness'));
    await probe.delete();
  });
}
