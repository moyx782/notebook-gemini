import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:notebook_core/notebook_core.dart';

import '../state/notebook_controller.dart';
import 'canvas_painter.dart';
import 'stroke_geometry.dart';
import 'widgets/canvas_card_layer.dart';

enum _GestureMode {
  none,
  pan,
  pinchZoom,
  drawStroke,
  drawShape,
  lasso,
  dragLassoGroup,
  erase,
  laser,
  dragElement,
}

class BoardStage extends StatefulWidget {
  const BoardStage({
    super.key,
    required this.controller,
    this.isSpacePanPressed = false,
    this.onRequestInsertImageAt,
  });

  final NotebookController controller;
  final bool isSpacePanPressed;
  final void Function(Offset scenePos)? onRequestInsertImageAt;

  @override
  State<BoardStage> createState() => _BoardStageState();
}

class _BoardStageState extends State<BoardStage> {
  final Map<int, Offset> _touchPointers = <int, Offset>{};
  final Map<int, int> _touchLastSeenMs = <int, int>{};
  _GestureMode _mode = _GestureMode.none;

  int? _activePointerId;
  PointerDeviceKind? _activePointerKind;
  Offset? _prevLocalPos;
  int _prevTimestampMs = 0;

  bool get _isStylusActive =>
      _activePointerId != null &&
      (_activePointerKind == PointerDeviceKind.stylus ||
          _activePointerKind == PointerDeviceKind.invertedStylus);

  void _pruneStaleTouches(int nowMs) {
    if (_touchPointers.isEmpty) return;
    final staleIds = <int>[];
    _touchLastSeenMs.forEach((id, ts) {
      if (id != _activePointerId && nowMs - ts > 6000) {
        staleIds.add(id);
      }
    });
    for (final id in staleIds) {
      _touchPointers.remove(id);
      _touchLastSeenMs.remove(id);
    }
  }

  // Multi-touch pinch state
  double _pinchStartDistance = 1.0;
  double _pinchStartZoom = 1.0;
  Offset _pinchSceneAnchor = Offset.zero;

  // Trackpad PanZoom state
  double _trackpadStartZoom = 1.0;

  // Dragging vector element state
  String? _draggingElementId;
  double _dragOrigX = 0;
  double _dragOrigY = 0;
  double _dragOrigW = 0;
  double _dragOrigH = 0;

  // Lasso group drag state
  Map<String, Offset> _lassoDragOrigins = const <String, Offset>{};
  Offset _lassoDragStartScene = Offset.zero;

  // Hold-to-Snap straight line timer (380ms pause at end of freehand stroke)
  Timer? _holdSnapTimer;
  Offset? _holdAnchorLocalPos;

  @override
  void dispose() {
    _cancelHoldSnapTimer();
    super.dispose();
  }

  void _cancelHoldSnapTimer() {
    _holdSnapTimer?.cancel();
    _holdSnapTimer = null;
    _holdAnchorLocalPos = null;
  }

  void _updateHoldSnapCheck(Offset localPos) {
    final c = widget.controller;
    if (c.isActiveStrokeSnappedLine) {
      _cancelHoldSnapTimer();
      return;
    }
    final anchor = _holdAnchorLocalPos;
    if (anchor != null && (localPos - anchor).distance <= 3.5) {
      return;
    }
    _holdAnchorLocalPos = localPos;
    _holdSnapTimer?.cancel();
    _holdSnapTimer = Timer(const Duration(milliseconds: 380), () {
      _holdSnapTimer = null;
      if (!mounted || _mode != _GestureMode.drawStroke) return;
      widget.controller.snapActiveStrokeToStraightLine();
    });
  }

  Offset _toScene(Offset local) {
    final c = widget.controller;
    return (local - c.panOffset) / c.zoom;
  }

  bool get _cardsInteractive {
    final c = widget.controller;
    if (c.formFactor == DeviceFormFactor.phone && c.phoneBrowseOnlyMode) {
      return false;
    }
    return c.tool == CanvasTool.select || c.editingCardId != null;
  }

