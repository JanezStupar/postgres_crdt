import 'package:postgres/postgres.dart';
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

          // Verify getTables() respects current schema (set via search_path)
          final tablesA = await crdtA.getTables();
          expect(tablesA, contains('test_table_a'));
          expect(tablesA, isNot(contains('test_table_b')));

          final tablesB = await crdtB.getTables();
          expect(tablesB, contains('test_table_b'));
          expect(tablesB, isNot(contains('test_table_a')));

          // Verify getTables() with explicit schema parameter
          final explicitA = await crdtA.getTables(schema: 'schema_a');
          expect(explicitA, contains('test_table_a'));
          expect(explicitA, isNot(contains('test_table_b')));

          final explicitB = await crdtB.getTables(schema: 'schema_b');
          expect(explicitB, contains('test_table_b'));
          expect(explicitB, isNot(contains('test_table_a')));

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

    test(
        'poolSettings parameter takes precedence over sslMode and maxConnectionAge',
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

    test('excludeTables filters tables from getTables()', () async {
      // Create test tables
      await crdt.execute('''
        CREATE TABLE IF NOT EXISTS included_table (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
      await crdt.execute('''
        CREATE TABLE IF NOT EXISTS excluded_table (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');

      try {
        // Create CRDT instance with excludeTables
        final testCrdt = await PostgresCrdt.open(
          'testdb',
          username: 'postgres',
          password: 'postgres',
          sslMode: SslMode.disable,
          excludeTables: {'excluded_table'},
        );

        try {
          // Get tables and verify excluded table is not in the list
          final tables = await testCrdt.getTables();
          final tableList = tables.toList();

          expect(
            tableList.contains('excluded_table'),
            isFalse,
            reason: 'excluded_table should not appear in getTables() results',
          );
          expect(
            tableList.contains('included_table'),
            isTrue,
            reason: 'included_table should appear in getTables() results',
          );
        } finally {
          await testCrdt.close();
        }
      } finally {
        await crdt.execute('DROP TABLE IF EXISTS included_table');
        await crdt.execute('DROP TABLE IF EXISTS excluded_table');
      }
    });

    test('excludeTables with empty set still retrieves all tables', () async {
      // Create test table
      await crdt.execute('''
        CREATE TABLE IF NOT EXISTS test_table_empty (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');

      try {
        // Create CRDT instance with empty excludeTables set
        final testCrdt = await PostgresCrdt.open(
          'testdb',
          username: 'postgres',
          password: 'postgres',
          sslMode: SslMode.disable,
          excludeTables: <String>{},
        );

        try {
          final tables = await testCrdt.getTables();
          final tableList = tables.toList();

          expect(
            tableList.contains('test_table_empty'),
            isTrue,
            reason:
                'test_table_empty should appear when excludeTables is empty',
          );
        } finally {
          await testCrdt.close();
        }
      } finally {
        await crdt.execute('DROP TABLE IF EXISTS test_table_empty');
      }
    });

    test('onlyTables limits schema discovery to provided set', () async {
      await crdt.execute('''
        CREATE TABLE IF NOT EXISTS only_table_a (
          id INTEGER PRIMARY KEY,
          name TEXT
        )
      ''');
      await crdt.execute('''
        CREATE TABLE IF NOT EXISTS only_table_b (
          id INTEGER PRIMARY KEY,
          name TEXT
        )
      ''');

      try {
        final testCrdt = await PostgresCrdt.open(
          'testdb',
          username: 'postgres',
          password: 'postgres',
          sslMode: SslMode.disable,
          onlyTables: {'only_table_a'},
        );

        try {
          final tables = await testCrdt.getTables();
          expect(tables, contains('only_table_a'));
          expect(tables, isNot(contains('only_table_b')));
        } finally {
          await testCrdt.close();
        }
      } finally {
        await crdt.execute('DROP TABLE IF EXISTS only_table_a');
        await crdt.execute('DROP TABLE IF EXISTS only_table_b');
      }
    });

    test('getTables ignores tables missing CRDT metadata', () async {
      // Create a direct database connection to bypass CRDT operations
      final directPool = Pool.withEndpoints(
        [
          Endpoint(
            host: 'localhost',
            port: 5432,
            database: 'testdb',
            username: 'postgres',
            password: 'postgres',
          )
        ],
        settings: PoolSettings(sslMode: SslMode.disable),
      );

      try {
        // Create a table without CRDT metadata using direct connection
        await directPool.execute('''
          CREATE TABLE IF NOT EXISTS no_crdt_table (
            id INTEGER PRIMARY KEY,
            name TEXT
          )
        ''');

        // Verify the table doesn't appear in getTables()
        final tables = await crdt.getTables();
        expect(tables, isNot(contains('no_crdt_table')));
      } finally {
        // Clean up using direct connection
        await directPool.execute('DROP TABLE IF EXISTS no_crdt_table');
        await directPool.close();
      }
    });
  });
}
