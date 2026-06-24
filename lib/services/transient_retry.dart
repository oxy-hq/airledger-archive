/// Retries [action] when it fails with a transient cold-start network
/// error and rethrows anything else immediately.
///
/// Why this exists: on Android the first frames after launch often run
/// before the radio has a route + working DNS. The Rust engine's first
/// request then fails with "error sending request for url: failed to look
/// up address information: no address associated with hostname". A manual
/// refresh a moment later succeeds because the network has since come up.
///
/// The pure-Dart [SheetsRepository] handles this with a retrying
/// `http.Client`, but the engine path makes its requests inside Rust
/// (reqwest), out of reach of a Dart client wrapper — so we retry at the
/// call site instead. A few short backoffs cover the cold-start window.
Future<T> retryTransient<T>(
  Future<T> Function() action, {
  int attempts = 5,
  Duration delay = const Duration(milliseconds: 600),
}) async {
  for (var i = 0;; i++) {
    try {
      return await action();
    } catch (e) {
      if (i >= attempts - 1 || !isTransientNetworkError(e)) rethrow;
      await Future<void>.delayed(delay);
    }
  }
}

/// True if [e]'s message looks like a transient connectivity failure
/// (DNS not ready, connection abort/reset/refused, TLS handshake race,
/// timeout). Matched on the stringified error so it works regardless of
/// the exception type the engine or http stack throws.
bool isTransientNetworkError(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('failed to look up address') ||
      s.contains('no address associated with hostname') ||
      s.contains('temporary failure in name resolution') ||
      s.contains('dns error') ||
      s.contains('error sending request') ||
      s.contains('connection abort') ||
      s.contains('connection reset') ||
      s.contains('connection refused') ||
      s.contains('connection closed') ||
      s.contains('handshake') ||
      s.contains('timed out') ||
      s.contains('network is unreachable');
}
