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

    test('schema isolation with PoolSettings and search_path', () async {
      // Create two test schemas
      await crdt.execute('CREATE SCHEMA IF NOT EXISTS schema_a');
      await crdt.execute('CREATE SCHEMA IF NOT EXISTS schema_b');

      try {
        // Create CRDT instance for schema_a
        final crdtA = await PostgresCrdt.open(
          'testdb',
          username: 'postgres',
          password: 'postgres',
          poolSettings: PoolSettings(
            sslMode: SslMode.disable,
            onOpen: (connection) async {
              await connection.execute('SET search_path TO schema_a');
            },
          ),
        );

        // Create CRDT instance for schema_b
        final crdtB = await PostgresCrdt.open(
          'testdb',
          username: 'postgres',
          password: 'postgres',
          poolSettings: PoolSettings(
            sslMode: SslMode.disable,
            onOpen: (connection) async {
              await connection.execute('SET search_path TO schema_b');
            },
          ),
        );

        try {
          // Create table in schema_a
          await crdtA.execute('''
            CREATE TABLE test_table_a (
              id INTEGER NOT NULL,
              value TEXT,
              PRIMARY KEY (id)
            )
          ''');

          // Create table in schema_b
          await crdtB.execute('''
            CREATE TABLE test_table_b (
              id INTEGER NOT NULL,
              value TEXT,
              PRIMARY KEY (id)
            )
          ''');

          // Insert data in schema_a
          await crdtA.execute(
            'INSERT INTO test_table_a (id, value) VALUES (?1, ?2)',
            [1, 'value_a'],
          );

          // Insert data in schema_b
          await crdtB.execute(
            'INSERT INTO test_table_b (id, value) VALUES (?1, ?2)',
            [2, 'value_b'],
          );

          // Verify getTables() with schema parameter returns only that schema's tables
          final tablesA = await crdtA.getTables(schema: 'schema_a');
          expect(tablesA, contains('test_table_a'));
          expect(tablesA, isNot(contains('test_table_b')));

          final tablesB = await crdtB.getTables(schema: 'schema_b');
          expect(tablesB, contains('test_table_b'));
          expect(tablesB, isNot(contains('test_table_a')));

          // Verify getTables() without schema parameter returns all tables
          final allTables = await crdtA.getTables();
          expect(allTables, contains('test_table_a'));
          expect(allTables, contains('test_table_b'));

          // Verify getTableKeys() works with schema isolation
          final keysA = await crdtA.getTableKeys('test_table_a');
          expect(keysA, contains('id'));

          final keysB = await crdtB.getTableKeys('test_table_b');
          expect(keysB, contains('id'));

          // Verify data isolation
          final dataA = await crdtA.query('SELECT * FROM test_table_a');
          expect(dataA.length, equals(1));
          expect(dataA[0]['id'], equals(1));
          expect(dataA[0]['value'], equals('value_a'));

          final dataB = await crdtB.query('SELECT * FROM test_table_b');
          expect(dataB.length, equals(1));
          expect(dataB[0]['id'], equals(2));
          expect(dataB[0]['value'], equals('value_b'));

          // Verify schema_a cannot see schema_b table
          expect(
            () => crdtA.query('SELECT * FROM test_table_b'),
            throwsA(isA<Exception>()),
          );

          // Verify schema_b cannot see schema_a table
          expect(
            () => crdtB.query('SELECT * FROM test_table_a'),
            throwsA(isA<Exception>()),
          );
        } finally {
          await crdtA.close();
          await crdtB.close();
        }
      } finally {
        // Clean up schemas
        await crdt.execute('DROP SCHEMA IF EXISTS schema_a CASCADE');
        await crdt.execute('DROP SCHEMA IF EXISTS schema_b CASCADE');
      }
    });

    test('poolSettings parameter takes precedence over sslMode and maxConnectionAge',
        () async {
      var onOpenCalled = false;

      final testCrdt = await PostgresCrdt.open(
        'testdb',
        username: 'postgres',
        password: 'postgres',
        sslMode: SslMode.require, // This should be ignored
        maxConnectionAge: const Duration(minutes: 5), // This should be ignored
        poolSettings: PoolSettings(
          sslMode: SslMode.disable,
          maxConnectionAge: const Duration(hours: 1),
          onOpen: (connection) async {
            onOpenCalled = true;
          },
        ),
      );

      try {
        // Trigger a query to ensure connection is opened
        await testCrdt.query('SELECT 1');

        // Verify onOpen was called
        expect(onOpenCalled, isTrue);
      } finally {
        await testCrdt.close();
      }
    });
  });
}
