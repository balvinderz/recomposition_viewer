import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recomposition_inspector/inspector_client.dart';
import 'package:recomposition_inspector/main.dart';

class FakeInspectorClient implements InspectorClient {
  bool attached = false;
  bool tracking = false;
  bool failNextSnapshot = false;
  int snapshotCount = 0;
  final List<(String, Map<String, dynamic>)> commands = [];

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> send(
    String command, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    commands.add((command, arguments));
    switch (command) {
      case 'prerequisites':
        return {'ready': true};
      case 'devices':
        return {
          'devices': [
            {
              'serial': 'pixel-1',
              'model': 'Pixel Fold',
              'foreground_package': 'com.example.app',
            },
          ],
        };
      case 'attach':
        attached = true;
        return _status();
      case 'start':
        tracking = true;
        return _status();
      case 'stop':
        tracking = false;
        return _status();
      case 'snapshot':
        snapshotCount++;
        if (failNextSnapshot) {
          failNextSnapshot = false;
          throw const InspectorClientException('temporary snapshot failure');
        }
        return {
          'status': _status(),
          'nodes': [
            {
              'id': 2,
              'root_view_id': 1,
              'anchor_hash': 42,
              'parent_anchor_hash': 100,
              'tree_index': 1,
              'depth': 12,
              'name': 'FoodCartCrouton',
              'path': 'Screen/FoodCartCrouton',
              'file': 'CartCrouton.kt',
              'line': 176,
              'recompositions': 4,
              'skips': 2,
              'recomposition_delta': 1,
              'skip_delta': 0,
              'bounds': {'x': 0, 'y': 100, 'width': 1080, 'height': 158},
            },
            {
              'id': 1,
              'root_view_id': 1,
              'anchor_hash': 100,
              'parent_anchor_hash': null,
              'tree_index': 0,
              'depth': 0,
              'name': 'RootComposable',
              'path': 'RootComposable',
              'file': 'Root.kt',
              'line': 10,
              'recompositions': 0,
              'skips': 0,
              'recomposition_delta': 0,
              'skip_delta': 0,
              'bounds': {'x': 0, 'y': 0, 'width': 1080, 'height': 2200},
            },
          ],
        };
      case 'detach':
        attached = false;
        tracking = false;
        return {'detached': true};
      default:
        return _status();
    }
  }

  Map<String, dynamic> _status() => {
    'attached': attached,
    'tracking': tracking,
    'device': 'pixel-1',
    'package': 'com.example.app',
    'pid': 123,
    'abi': 'arm64-v8a',
    'compose_version': '1.11.2',
    'root_view_ids': [1],
  };

  @override
  Future<void> dispose() async {}
}

void main() {
  testWidgets('attaches, renders counters, and detaches', (tester) async {
    final client = FakeInspectorClient();
    await tester.binding.setSurfaceSize(const Size(1320, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      RecompositionInspectorApp(client: client, enablePreview: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Recomposition Viewer'), findsOneWidget);
    expect(find.textContaining('Pixel Fold'), findsOneWidget);

    await tester.tap(find.byKey(const Key('attach-button')));
    await tester.pumpAndSettle();

    final attachIndex = client.commands.indexWhere(
      (entry) => entry.$1 == 'attach',
    );
    expect(client.commands.skip(attachIndex).take(3).map((entry) => entry.$1), [
      'attach',
      'start',
      'snapshot',
    ]);
    expect(client.commands[attachIndex + 1].$2['reset'], isTrue);
    expect(find.text('Pause capture'), findsOneWidget);
    expect(find.text('FoodCartCrouton'), findsWidgets);
    expect(find.text('CartCrouton.kt:176'), findsWidgets);
    expect(find.text('4'), findsWidgets);
    expect(
      tester.getTopLeft(find.text('RootComposable')).dy,
      lessThan(tester.getTopLeft(find.text('FoodCartCrouton').first).dy),
    );

    await tester.tap(find.byKey(const Key('detach-button')));
    await tester.pumpAndSettle();

    expect(client.attached, isFalse);
    expect(find.text('Attach a debuggable Compose app'), findsOneWidget);
  });

  testWidgets('pause and resume preserve counts', (tester) async {
    final client = FakeInspectorClient();
    await tester.binding.setSurfaceSize(const Size(1320, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      RecompositionInspectorApp(client: client, enablePreview: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pause-button')));
    await tester.pumpAndSettle();
    expect(find.text('Resume capture'), findsOneWidget);
    final resumeLabel = tester.widget<Text>(find.text('Resume capture'));
    expect(resumeLabel.maxLines, 1);
    expect(resumeLabel.softWrap, isFalse);

    await tester.tap(find.byKey(const Key('resume-button')));
    await tester.pumpAndSettle();
    final starts = client.commands
        .where((entry) => entry.$1 == 'start')
        .toList();
    expect(starts, hasLength(2));
    expect(starts.first.$2['reset'], isTrue);
    expect(starts.last.$2['reset'], isFalse);
  });

  testWidgets('horizontal tree scrolling keeps counters pinned', (
    tester,
  ) async {
    final client = FakeInspectorClient();
    await tester.binding.setSurfaceSize(const Size(1320, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      RecompositionInspectorApp(client: client, enablePreview: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-button')));
    await tester.pumpAndSettle();

    final composable = find.text('FoodCartCrouton').first;
    final counterHeader = find.text('RECOMPOSITIONS').first;
    final composableX = tester.getTopLeft(composable).dx;
    final counterX = tester.getTopLeft(counterHeader).dx;

    await tester.drag(composable, const Offset(-40, 0));
    await tester.pump();

    expect(tester.getTopLeft(composable).dx, lessThan(composableX));
    expect(tester.getTopLeft(counterHeader).dx, counterX);
  });

  testWidgets(
    'collapses tree nodes while keeping search results discoverable',
    (tester) async {
      final client = FakeInspectorClient();
      await tester.binding.setSurfaceSize(const Size(1320, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        RecompositionInspectorApp(client: client, enablePreview: false),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attach-button')));
      await tester.pumpAndSettle();

      const childRow = ValueKey('hierarchy-1:node:2');
      expect(find.byKey(childRow), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toggle-1:node:1')));
      await tester.pump();
      expect(find.byKey(childRow), findsNothing);

      await tester.enterText(
        find.widgetWithText(TextField, 'Filter composables'),
        'FoodCart',
      );
      await tester.pump();
      expect(find.byKey(childRow), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Filter composables'),
        '',
      );
      await tester.pump();
      expect(find.byKey(childRow), findsNothing);

      await tester.tap(find.byKey(const Key('expand-all-nodes')));
      await tester.pump();
      expect(find.byKey(childRow), findsOneWidget);

      await tester.tap(find.byKey(const Key('collapse-all-nodes')));
      await tester.pump();
      expect(find.byKey(childRow), findsNothing);
    },
  );

  testWidgets('a transient snapshot failure keeps polling', (tester) async {
    final client = FakeInspectorClient();
    await tester.binding.setSurfaceSize(const Size(1320, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      RecompositionInspectorApp(client: client, enablePreview: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('attach-button')));
    await tester.pumpAndSettle();

    final beforeFailure = client.snapshotCount;
    client.failNextSnapshot = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('retrying automatically'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(client.snapshotCount, greaterThan(beforeFailure + 1));
    expect(find.textContaining('retrying automatically'), findsNothing);
  });
}