  void _handleOuterPointerDown(PointerDownEvent event) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _pruneStaleTouches(nowMs);

    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      if (_mode == _GestureMode.pinchZoom) {
        _mode = _GestureMode.none;
      }
      return;
    }

    if (event.kind == PointerDeviceKind.touch) {
      if (_isStylusActive) {
        // Ignore resting-palm touch contacts while stylus is actively writing.
        return;
      }
      _touchPointers[event.pointer] = event.localPosition;
      _touchLastSeenMs[event.pointer] = nowMs;
      if (_touchPointers.length >= 2) {
        _cancelHoldSnapTimer();
        if (_mode == _GestureMode.drawStroke &&
            widget.controller.hasSubstantialActiveStroke) {
          widget.controller.finishLocalStroke();
        } else {
          widget.controller.cancelLocalStroke();
        }
        widget.controller.cancelLocalShape();
        widget.controller.cancelLasso();
        _mode = _GestureMode.pinchZoom;
        _activePointerId = null;
        _activePointerKind = null;
        _initPinchAnchor();
      }
    }
  }

  void _handleOuterPointerMove(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.touch &&
        _touchPointers.containsKey(event.pointer)) {
      _touchPointers[event.pointer] = event.localPosition;
      _touchLastSeenMs[event.pointer] = DateTime.now().millisecondsSinceEpoch;
      if (_isStylusActive) {
        return;
      }
      if (_touchPointers.length >= 2) {
        if (_mode != _GestureMode.pinchZoom) {
          _cancelHoldSnapTimer();
          if (_mode == _GestureMode.drawStroke &&
              widget.controller.hasSubstantialActiveStroke) {
            widget.controller.finishLocalStroke();
          } else {
            widget.controller.cancelLocalStroke();
          }
          widget.controller.cancelLocalShape();
          widget.controller.cancelLasso();
          _mode = _GestureMode.pinchZoom;
          _activePointerId = null;
          _activePointerKind = null;
          _initPinchAnchor();
        } else {
          _applyPinchUpdate();
        }
      }
    }
  }

  void _handleOuterPointerUpOrCancel(PointerEvent event) {
    if (event.kind == PointerDeviceKind.touch) {
      _touchPointers.remove(event.pointer);
      _touchLastSeenMs.remove(event.pointer);
      if (_mode == _GestureMode.pinchZoom && _touchPointers.length < 2) {
        _mode = _GestureMode.none;
      }
    }
  }

  void _initPinchAnchor() {
    if (_touchPointers.length < 2) return;
    final pts = _touchPointers.values.take(2).toList();
    final mid = (pts[0] + pts[1]) * 0.5;
    _pinchStartDistance = math.max(12.0, (pts[0] - pts[1]).distance);
    _pinchStartZoom = widget.controller.zoom;
    _pinchSceneAnchor = _toScene(mid);
  }

  void _applyPinchUpdate() {
    if (_touchPointers.length < 2) return;
    final pts = _touchPointers.values.take(2).toList();
    final mid = (pts[0] + pts[1]) * 0.5;
    final dist = math.max(12.0, (pts[0] - pts[1]).distance);
    final nextZoom =
        (_pinchStartZoom * (dist / _pinchStartDistance)).clamp(0.25, 4.0);
    final nextPan = mid - _pinchSceneAnchor * nextZoom;
    widget.controller.updateViewport(panOffset: nextPan, zoom: nextZoom);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    final c = widget.controller;
    if (event is PointerScrollEvent) {
      final isZoomModifier = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed ||
          event.kind == PointerDeviceKind.mouse;
      if (isZoomModifier) {
        final factor = math.exp(-event.scrollDelta.dy * 0.0018);
        c.zoomByFactor(factor, focalLocalPoint: event.localPosition);
      } else {
        c.updateViewport(panOffset: c.panOffset - event.scrollDelta);
      }
    } else if (event is PointerScaleEvent) {
      c.zoomByFactor(event.scale, focalLocalPoint: event.localPosition);
    }
  }

  void _handlePanZoomStart(PointerPanZoomStartEvent event) {
    _trackpadStartZoom = widget.controller.zoom;
  }

  void _handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    final c = widget.controller;
    if ((event.scale - 1.0).abs() > 0.005) {
      final targetZoom = (_trackpadStartZoom * event.scale).clamp(0.25, 4.0);
      final sceneFocal = (event.localPosition - c.panOffset) / c.zoom;
      final nextPan = event.localPosition - sceneFocal * targetZoom;
      c.updateViewport(panOffset: nextPan, zoom: targetZoom);
    } else if (event.localPanDelta != Offset.zero) {
      c.updateViewport(panOffset: c.panOffset + event.localPanDelta);
    }
  }

  void _handleSurfacePointerDown(PointerDownEvent event) {
    final isStylus = event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    if (!isStylus &&
        (_touchPointers.length >= 2 || _mode == _GestureMode.pinchZoom)) {
      return;
    }

    final c = widget.controller;

    // Prevent secondary touch/palm contacts from hijacking an active pointer;
    // allow a hardware stylus tip to cleanly preempt an earlier palm touch.
    if (_activePointerId != null && _activePointerId != event.pointer) {
      if (!isStylus) {
        return;
      }
      if (_mode == _GestureMode.drawStroke) {
        _cancelHoldSnapTimer();
        if (c.hasSubstantialActiveStroke) {
          c.finishLocalStroke();
        } else {
          c.cancelLocalStroke();
        }
      } else if (_mode == _GestureMode.drawShape) {
        c.cancelLocalShape();
      } else if (_mode == _GestureMode.lasso) {
        c.cancelLasso();
      }
      _draggingElementId = null;
    }

    final scenePos = _toScene(event.localPosition);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _activePointerId = event.pointer;
    _activePointerKind = event.kind;
    _prevLocalPos = event.localPosition;
    _prevTimestampMs = nowMs;

    final isMiddleOrSpace =
        (event.buttons & kMiddleMouseButton) != 0 || widget.isSpacePanPressed;
    final isTouchRejectedForStylus =
        c.stylusOnlyMode && event.kind == PointerDeviceKind.touch;
    final isPhoneBrowseTouch = c.formFactor == DeviceFormFactor.phone &&
        c.phoneBrowseOnlyMode &&
        event.kind == PointerDeviceKind.touch;

    if (isMiddleOrSpace ||
        c.tool == CanvasTool.hand ||
        isTouchRejectedForStylus ||
        isPhoneBrowseTouch) {
      _mode = _GestureMode.pan;
      return;
    }

    if (event.kind == PointerDeviceKind.invertedStylus ||
        c.tool == CanvasTool.eraser) {
      _mode = _GestureMode.erase;
      c.eraseAt(scenePos);
      return;
    }

    if (c.tool == CanvasTool.pen || c.tool == CanvasTool.highlighter) {
      _mode = _GestureMode.drawStroke;
      _cancelHoldSnapTimer();
      _holdAnchorLocalPos = event.localPosition;
      final pressure = computeEffectivePressure(event, null, 0);
      c.startLocalStroke(scenePos, pressure: pressure);
      return;
    }

    if (c.tool == CanvasTool.lasso) {
      final groupRect = c.selectionBounds;
      if (groupRect != null && groupRect.inflate(12.0).contains(scenePos)) {
        _lassoDragOrigins = c.captureSelectedOrigins();
        _lassoDragStartScene = scenePos;
        _mode = _GestureMode.dragLassoGroup;
      } else {
        _mode = _GestureMode.lasso;
        c.startLasso(scenePos);
      }
      return;
    }

    if (c.tool.isShapeTool) {
      final kind = c.tool.asShapeKind;
      if (kind != null) {
        _mode = _GestureMode.drawShape;
        c.startLocalShape(scenePos, kind);
      }
      return;
    }

    if (c.tool == CanvasTool.laser) {
      _mode = _GestureMode.laser;
      c.emitLaserPoint(scenePos);
      return;
    }

    if (c.tool == CanvasTool.textCard) {
      c.createTextCard(sceneCenter: scenePos);
      return;
    }

    if (c.tool == CanvasTool.stickyNote) {
      c.createStickyNote(sceneCenter: scenePos);
      return;
    }

    if (c.tool == CanvasTool.image) {
      widget.onRequestInsertImageAt?.call(scenePos);
      return;
    }

    if (c.tool == CanvasTool.select) {
      final groupRect = c.selectionBounds;
      if (c.selectedElementIds.length > 1 &&
          groupRect != null &&
          groupRect.inflate(10.0).contains(scenePos)) {
        _lassoDragOrigins = c.captureSelectedOrigins();
        _lassoDragStartScene = scenePos;
        _mode = _GestureMode.dragLassoGroup;
        return;
      }
      final hit = c.hitTestElement(scenePos);
      if (hit != null) {
        c.selectElement(hit.id);
        _draggingElementId = hit.id;
        _dragOrigX = hit.x;
        _dragOrigY = hit.y;
        _dragOrigW = hit.width;
        _dragOrigH = hit.height;
        _mode = _GestureMode.dragElement;
      } else {
        c.clearSelection();
        _mode = _GestureMode.pan;
      }
    }
  }

  void _handleSurfacePointerMove(PointerMoveEvent event) {
    if (!_isStylusActive &&
        (_touchPointers.length >= 2 || _mode == _GestureMode.pinchZoom)) {
      return;
    }
    if (_activePointerId == null || event.pointer != _activePointerId) {
      return;
    }

    final c = widget.controller;
    final scenePos = _toScene(event.localPosition);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final dtMs = math.max(1, nowMs - _prevTimestampMs);

    c.updateCursorPresence(scenePos, visible: true);

    switch (_mode) {
      case _GestureMode.pan:
        final delta = event.localDelta;
        c.updateViewport(panOffset: c.panOffset + delta);
        break;

      case _GestureMode.drawStroke:
        final pressure =
            computeEffectivePressure(event, _prevLocalPos, dtMs);
        c.appendLocalStrokePoint(scenePos, pressure: pressure, dtMs: dtMs);
        _updateHoldSnapCheck(event.localPosition);
        break;

      case _GestureMode.drawShape:
        c.updateLocalShape(scenePos);
        break;

      case _GestureMode.lasso:
        c.appendLassoPoint(scenePos);
        break;

      case _GestureMode.dragLassoGroup:
        c.previewMoveSelectedElements(
          _lassoDragOrigins,
          scenePos - _lassoDragStartScene,
        );
        break;

      case _GestureMode.erase:
        c.eraseAt(scenePos);
        break;

      case _GestureMode.laser:
        c.emitLaserPoint(scenePos);
        break;

      case _GestureMode.dragElement:
        final elId = _draggingElementId;
        if (elId != null) {
          final current = c.doc.getElement(elId);
          if (current != null) {
            final sceneDelta = event.localDelta / c.zoom;
            c.previewElementFrame(
              elId,
              x: current.x + sceneDelta.dx,
              y: current.y + sceneDelta.dy,
            );
          }
        }
        break;

      case _GestureMode.none:
      case _GestureMode.pinchZoom:
        break;
    }

    _prevLocalPos = event.localPosition;
    _prevTimestampMs = nowMs;
  }

  void _handleSurfacePointerUpOrCancel(PointerEvent event) {
    if (_activePointerId == null || event.pointer != _activePointerId) {
      return;
    }

    _cancelHoldSnapTimer();
    final c = widget.controller;
    switch (_mode) {
      case _GestureMode.drawStroke:
        if (event is PointerUpEvent) {
          if (_prevLocalPos != null &&
              (event.localPosition - _prevLocalPos!).distance > 0.35) {
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            final dtMs = math.max(1, nowMs - _prevTimestampMs);
            final pressure =
                computeEffectivePressure(event, _prevLocalPos, dtMs);
            c.appendLocalStrokePoint(
              _toScene(event.localPosition),
              pressure: pressure,
              dtMs: dtMs,
            );
          }
          c.finishLocalStroke();
        } else if (c.hasSubstantialActiveStroke) {
          // Preserve intentional handwriting if OS/browser fires pointercancel
          // mid-stroke instead of flashing and deleting the user's ink.
          c.finishLocalStroke();
        } else {
          c.cancelLocalStroke();
        }
        break;
      case _GestureMode.drawShape:
        if (event is PointerUpEvent) {
          c.updateLocalShape(_toScene(event.localPosition));
          c.finishLocalShape();
        } else {
          c.cancelLocalShape();
        }
        break;
      case _GestureMode.lasso:
        if (event is PointerUpEvent) {
          c.finishLasso();
        } else {
          c.cancelLasso();
        }
        break;
      case _GestureMode.dragLassoGroup:
        c.commitGroupMoveUndo(_lassoDragOrigins);
        _lassoDragOrigins = const <String, Offset>{};
        break;
      case _GestureMode.dragElement:
        final elId = _draggingElementId;
        if (elId != null) {
          c.commitElementTransformUndo(
            elementId: elId,
            oldX: _dragOrigX,
            oldY: _dragOrigY,
            oldWidth: _dragOrigW,
            oldHeight: _dragOrigH,
          );
        }
        _draggingElementId = null;
        break;
      case _GestureMode.none:
      case _GestureMode.pan:
      case _GestureMode.pinchZoom:
      case _GestureMode.erase:
      case _GestureMode.laser:
        break;
    }

    _activePointerId = null;
    _activePointerKind = null;
    _prevLocalPos = null;
    if (_mode != _GestureMode.pinchZoom) {
      _mode = _GestureMode.none;
    }
  }

  MouseCursor _cursorForTool(CanvasTool tool) {
    if (widget.isSpacePanPressed || tool == CanvasTool.hand) {
      return _mode == _GestureMode.pan
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.grab;
    }
    switch (tool) {
      case CanvasTool.select:
        return SystemMouseCursors.basic;
      case CanvasTool.textCard:
      case CanvasTool.stickyNote:
      case CanvasTool.image:
        return SystemMouseCursors.click;
      default:
        return SystemMouseCursors.precise;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.of(context);
        widget.controller.updateViewportMetrics(
          constraints.biggest,
          mq.size.shortestSide,
        );

        return AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final c = widget.controller;
            final page = c.activePage;
            final elements = c.activeElements;

            return ClipRect(
              child: Listener(
                key: const ValueKey<String>('outer-board-listener'),
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handleOuterPointerDown,
                onPointerMove: _handleOuterPointerMove,
                onPointerUp: _handleOuterPointerUpOrCancel,
                onPointerCancel: _handleOuterPointerUpOrCancel,
                onPointerSignal: _handlePointerSignal,
                onPointerPanZoomStart: _handlePanZoomStart,
                onPointerPanZoomUpdate: _handlePanZoomUpdate,
                child: MouseRegion(
                  cursor: _cursorForTool(c.tool),
                  onHover: (event) => c.updateCursorPresence(
                    _toScene(event.localPosition),
                    visible: true,
                  ),
                  onExit: (_) =>
                      c.updateCursorPresence(Offset.zero, visible: false),
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      // Layer 1: Paper background & templates
                      RepaintBoundary(
                        child: CustomPaint(
                          painter: CommittedCanvasPainter(
                            page: page,
                            elements: const <CanvasElementModel>[],
                            panOffset: c.panOffset,
                            zoom: c.zoom,
                            selectedElementId: null,
                            showPageGuide: c.showPageGuide,
                            paintPaper: true,
                            paintInk: false,
                          ),
                          isComplex: true,
                        ),
                      ),

                      // Layer 2: Canvas drawing / erasing / stroke-selection surface
                      Positioned.fill(
                        key: const ValueKey<String>('surface-board-listener-pos'),
                        child: Listener(
                          key: const ValueKey<String>('surface-board-listener'),
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: _handleSurfacePointerDown,
                          onPointerMove: _handleSurfacePointerMove,
                          onPointerUp: _handleSurfacePointerUpOrCancel,
                          onPointerCancel: _handleSurfacePointerUpOrCancel,
                        ),
                      ),

                      // Layer 3: Interactive Markdown, Sticky Note & Image Cards
                      CanvasCardLayer(
                        controller: c,
                        interactive: _cardsInteractive,
                      ),

                      // Layer 4: Committed vector strokes, highlighters & shapes (above cards!)
                      IgnorePointer(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: CommittedCanvasPainter(
                              page: page,
                              elements: elements,
                              panOffset: c.panOffset,
                              zoom: c.zoom,
                              selectedElementId: c.selectedElementId,
                              revision: c.committedInkRevision,
                              paintPaper: false,
                              paintInk: true,
                            ),
                            isComplex: true,
                          ),
                        ),
                      ),

                      // Layer 5: Real-time local & remote strokes, laser & cursors
                      IgnorePointer(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: LiveOverlayPainter(
                              controller: c,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
