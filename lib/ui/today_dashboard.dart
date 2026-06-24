import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/quickbooks_config.dart';
import '../models/view_schema.dart';
import '../services/connector_registry.dart';
import '../services/icon_resolver.dart';
import '../services/qbo_service.dart';
import '../services/warehouse_connector.dart';
import 'timeline_screen.dart';

/// Compact "today" summary band shown at the top of the home screen.
///
/// For each view with a `date_field`, fetches today's rows in parallel
/// and displays a small pill: icon + count. Tapping a pill drills into
/// that view's timeline (already date-filters to today by default).
///
/// Loads independently of the bootstrap so the views list below it
/// renders immediately while counts populate in the background.
class TodayDashboard extends StatefulWidget {
  final List<ViewSchema> views;
  final ConnectorRegistry registry;

  /// QBO config + push service, threaded through so a QBO-mapped view
  /// opened from a pill still gets the Update button + badges. Null when
  /// the build has no `quickbooks:` block.
  final QuickBooksConfig? quickbooks;
  final QboService? qboService;

  const TodayDashboard({
    super.key,
    required this.views,
    required this.registry,
    this.quickbooks,
    this.qboService,
  });

  @override
  State<TodayDashboard> createState() => _TodayDashboardState();
}

class _TodayDashboardState extends State<TodayDashboard> {
  late Future<Map<String, int>> _counts;

  @override
  void initState() {
    super.initState();
    _counts = _fetchCounts();
  }

  Future<Map<String, int>> _fetchCounts() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final eligible =
        widget.views.where((v) => v.dateField != null).toList();
    final results = await Future.wait(
      eligible.map((v) => _countForView(v, today)),
    );
    return {
      for (var i = 0; i < eligible.length; i++) eligible[i].name: results[i],
    };
  }

  Future<int> _countForView(ViewSchema view, DateTime today) async {
    try {
      final rows =
          await widget.registry.forView(view).list(view, onDate: today);
      return rows.length;
    } catch (_) {
      return -1; // sentinel: failed to load
    }
  }

  @override
  Widget build(BuildContext context) {
    final eligible =
        widget.views.where((v) => v.dateField != null).toList();
    if (eligible.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final dateLabel = DateFormat('EEE, MMM d').format(DateTime.now());

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Today', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(dateLabel, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 10),
          FutureBuilder<Map<String, int>>(
            future: _counts,
            builder: (context, snap) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final view in eligible) ...[
                      _StatPill(
                        view: view,
                        count: snap.data?[view.name],
                        loading: !snap.hasData,
                        repository: widget.registry.forView(view),
                        qboSpec: widget.quickbooks?.specFor(view.name),
                        qboService:
                            widget.quickbooks?.specFor(view.name) == null
                                ? null
                                : widget.qboService,
                      ),
                      const SizedBox(width: 8),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final ViewSchema view;
  final int? count;
  final bool loading;
  final WarehouseConnector repository;
  final QboPushSpec? qboSpec;
  final QboService? qboService;

  const _StatPill({
    required this.view,
    required this.count,
    required this.loading,
    required this.repository,
    this.qboSpec,
    this.qboService,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final displayCount = loading
        ? '…'
        : count == null || count! < 0
            ? '—'
            : count.toString();
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TimelineScreen(
            view: view,
            repository: repository,
            qboSpec: qboSpec,
            qboService: qboService,
            // Dashboard navigation doesn't need an LLM client — the
            // timeline gracefully skips the post-log hook when one
            // isn't provided.
          ),
        ),
      ),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconResolver.resolve(
                  view.icon,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  view.name,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              displayCount,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: scheme.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
