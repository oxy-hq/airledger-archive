import 'dart:ui';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/app_def.dart';
import '../models/view_schema.dart';
import '../services/analytics_engine.dart';
import '../services/app_runtime.dart';

/// Renders a single `.app.yml` app: a stack of [DisplayDef]s with [ControlDef]s
/// at the top driving the queries. Re-runs all tasks when any control changes.
class AppViewerScreen extends StatefulWidget {
  final AppDef app;
  final List<ViewSchema> views;
  final AnalyticsEngine engine;

  const AppViewerScreen({
    super.key,
    required this.app,
    required this.views,
    required this.engine,
  });

  @override
  State<AppViewerScreen> createState() => _AppViewerScreenState();
}

class _AppViewerScreenState extends State<AppViewerScreen> {
  late final AppRuntime _runtime;
  final Map<String, String?> _values = {};
  final Map<String, List<String>> _optionsCache = {};
  Future<Map<String, List<Map<String, Object?>>>>? _results;

  @override
  void initState() {
    super.initState();
    _runtime = AppRuntime(
      app: widget.app,
      views: widget.views,
      engine: widget.engine,
    );
    _initOptions();
  }

  Future<void> _initOptions() async {
    for (final control in widget.app.controls) {
      if (control is DropdownControl) {
        if (control.optionsView != null) {
          final opts = await _runtime.resolveOptions(control.optionsView!);
          _optionsCache[control.id] = opts;
          // pick default — explicit default > first option
          _values[control.id] = control.defaultValue ??
              (opts.isNotEmpty ? opts.first : null);
        } else if (control.options != null) {
          _optionsCache[control.id] = control.options!;
          _values[control.id] = control.defaultValue ??
              (control.options!.isNotEmpty ? control.options!.first : null);
        }
      }
    }
    if (mounted) {
      setState(() {
        _results = _runtime.run(_values);
      });
    }
  }

