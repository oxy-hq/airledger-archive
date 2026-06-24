/// QuickBooks Online integration config — sourced from the schemas repo's
/// `config.yml` `quickbooks:` block and resolved at build time by
/// `tool/build_config.dart` (any `*_var` key is replaced from `.env`, so
/// `client_id_var: QBO_CLIENT_ID` becomes `client_id: <value>`).
///
/// QBO is a **state target layered above the ledger**, not a datasource:
/// transactions still live in their view's ledger (Sheets or sqlite); the
/// "Update" button pushes each not-yet-pushed transaction to QBO as an
/// inventory-quantity change. Per-view mapping lives here (keyed by view
/// name) rather than on the `.view.yml` because views are parsed by the
/// Rust engine, which doesn't know this app-specific field.
///
/// Optional. When absent, the QBO Update button + status badges stay inert.
class QuickBooksConfig {
  /// `sandbox` (default) or `production` — selects the API base host.
  final String environment;
  final String realmId;
  final String clientId;
  final String clientSecret;

  /// The refresh token to bootstrap from on first run (minted once via
  /// Intuit's OAuth Playground). After the first refresh the app stores
  /// and rotates its own; this seed is only used when the token store is
  /// empty. See [QboTokenStore].
  final String? seedRefreshToken;

  /// Per-view push mappings, keyed by view name.
  final Map<String, QboPushSpec> specsByView;

  const QuickBooksConfig({
    required this.environment,
    required this.realmId,
    required this.clientId,
    required this.clientSecret,
    this.seedRefreshToken,
    this.specsByView = const {},
  });

  bool get isSandbox => environment != 'production';

  /// Accounting API base. Sandbox and production are separate companies.
  String get apiBase => isSandbox
      ? 'https://sandbox-quickbooks.api.intuit.com'
      : 'https://quickbooks.api.intuit.com';

  /// OAuth2 token endpoint (same for sandbox + production).
  static const tokenEndpoint =
      'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';

  QboPushSpec? specFor(String viewName) => specsByView[viewName];

  /// Parses a `quickbooks:` block. [m] may be a `YamlMap` or plain `Map`
  /// (both support `[]`); nested entries are read via dynamic indexing.
  static QuickBooksConfig fromYaml(Map<dynamic, dynamic> m) {
    String? str(String k) => m[k]?.toString();

    final realmId = str('realm_id');
    final clientId = str('client_id');
    final clientSecret = str('client_secret');
    if (realmId == null || realmId.isEmpty) {
      throw const FormatException(
        'quickbooks.realm_id missing (set realm_id_var: QBO_REALM_ID)',
      );
    }
    if (clientId == null || clientSecret == null) {
      throw const FormatException(
        'quickbooks.client_id and client_secret are required '
        '(set client_id_var / client_secret_var)',
      );
    }

    final specs = <String, QboPushSpec>{};
    final viewsNode = m['views'];
    if (viewsNode is Iterable) {
      for (final entry in viewsNode) {
        if (entry is Map) {
          final spec = QboPushSpec.fromYaml(entry);
          specs[spec.view] = spec;
        }
      }
    }

    return QuickBooksConfig(
      environment: (str('environment') ?? 'sandbox').toLowerCase(),
      realmId: realmId,
      clientId: clientId,
      clientSecret: clientSecret,
      seedRefreshToken: str('refresh_token'),
      specsByView: specs,
    );
  }
}

/// How one view's transactions map to a QBO inventory-quantity change.
///
/// Each transaction names an item (via [skuDimension], matched against the
/// QBO Item's `Name`) and a quantity (via [qtyDimension]). [increase]
/// decides the sign: an `increase` view adds the quantity to QtyOnHand
/// (stock received); a `decrease` view subtracts it (stock sold/used).
class QboPushSpec {
  final String view;
  final String skuDimension;
  final String qtyDimension;
  final bool increase;

  const QboPushSpec({
    required this.view,
    required this.skuDimension,
    required this.qtyDimension,
    required this.increase,
  });

  /// Signed delta to apply to QtyOnHand for a row whose quantity is [qty].
  double signedDelta(num qty) => increase ? qty.toDouble() : -qty.toDouble();

  static QboPushSpec fromYaml(Map<dynamic, dynamic> m) {
    final view = m['view']?.toString();
    final sku = m['sku_dimension']?.toString();
    final qty = m['qty_dimension']?.toString();
    if (view == null || sku == null || qty == null) {
      throw const FormatException(
        'quickbooks.views[] entries require view, sku_dimension, '
        'qty_dimension',
      );
    }
    final dir = (m['direction']?.toString() ?? 'decrease').toLowerCase();
    return QboPushSpec(
      view: view,
      skuDimension: sku,
      qtyDimension: qty,
      increase: dir == 'increase',
    );
  }
}
