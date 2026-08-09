/// The one place that decides whether an address is allowed to be contacted.
///
/// The whole premise of the AI features is that nothing leaves the machine, and
/// a text field in Settings is not a guarantee — the value is persisted, can be
/// restored from a backup written elsewhere, and is read straight into an HTTP
/// request. Ollama also has no authentication, so a host that resolved to a
/// remote machine would be both a data leak and an open door.
///
/// So the check lives at the network boundary, where every request must pass
/// it, rather than in the form that happens to set the value.
library;

/// Validates and normalises a user-supplied local service address.
abstract final class LocalEndpoint {
  /// Loopback names and addresses, in the forms a person actually types.
  ///
  /// `localhost` is included deliberately: it is resolved by the OS, and on
  /// every supported platform it resolves to loopback. Excluding it would
  /// reject the address printed by Ollama's own installer.
  static const _names = {'localhost', '127.0.0.1', '::1'};

  /// Parses [raw] into a base URI, or returns `null` when it is not a local
  /// address the app is willing to talk to.
  ///
  /// Any path, query or fragment is dropped: callers append their own paths,
  /// and carrying `/api/tags` through into `'$host/api/chat'` would produce
  /// nonsense URLs. Credentials are rejected rather than stripped — their
  /// presence means the address was meant for something this is not.
  static Uri? tryParse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;

    // A bare "127.0.0.1:11434" parses as scheme "127.0.0.1", so give a
    // scheme-less address the default before parsing rather than after.
    final withScheme = text.contains('://') ? text : 'http://$text';

    final uri = Uri.tryParse(withScheme);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (!isLoopbackHost(uri.host)) return null;

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : 11434,
    );
  }

  /// Whether [host] names this machine.
  ///
  /// Covers the whole 127.0.0.0/8 block, not just 127.0.0.1 — every address in
  /// it is loopback, and 127.0.0.2 is a legitimate way to bind a second local
  /// service.
  static bool isLoopbackHost(String host) {
    final h = host.toLowerCase();
    if (_names.contains(h)) return true;

    final octets = h.split('.');
    if (octets.length != 4) return false;
    final parsed = [for (final o in octets) int.tryParse(o)];
    if (parsed.any((o) => o == null || o < 0 || o > 255)) return false;
    return parsed.first == 127;
  }

  /// Why [raw] was refused, phrased for the user. `null` when it is fine.
  static String? describeProblem(String raw) {
    if (raw.trim().isEmpty) return 'Enter an address.';
    return tryParse(raw) == null
        ? 'Only addresses on this machine are allowed — localhost, 127.0.0.1 '
              'or ::1, optionally with a port.'
        : null;
  }
}