  void _onControlChanged(String id, String? newValue) {
    setState(() {
      _values[id] = newValue;
      _results = _runtime.run(_values);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.app.title ?? widget.app.name)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in widget.app.controls) _buildControl(c),
            const SizedBox(height: 16),
            FutureBuilder<Map<String, List<Map<String, Object?>>>>(
              future: _results,
              builder: (context, snap) {
                if (_results == null || snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Text('Error: ${snap.error}',
                      style: const TextStyle(color: Colors.red));
                }
                final data = snap.data ?? {};
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final d in widget.app.displays) _buildDisplay(d, data),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControl(ControlDef control) {
    if (control is DropdownControl) {
      final opts = _optionsCache[control.id] ?? const [];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DropdownButtonFormField<String>(
          initialValue: _values[control.id],
          decoration: InputDecoration(
            labelText: control.label ?? control.id,
            border: const OutlineInputBorder(),
          ),
          items: opts
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => _onControlChanged(control.id, v),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildDisplay(
    DisplayDef d,
    Map<String, List<Map<String, Object?>>> taskResults,
  ) {
    if (d is MarkdownDisplay) {
      // Minimal: substitute control refs, render as a Text. We don't pull in
      // a markdown renderer — display strings are short headers in practice.
      final rendered = _substituteText(d.text);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          rendered.replaceFirst(RegExp(r'^#+\s*'), ''),
          style: Theme.of(context).textTheme.titleLarge,
        ),
      );
    }
    if (d is LineChartDisplay) {
      final rows = taskResults[d.taskData] ?? const [];
      return _LineChart(rows: rows, xCol: d.x, yCol: d.y, title: d.title);
    }
    if (d is TableDisplay) {
      final rows = taskResults[d.taskData] ?? const [];
      return _resultTable(rows, d.columns);
    }
    return const SizedBox.shrink();
  }

  String _substituteText(String text) {
    // Cheap Jinja-lite: replace {{ controls.foo }} with the value.
    final re = RegExp(r'\{\{\s*controls\.(\w+)\s*\}\}');
    return text.replaceAllMapped(re, (m) {
      final id = m.group(1)!;
      return _values[id] ?? '';
    });
  }

  Widget _resultTable(List<Map<String, Object?>> rows, List<String>? cols) {
    if (rows.isEmpty) return const Text('(no rows)');
    final headers = cols ?? rows.first.keys.toList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: [for (final h in headers) DataColumn(label: Text(h))],
          rows: [
            for (final r in rows)
              DataRow(
                cells: [
                  for (final h in headers) DataCell(Text('${r[h] ?? ''}')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Line chart with pan + pinch-to-zoom + reset + a non-blocking tooltip.
///
/// Zoom/pan are state-based (we track the visible x range and rebuild the
/// chart at the new range, rather than scaling the widget) so axis labels
/// stay readable at any zoom level.
class _LineChart extends StatefulWidget {
  final List<Map<String, Object?>> rows;
  final String xCol;
  final String yCol;
  final String? title;

  const _LineChart({
    required this.rows,
    required this.xCol,
    required this.yCol,
    this.title,
  });

  @override
  State<_LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<_LineChart> {
  late List<FlSpot> _spots;
  late double _dataXMin, _dataXMax, _dataYMin, _dataYMax;

  // Visible window. null means "use full data range".
  double? _viewXMin, _viewXMax;

  // Cached state during an active pinch gesture so we can compute a smooth
  // zoom from the gesture's starting scale + focal point.
  double? _gestureStartXMin, _gestureStartXMax;
  double? _gestureFocalXValue;
  Offset? _gestureLastFocal;

  @override
  void initState() {
    super.initState();
    _rebuildSpots();
  }

  @override
  void didUpdateWidget(_LineChart old) {
    super.didUpdateWidget(old);
    if (old.rows != widget.rows ||
        old.xCol != widget.xCol ||
        old.yCol != widget.yCol) {
      _rebuildSpots();
      // Reset the view window when the underlying data changes (e.g. user
      // picked a different exercise).
      _viewXMin = null;
      _viewXMax = null;
    }
  }

  void _rebuildSpots() {
    final spots = <FlSpot>[];
    for (final raw in widget.rows) {
      final yVal = (raw[widget.yCol] as num?)?.toDouble() ?? double.nan;
      if (yVal.isNaN) continue;
      final xRaw = raw[widget.xCol]?.toString() ?? '';
      double xVal;
      try {
        final dt = DateTime.parse(xRaw);
        xVal = dt.millisecondsSinceEpoch / (1000 * 60 * 60 * 24);
      } catch (_) {
        xVal = (raw[widget.xCol] as num?)?.toDouble() ?? 0;
      }
      spots.add(FlSpot(xVal, yVal));
    }
    spots.sort((a, b) => a.x.compareTo(b.x));
    _spots = spots;
    if (spots.isNotEmpty) {
      _dataXMin = spots.first.x;
      _dataXMax = spots.last.x;
      _dataYMin = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
      _dataYMax = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_spots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('(no data)'),
      );
    }
    final xMin = _viewXMin ?? _dataXMin;
    final xMax = _viewXMax ?? _dataXMax;
    // Auto-rescale y to whatever's currently visible, so a zoomed-in
    // section uses the whole vertical space.
    final visible = _spots.where((s) => s.x >= xMin && s.x <= xMax).toList();
    final yMin = visible.isEmpty
        ? _dataYMin
        : visible.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final yMax = visible.isEmpty
        ? _dataYMax
        : visible.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final yPad = (yMax - yMin).abs() * 0.1;
    final isZoomed = _viewXMin != null || _viewXMax != null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.title != null)
                Expanded(
                  child: Text(
                    widget.title!,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              IconButton(
                icon: const Icon(Icons.zoom_in, size: 20),
                tooltip: 'Zoom in',
                visualDensity: VisualDensity.compact,
                onPressed: () => _zoomBy(0.65),
              ),
              IconButton(
                icon: const Icon(Icons.zoom_out, size: 20),
                tooltip: 'Zoom out',
                visualDensity: VisualDensity.compact,
                onPressed: () => _zoomBy(1.5),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                tooltip: 'Reset view',
                visualDensity: VisualDensity.compact,
                onPressed: isZoomed ? _resetView : null,
              ),
            ],
          ),
          SizedBox(
            height: 320,
            child: GestureDetector(
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: (_) {
                _gestureStartXMin = null;
                _gestureStartXMax = null;
                _gestureFocalXValue = null;
                _gestureLastFocal = null;
              },
              child: LineChart(
                LineChartData(
                  minX: xMin,
                  maxX: xMax,
                  minY: yMin - yPad,
                  maxY: yMax + yPad,
                  clipData: const FlClipData.all(),
                  gridData: const FlGridData(show: true, drawVerticalLine: true),
                  borderData: FlBorderData(show: true),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(),
                    topTitles: const AxisTitles(),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 52,
                        getTitlesWidget: (value, meta) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            _formatYTick(value),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 48,
                        interval: _xInterval(xMax - xMin),
                        getTitlesWidget: (value, meta) => _xLabel(
                          value: value,
                          rangeDays: xMax - xMin,
                        ),
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: _spots,
                      isCurved: false,
                      barWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                      dotData: FlDotData(show: visible.length < 60),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    enabled: true,
                    handleBuiltInTouches: true,
                    touchTooltipData: LineTouchTooltipData(
                      // semi-transparent surface so the line/points stay visible
                      getTooltipColor: (_) =>
                          Colors.black.withValues(alpha: 0.55),
                      tooltipMargin: 12,
                      tooltipPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItems: (spots) {
                        return spots.map((s) {
                          final dt = DateTime.fromMillisecondsSinceEpoch(
                            (s.x * 86400000).toInt(),
                            isUtc: true,
                          );
                          final date = DateFormat('yyyy-MM-dd').format(dt);
                          return LineTooltipItem(
                            '$date\n${s.y.toStringAsFixed(1)}',
                            const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              height: 1.3,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${visible.length} of ${_spots.length} points visible · '
              'y=${yMin.toStringAsFixed(1)}–${yMax.toStringAsFixed(1)} · '
              'pinch or drag to zoom/pan',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Zoom / pan ----

  void _zoomBy(double factor) {
    // factor < 1 → zoom in (range shrinks around the center)
    final xMin = _viewXMin ?? _dataXMin;
    final xMax = _viewXMax ?? _dataXMax;
    final center = (xMin + xMax) / 2;
    final half = (xMax - xMin) / 2 * factor;
    _applyViewRange(center - half, center + half);
  }

  void _resetView() {
    setState(() {
      _viewXMin = null;
      _viewXMax = null;
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartXMin = _viewXMin ?? _dataXMin;
    _gestureStartXMax = _viewXMax ?? _dataXMax;
    _gestureLastFocal = details.focalPoint;
    // Approximate focal point in chart-x by mapping the touch's local x to
    // the current visible range. Without the chart's actual render box this
    // is good-enough for the zoom UX.
    final box = context.findRenderObject() as RenderBox?;
    if (box != null) {
      final local = box.globalToLocal(details.focalPoint);
      final width = box.size.width;
      final t = (local.dx / width).clamp(0.0, 1.0);
      _gestureFocalXValue = _gestureStartXMin! +
          (_gestureStartXMax! - _gestureStartXMin!) * t;
    } else {
      _gestureFocalXValue = (_gestureStartXMin! + _gestureStartXMax!) / 2;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_gestureStartXMin == null) return;
    final startRange = _gestureStartXMax! - _gestureStartXMin!;
    // Zoom — pinch: scale the visible range by 1/scale, anchored on focal x.
    final newRange = startRange / details.horizontalScale.clamp(0.1, 10.0);
    final focal = _gestureFocalXValue!;
    final tFocal = (focal - _gestureStartXMin!) / startRange;
    var newMin = focal - newRange * tFocal;
    var newMax = newMin + newRange;
    // Pan — translation: shift everything by the focal-point delta
    // converted from pixels to chart-x.
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && _gestureLastFocal != null) {
      final dxPixels = details.focalPoint.dx - _gestureLastFocal!.dx;
      final pxPerX = box.size.width / (_viewXMax! - _viewXMin!).clamp(0.001, 1e9);
      final dxChart = dxPixels / pxPerX;
      newMin -= dxChart;
      newMax -= dxChart;
    }
    _applyViewRange(newMin, newMax);
  }

  void _applyViewRange(double newMin, double newMax) {
    // Clamp to data bounds; don't let zoom flip min/max.
    newMin = newMin.clamp(_dataXMin, _dataXMax);
    newMax = newMax.clamp(_dataXMin, _dataXMax);
    if (newMax - newMin < 1) return; // minimum window: 1 day
    setState(() {
      _viewXMin = newMin;
      _viewXMax = newMax;
    });
  }

  // ---- Axis label formatting ----

  String _formatYTick(double v) {
    if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    if (v == v.truncate()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  /// Pick a sensible tick interval based on the visible x-range (in days).
  double _xInterval(double rangeDays) {
    if (rangeDays <= 14) return 2; // every 2 days
    if (rangeDays <= 60) return 7; // weekly
    if (rangeDays <= 365) return 30; // monthly-ish
    if (rangeDays <= 365 * 3) return 90; // quarterly
    return 365; // yearly
  }

  Widget _xLabel({required double value, required double rangeDays}) {
    final dt = DateTime.fromMillisecondsSinceEpoch(
      (value * 86400000).toInt(),
      isUtc: true,
    );
    final fmt = rangeDays <= 60
        ? DateFormat('MMM d')
        : rangeDays <= 365 * 2
            ? DateFormat('MMM yy')
            : DateFormat('yyyy');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Transform.rotate(
        angle: -0.5, // ~ -28 degrees; fits long month labels without overlap
        child: Text(fmt.format(dt), style: const TextStyle(fontSize: 10)),
      ),
    );
  }
}
