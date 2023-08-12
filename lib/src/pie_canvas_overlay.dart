import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pie_menu/src/pie_action.dart';
import 'package:pie_menu/src/pie_button.dart';
import 'package:pie_menu/src/pie_canvas.dart';
import 'package:pie_menu/src/pie_delegate.dart';
import 'package:pie_menu/src/pie_menu.dart';
import 'package:pie_menu/src/pie_theme.dart';
import 'package:pie_menu/src/platform/base.dart';
import 'package:vector_math/vector_math.dart' hide Colors;

/// Canvas widget that is actually displayed on the screen.
class PieCanvasOverlay extends StatefulWidget {
  const PieCanvasOverlay({
    super.key,
    required this.theme,
    this.onMenuToggle,
    required this.child,
  });

  final PieTheme theme;
  final Function(bool active)? onMenuToggle;
  final Widget child;

  @override
  PieCanvasOverlayState createState() => PieCanvasOverlayState();
}

class PieCanvasOverlayState extends State<PieCanvasOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// * [PieMenu] refers to the menu that is currently displayed on the canvas.

  final _platform = BasePlatform();

  /// Theme of [PieMenu].
  ///
  /// If [PieMenu] does not have a theme, [PieCanvas] theme is displayed.
  late PieTheme _theme = widget.theme;

  /// Actions of [PieMenu].
  List<PieAction> _actions = [];

  /// Controls [_bounceAnimation].
  late final AnimationController _bounceController = AnimationController(
    duration: widget.theme.pieBounceDuration,
    vsync: this,
  );

  /// Bouncing animation for the [PieButton]s.
  late final Animation _bounceAnimation = Tween(
    begin: 0.0,
    end: 1.0,
  ).animate(CurvedAnimation(
    parent: _bounceController,
    curve: Curves.elasticOut,
  ));

  /// Whether [_menuChild] is currently pressed.
  bool _pressed = false;

  /// Whether [_menuChild] is pressed again when the menu is active.
  bool _pressedAgain = false;

  /// Whether [PieMenu] is currently active.
  bool menuActive = false;

  /// Whether a [PieMenu] is attached.
  bool _menuAttached = false;

  /// State of [PieMenu].
  PieMenuState? _menuState;

  /// Child widget of [PieMenu].
  Widget? _menuChild;

  /// Render box of [_menuChild].
  RenderBox? _menuRenderBox;

  /// Currently pressed pointer offset.
  Offset _pointerOffset = Offset.zero;

  /// Currently hovered [PieButton] index.
  int? _hoveredAction;

  /// Starts when the pointer is down,
  /// is triggered after the delay duration specified in [PieTheme],
  /// and gets cancelled when the pointer is up.
  Timer? _attachTimer;

  /// Starts when the pointer is up,
  /// is triggered after the fade duration specified in [PieTheme],
  /// and gets cancelled when the pointer is down again.
  Timer? _detachTimer;

  /// Tooltip widget for the hovered [PieButton].
  Widget? _tooltip;

  /// Functional callback that is triggered when
  /// the active [PieMenu] is opened and closed.
  Function(bool active)? _onActiveMenuToggle;

  RenderBox? get _renderBox {
    final object = context.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }

  Offset get _canvasOffset {
    return _renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
  }

  Size get _canvasSize => _renderBox?.size ?? Size.zero;
  double get cw => _canvasSize.width;
  double get ch => _canvasSize.height;

  dynamic _contextMenuSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _bounceController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void setState(fn) {
    if (mounted) {
      super.setState(fn);
    }
  }

  var _size = PlatformDispatcher.instance.views.first.physicalSize;

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (mounted && menuActive) {
      final prevSize = _size;
      _size = PlatformDispatcher.instance.views.first.physicalSize;
      if (prevSize != _size) {
        menuActive = false;
        _menuState?.setVisibility(true);
        toggleMenu(false);
        _detachMenu();
      }
    }
  }

  double get px => _pointerOffset.dx - _canvasOffset.dx;
  double get py => _pointerOffset.dy - _canvasOffset.dy;

  double get _angleDiff => 7.4 * _theme.buttonSize / sqrt(_theme.distance);

  double get _safeDistance => _theme.distance + _theme.buttonSize;

  double get _baseAngle {
    final arc = (_actions.length - 1) * _angleDiff;
    final customAngle = _theme.customAngle;

    if (customAngle != null) {
      switch (_theme.customAngleAnchor) {
        case PieAnchor.start:
          return customAngle;
        case PieAnchor.center:
          return customAngle + arc / 2;
        case PieAnchor.end:
          return customAngle + arc;
      }
    }

    final distanceFactor = min(1, (cw / 2 - px) / (cw / 2));

    final p = Offset(px, py);

    double angleBetween(Offset o1, Offset o2) {
      final slope = (o2.dy - o1.dy) / (o2.dx - o1.dx);
      return degrees(atan(slope));
    }

    if ((p - const Offset(0, 0)).distance < _safeDistance) {
      final o = Offset(_safeDistance, _safeDistance);
      return arc / 2 - angleBetween(o, p);
    } else if ((p - Offset(cw, 0)).distance < _safeDistance) {
      final o = Offset(cw - _safeDistance, _safeDistance);
      return arc / 2 + 180 - angleBetween(o, p);
    } else if ((p - Offset(0, ch)).distance < _safeDistance) {
      final o = Offset(_safeDistance, ch - _safeDistance);
      return arc / 2 - angleBetween(o, p);
    } else if ((p - Offset(cw, ch)).distance < _safeDistance) {
      final o = Offset(cw - _safeDistance, ch - _safeDistance);
      return arc / 2 + 180 - angleBetween(o, p);
    } else if (py < _safeDistance) {
      final o = Offset(cw / 2, max(cw, ch));
      return px > cw / 2
          ? arc / 2 - 180 - angleBetween(o, p)
          : arc / 2 - angleBetween(o, p);
    } else if (py > ch - _safeDistance / 2) {
      final o = Offset(cw / 2, min(0, ch - cw));
      return px > cw / 2
          ? arc / 2 - 180 - angleBetween(o, p)
          : arc / 2 - angleBetween(o, p);
    } else {
      return arc / 2 + 90 - 90 * distanceFactor;
    }
  }

  double _getActionAngle(int index) {
    return radians(_baseAngle - _theme.angleOffset - _angleDiff * index);
  }

  @override
  Widget build(BuildContext context) {
    final tooltip = _tooltip;
    final menuRenderBox = _menuRenderBox;
    final menuChild = _menuChild;

    return MouseRegion(
      cursor: _hoveredAction != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) => _pointerDown(event.position),
            onPointerMove: (event) => _pointerMove(event.position),
            onPointerHover:
                menuActive ? (event) => _pointerMove(event.position) : null,
            onPointerUp: (event) => _pointerUp(event.position),
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                physics:
                    menuActive ? const NeverScrollableScrollPhysics() : null,
              ),
              child: IgnorePointer(
                ignoring: menuActive,
                child: widget.child,
              ),
            ),
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              duration: _theme.fadeDuration,
              opacity: menuActive ? 1 : 0,
              curve: Curves.ease,
              child: Stack(
                children: [
                  /// Overlay
                  Positioned.fill(
                    child: ColoredBox(
                      color: _theme.overlayColor ??
                          (_theme.brightness == Brightness.light
                              ? Colors.white.withOpacity(0.8)
                              : Colors.black.withOpacity(0.8)),
                    ),
                  ),

                  /// Pie Menu child
                  if (menuRenderBox != null &&
                      menuRenderBox.attached &&
                      menuChild != null)
                    () {
                      final menuOffset =
                          menuRenderBox.localToGlobal(Offset.zero);

                      return Positioned(
                        top: menuOffset.dy - _canvasOffset.dy,
                        left: menuOffset.dx - _canvasOffset.dx,
                        child: AnimatedOpacity(
                          opacity: _hoveredAction != null ? 0.5 : 1,
                          duration: _theme.hoverDuration,
                          curve: Curves.ease,
                          child: SizedBox.fromSize(
                            size: menuRenderBox.size,
                            child: menuChild,
                          ),
                        ),
                      );
                    }.call(),

                  /// Tooltip
                  if (tooltip != null)
                    () {
                      final tooltipAlignment = _theme.tooltipAlignment;

                      final child = AnimatedOpacity(
                        opacity: menuActive && _hoveredAction != null ? 1 : 0,
                        duration: _theme.hoverDuration,
                        curve: Curves.ease,
                        child: Padding(
                          padding: _theme.tooltipPadding,
                          child: DefaultTextStyle(
                            textAlign: _theme.tooltipTextAlign ??
                                (px < cw / 2
                                    ? TextAlign.right
                                    : TextAlign.left),
                            style: _theme.tooltipStyle ??
                                TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: _theme.brightness == Brightness.light
                                      ? Colors.black
                                      : Colors.white,
                                ),
                            child: tooltip,
                          ),
                        ),
                      );

                      if (tooltipAlignment != null) {
                        return Align(
                          alignment: tooltipAlignment,
                          child: child,
                        );
                      } else {
                        return Positioned(
                          top: py < ch / 2 ? py + _safeDistance : null,
                          bottom: py >= ch / 2 ? ch - py + _safeDistance : null,
                          left: 0,
                          right: 0,
                          child: Align(
                            alignment: px < cw / 2
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: child,
                          ),
                        );
                      }
                    }.call(),

                  /// Action buttons
                  Flow(
                    delegate: PieDelegate(
                      bounceAnimation: _bounceAnimation,
                      pointerOffset: _pointerOffset,
                      canvasOffset: _canvasOffset,
                      baseAngle: _baseAngle,
                      angleDiff: _angleDiff,
                      theme: _theme,
                    ),
                    children: [
                      DecoratedBox(
                        decoration: _theme.pointerDecoration ??
                            BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _theme.brightness == Brightness.light
                                    ? Colors.black.withOpacity(0.35)
                                    : Colors.white.withOpacity(0.5),
                                width: 4,
                              ),
                            ),
                      ),
                      for (int i = 0; i < _actions.length; i++)
                        PieButton(
                          action: _actions[i],
                          angle: _getActionAngle(i),
                          menuActive: menuActive,
                          hovered: i == _hoveredAction,
                          theme: _theme,
                          fadeDuration: _theme.fadeDuration,
                          hoverDuration: _theme.hoverDuration,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void toggleMenu(bool active) {
    _onActiveMenuToggle?.call(active);
    widget.onMenuToggle?.call(active);
    if (active) {
      WidgetsBinding.instance.addPostFrameCallback((duration) {
        /// This rebuild prevents menu child being displayed
        /// in the wrong offset when the scrollable swiped fast.
        setState(() {});
      });
    }
  }

  bool isOutsideOfPointerArea(Offset offset) {
    return (_pointerOffset - offset).distance > _theme.pointerSize / 2;
  }

  void attachMenu({
    required bool rightClicked,
    required Offset offset,
    required PieMenuState state,
    required Widget child,
    required RenderBox renderBox,
    required List<PieAction> actions,
    required PieTheme? theme,
    required Function(bool menuActive)? onMenuToggle,
  }) {
    _contextMenuSubscription = _platform.listenContextMenu(
      preventDefault: rightClicked,
    );

    _attachTimer?.cancel();
    _detachTimer?.cancel();
    _menuState?.setVisibility(true);

    _menuAttached = true;
    _onActiveMenuToggle = onMenuToggle;
    _theme = theme ?? widget.theme;
    _actions = actions;
    _menuState = state;
    _menuChild = child;
    _menuRenderBox = renderBox;

    if (!_pressed) {
      _pressed = true;
      _pointerOffset = offset;

      _attachTimer = Timer(
        rightClicked ? Duration.zero : _theme.delayDuration,
        () {
          _detachTimer?.cancel();
          _bounceController.forward(from: 0);
          setState(() {
            menuActive = true;
            _hoveredAction = null;
          });
          toggleMenu(true);

          _menuState?.debounce();
          Future.delayed(_theme.fadeDuration, () {
            if (!(_detachTimer?.isActive ?? false)) {
              _menuState?.setVisibility(false);
            }
          });
        },
      );
    }
  }

  void _detachMenu({bool afterDelay = true}) {
    final subscription = _contextMenuSubscription;
    if (subscription is StreamSubscription) subscription.cancel();

    _detachTimer = Timer(
      afterDelay ? _theme.fadeDuration : Duration.zero,
      () {
        _attachTimer?.cancel();
        if (_menuAttached) {
          setState(() {
            _pressed = false;
            _pressedAgain = false;
            _tooltip = null;
            _hoveredAction = null;
            _menuState = null;
            _menuRenderBox = null;
            _menuChild = null;
            _menuAttached = false;
            menuActive = false;
          });
        }
      },
    );
  }

  void _pointerDown(Offset offset) {
    if (menuActive) {
      _pressedAgain = true;
      _pointerMove(offset);
    }
  }

  void _pointerUp(Offset offset) {
    _attachTimer?.cancel();

    if (menuActive) {
      if (isOutsideOfPointerArea(offset) || _pressedAgain) {
        final hoveredAction = _hoveredAction;

        if (hoveredAction != null) {
          _actions[hoveredAction].onSelect();
        }

        _menuState?.setVisibility(true);
        toggleMenu(false);
        setState(() => menuActive = false);

        _detachMenu();
      }
    } else {
      _detachMenu();
    }

    _pressed = false;
    _pressedAgain = false;
  }

  void _pointerMove(Offset offset) {
    if (menuActive) {
      for (int i = 0; i < _actions.length; i++) {
        PieAction action = _actions[i];
        final angle = _getActionAngle(i);
        Offset actionOffset = Offset(
          _pointerOffset.dx + _theme.distance * cos(angle),
          _pointerOffset.dy - _theme.distance * sin(angle),
        );
        if ((actionOffset - offset).distance <
            _theme.buttonSize / 2 + sqrt(_theme.buttonSize)) {
          if (_hoveredAction != i) {
            setState(() {
              _hoveredAction = i;
              _tooltip = action.tooltip;
            });
          }
          return;
        }
      }
      if (_hoveredAction != null) {
        setState(() => _hoveredAction = null);
      }
    } else if (_pressed && isOutsideOfPointerArea(offset)) {
      _detachMenu(afterDelay: false);
    }
  }
}
