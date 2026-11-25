import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// [AnimatedBuilder] that rests while a full-screen page covers it.
///
/// The navigator turns the ticker mode off for routes under an opaque
/// page. While it is off, changes of [listenable] only get noted; when the
/// route shows again (the page starts sliding away) it rebuilds once with
/// the newest state. Popups such as dialogs and sheets leave the ticker
/// mode on, so what shows dimmed behind them keeps updating.
class WhileShownBuilder extends StatefulWidget {
  const WhileShownBuilder({
    required this.listenable,
    required this.builder,
    this.child,
    super.key,
  });

  final Listenable listenable;
  final TransitionBuilder builder;
  final Widget? child;

  @override
  State<WhileShownBuilder> createState() => _WhileShownBuilderState();
}

class _WhileShownBuilderState extends State<WhileShownBuilder> {
  ValueListenable<TickerModeData>? _tickerMode;

  /// Something changed while covered.
  bool _missed = false;

  bool get _shown => _tickerMode?.value.enabled ?? true;

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant WhileShownBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_changed);
      widget.listenable.addListener(_changed);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final mode = TickerMode.getValuesNotifier(context);
    if (identical(mode, _tickerMode)) return;
    _tickerMode?.removeListener(_shownChanged);
    _tickerMode = mode..addListener(_shownChanged);
  }

  void _changed() {
    if (!mounted) return;
    if (_shown) {
      setState(() {});
    } else {
      _missed = true;
    }
  }

  void _shownChanged() {
    if (!mounted || !_shown || !_missed) return;
    _missed = false;
    setState(() {});
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_changed);
    _tickerMode?.removeListener(_shownChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.child);
}
