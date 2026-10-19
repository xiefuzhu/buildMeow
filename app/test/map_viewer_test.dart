import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:build_meow/src/widgets/map_viewer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A flat opaque image. The content does not matter: these tests are about the
/// transform, not the pixels.
Future<ui.Image> _solidImage(int width, int height) {
  final pixels = Uint8List(width * height * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 120;
    pixels[i + 1] = 160;
    pixels[i + 2] = 200;
    pixels[i + 3] = 255;
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

void main() {
  late ui.Image image;
  const viewport = 400.0;
  // 400 / 64 = 6.25, times the 0.94 fit margin.
  const fittedScale = 6.25 * 0.94;

  setUpAll(() async {
    image = await _solidImage(64, 64);
  });

  /// Pumps the viewer at a known size with a device pixel ratio of 1, so zoom
  /// readouts are exact.
  Future<GlobalKey<MapViewerState>> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(viewport, viewport);
    addTearDown(tester.view.reset);

    final key = GlobalKey<MapViewerState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: viewport,
            height: viewport,
            child: MapViewer(key: key, image: image),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('fits the picture to the viewport on first layout', (
    tester,
  ) async {
    final key = await pump(tester);
    expect(key.currentState!.zoom, closeTo(fittedScale, 0.01));
    expect(key.currentState!.rotation, 0);
  });

  testWidgets('a quarter turn accumulates, and the opposite turn undoes it', (
    tester,
  ) async {
    final key = await pump(tester);
    final state = key.currentState!;

    state.rotateByQuarterTurns(1);
    await tester.pumpAndSettle();
    expect(state.rotation, closeTo(math.pi / 2, 1e-9));

    state.rotateByQuarterTurns(1);
    await tester.pumpAndSettle();
    expect(state.rotation, closeTo(math.pi, 1e-9));

    state.rotateByQuarterTurns(-1);
    await tester.pumpAndSettle();
    expect(state.rotation, closeTo(math.pi / 2, 1e-9));
  });

  testWidgets('rotating keeps the picture centred', (tester) async {
    final key = await pump(tester);
    final state = key.currentState!;
    const centre = Offset(viewport / 2, viewport / 2);

    // Get this wrong and the picture jumps out of view when the rotate button
    // is pressed, which is exactly the sort of bug a screenshot will not catch.
    for (final quarters in <int>[0, 1, 2, 3, 4, 5]) {
      state.reset();
      await tester.pumpAndSettle();
      state.rotateByQuarterTurns(quarters);
      await tester.pumpAndSettle();

      final mapped = state.imageToScreen(
        Offset(image.width / 2, image.height / 2),
      );
      expect(mapped.dx, closeTo(centre.dx, 0.01), reason: '$quarters quarters');
      expect(mapped.dy, closeTo(centre.dy, 0.01), reason: '$quarters quarters');
    }
  });

  testWidgets('the four corners stay put through a full turn', (tester) async {
    final key = await pump(tester);
    final state = key.currentState!;
    final corners = <Offset>[
      Offset.zero,
      Offset(image.width.toDouble(), 0),
      Offset(0, image.height.toDouble()),
      Offset(image.width.toDouble(), image.height.toDouble()),
    ];

    state.reset();
    await tester.pumpAndSettle();
    final before = corners.map(state.imageToScreen).toList();

    state.rotateByQuarterTurns(4);
    await tester.pumpAndSettle();
    final after = corners.map(state.imageToScreen).toList();

    for (var i = 0; i < corners.length; i++) {
      expect(after[i].dx, closeTo(before[i].dx, 0.01));
      expect(after[i].dy, closeTo(before[i].dy, 0.01));
    }
  });

  testWidgets('screenToImage undoes imageToScreen', (tester) async {
    final key = await pump(tester);
    final state = key.currentState!;
    state.rotateByQuarterTurns(1);
    await tester.pumpAndSettle();

    for (final point in <Offset>[
      Offset.zero,
      const Offset(64, 0),
      const Offset(13.5, 41.25),
      const Offset(64, 64),
    ]) {
      final roundTripped = state.screenToImage(state.imageToScreen(point));
      expect(roundTripped.dx, closeTo(point.dx, 1e-9));
      expect(roundTripped.dy, closeTo(point.dy, 1e-9));
    }
  });

  testWidgets('dragging pans without changing zoom or rotation', (
    tester,
  ) async {
    final key = await pump(tester);
    final state = key.currentState!;
    final before = state.imageToScreen(Offset.zero);

    // `tester.drag` moves in one step, so part of it is eaten by the gesture
    // recogniser's slop. Assert the direction and that the picture actually
    // moved; the exact delta is not what this test is about.
    await tester.drag(find.byType(MapViewer), const Offset(40, -25));
    await tester.pumpAndSettle();

    expect(state.rotation, 0);
    expect(state.zoom, closeTo(fittedScale, 0.01));

    final after = state.imageToScreen(Offset.zero);
    final moved = after - before;
    expect(moved.dx, greaterThan(0));
    expect(moved.dy, lessThan(0));
    expect(moved.dx, lessThanOrEqualTo(40.5));
    expect(moved.dy, greaterThanOrEqualTo(-25.5));
  });

  testWidgets('double tap resets zoom and rotation', (tester) async {
    final key = await pump(tester);
    final state = key.currentState!;

    state.rotateByQuarterTurns(1);
    await tester.pumpAndSettle();
    expect(state.rotation, isNot(0));

    final centre = tester.getCenter(find.byType(MapViewer));
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();

    expect(state.rotation, 0);
    expect(state.zoom, closeTo(fittedScale, 0.01));
  });

  testWidgets('an empty viewer shows its label and still lays out', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 300,
            child: MapViewer(image: null, emptyLabel: '空空如也'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('空空如也'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits when the picture arrives after the first layout', (
    tester,
  ) async {
    // The regression this exists for: a result is produced seconds after the
    // screen is up, so the fit must key off the image arriving and not only off
    // the viewport changing. Keying it off the viewport alone left the map at
    // 1:1 in the corner, and the screenshot showed a cropped picture.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(viewport, viewport);
    addTearDown(tester.view.reset);

    final key = GlobalKey<MapViewerState>();
    Widget build(ui.Image? image) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: viewport,
          height: viewport,
          child: MapViewer(key: key, image: image),
        ),
      ),
    );

    await tester.pumpWidget(build(null));
    await tester.pumpAndSettle();
    expect(key.currentState!.zoom, 1);

    await tester.pumpWidget(build(image));
    await tester.pumpAndSettle();
    expect(key.currentState!.zoom, closeTo(fittedScale, 0.01));
    expect(key.currentState!.rotation, 0);

    // The picture must be centred, not stuck in the corner.
    final centre = key.currentState!.imageToScreen(
      Offset(image.width / 2, image.height / 2),
    );
    expect(centre.dx, closeTo(viewport / 2, 0.01));
    expect(centre.dy, closeTo(viewport / 2, 0.01));
  });

  testWidgets('a resize refits while the user has not taken over', (
    tester,
  ) async {
    final key = await pump(tester);
    final state = key.currentState!;

    // Half the viewport: the fit scale should halve with it.
    tester.view.physicalSize = const Size(viewport / 2, viewport / 2);
    await tester.pumpAndSettle();
    expect(state.zoom, closeTo(fittedScale / 2, 0.02));

    // Once the user zooms in, a resize must leave their zoom alone.
    state.rotateByQuarterTurns(1);
    await tester.pumpAndSettle();
    final zoomed = state.zoom;
    tester.view.physicalSize = const Size(viewport, viewport);
    await tester.pumpAndSettle();
    expect(state.zoom, closeTo(zoomed, 0.02));
    expect(state.rotation, closeTo(math.pi / 2, 1e-9));
  });

  testWidgets('the badge reports map cells, not the blown-up texture', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(viewport, viewport);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: viewport,
            height: viewport,
            child: MapViewer(image: image, mapPixel: 16),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 64 texture pixels / 16 = 4 map cells. Fitted zoom 5.875 per texel is
    // 94 per map cell, which is what the size panel is counting.
    expect(find.text('4x4  94x'), findsOneWidget);
  });
}
