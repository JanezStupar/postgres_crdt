import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

import 'sql_crdt_test.dart';

Future<void> main() async {
  final crdt = await PostgresCrdt.open(
    'testdb',
    username: 'postgres',
    password: 'postgres',
    sslMode: SslMode.disable,
  );

  runSqlCrdtTests(crdt);

  group('PostgresCrdt specific tests', () {
    test('close() method properly closes connection pool', () async {
      // Create a new instance for this test
      final testCrdt = await PostgresCrdt.open(
        'testdb',
        username: 'postgres',
        password: 'postgres',
        sslMode: SslMode.disable,
      );

      // Verify the connection works before closing
      await testCrdt.execute('''
        CREATE TABLE IF NOT EXISTS test_close (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');

      final resultBefore = await testCrdt.query('SELECT * FROM test_close');
      expect(resultBefore, isNotNull);

      // Close the connection
      await testCrdt.close();

      // Verify that operations fail after closing
      // Should throw StateError: "Bad state: request() may not be called on a closed Pool."
      expect(
        () => testCrdt.query('SELECT * FROM test_close'),
        throwsStateError,
      );

      // Clean up - use the main crdt instance that's still open
      await crdt.execute('DROP TABLE IF EXISTS test_close');
    });
  });
}
