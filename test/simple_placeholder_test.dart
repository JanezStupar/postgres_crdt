// Simple test to verify placeholder handling with minimal complexity
// This test helps debug the placeholder conversion issue

import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

void main() {
  late PostgresCrdt crdt;

  setUpAll(() async {
    crdt = await PostgresCrdt.open(
      'testdb',
      username: 'postgres',
      password: '',
      sslMode: SslMode.disable,
    );

    // Clean up any existing tables
    try {
      await crdt.execute('DROP TABLE IF EXISTS simple_test CASCADE');
    } catch (_) {}
  });

  tearDownAll(() async {
    try {
      await crdt.execute('DROP TABLE IF EXISTS simple_test CASCADE');
    } catch (_) {}
  });

  group('Simple Placeholder Test', () {
    test('Setup: Create table', () async {
      await crdt.execute('''
        CREATE TABLE simple_test (
          id INTEGER NOT NULL PRIMARY KEY,
          value TEXT
        )
      ''');

      final tables = await crdt.getTables();
      expect(tables.contains('simple_test'), true);
    });

    test('Test 1: INSERT with \$1, \$2 placeholders', () async {
      // This is the most basic test - if this fails, the bug is still present
      print('Executing: INSERT INTO simple_test (id, value) VALUES (\$1, \$2)');
      print('With args: [1, "test_value"]');

      try {
        await crdt.execute(
          'INSERT INTO simple_test (id, value) VALUES (\$1, \$2)',
          [1, 'test_value'],
        );

        final result =
            await crdt.query('SELECT * FROM simple_test WHERE id = 1');
        print('Query result: $result');

        expect(result.length, 1);
        expect(result.first['id'], 1);
        expect(result.first['value'], 'test_value');

        print('SUCCESS: Placeholders working correctly!');
      } catch (e, st) {
        print('FAILED with error: $e');
        print('Stack trace: $st');
        rethrow;
      }
    });

    test('Test 2: Verify ?1, ?2 format still works', () async {
      print('Executing: INSERT INTO simple_test (id, value) VALUES (?1, ?2)');
      print('With args: [2, "test_value_2"]');

      try {
        await crdt.execute(
          'INSERT INTO simple_test (id, value) VALUES (?1, ?2)',
          [2, 'test_value_2'],
        );

        final result =
            await crdt.query('SELECT * FROM simple_test WHERE id = 2');
        print('Query result: $result');

        expect(result.length, 1);
        expect(result.first['value'], 'test_value_2');

        print('SUCCESS: ?N placeholders working correctly!');
      } catch (e, st) {
        print('FAILED with error: $e');
        print('Stack trace: $st');
        rethrow;
      }
    });
  });
}
