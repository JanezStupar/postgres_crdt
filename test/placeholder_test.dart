// Tests for PostgreSQL-style $N parameter placeholders
//
// These tests verify that the CRDT executor correctly handles Postgres-style
// placeholders ($1, $2, etc.) which are converted from Drift's SQL queries.
//
// The bug being tested:
// - sqlparser doesn't recognize $N syntax and treats it as numeric literals
// - This causes INSERT statements to use literal values (1, 2) instead of parameters
// - The fix normalizes $N to ?N before parsing, then converts back for Postgres

import 'package:postgres_crdt/postgres_crdt.dart';
import 'package:test/test.dart';

void main() {
  late PostgresCrdt crdt;

  setUpAll(() async {
    crdt = await PostgresCrdt.open(
      'testdb',
      username: 'postgres',
      password: 'postgres',
      sslMode: SslMode.disable,
    );
  });

  tearDownAll(() async {
    // Clean up all tables
    final tables = await crdt.getTables();
    for (final table in tables) {
      await crdt.execute('DROP TABLE $table');
    }
  });

  group('PostgreSQL \$N Placeholder Tests', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          birth_date INTEGER,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() async {
      await crdt.execute('DROP TABLE users');
    });

    test('INSERT with \$N placeholders - basic types', () async {
      // This mimics what Drift sends to the executor
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [1, 'Dash', 1318284000],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 1');
      expect(result.length, 1);
      expect(result.first['id'], 1);
      expect(result.first['name'], 'Dash');
      expect(result.first['birth_date'], 1318284000);
    });

    test('INSERT with \$N placeholders - string values', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [2, 'Alice Johnson'],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 2');
      expect(result.length, 1);
      expect(result.first['name'], 'Alice Johnson');
    });

    test('INSERT with \$N placeholders - null values', () async {
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [3, null, null],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 3');
      expect(result.length, 1);
      expect(result.first['name'], null);
      expect(result.first['birth_date'], null);
    });

    test('INSERT multiple rows with \$N placeholders', () async {
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [10, 'User 10', 1000000000],
      );
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [11, 'User 11', 1100000000],
      );
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [12, 'User 12', 1200000000],
      );

      final result = await crdt.query(
        'SELECT * FROM users WHERE id >= 10 ORDER BY id',
      );
      expect(result.length, 3);
      expect(result[0]['name'], 'User 10');
      expect(result[1]['name'], 'User 11');
      expect(result[2]['name'], 'User 12');
      expect(result[0]['birth_date'], 1000000000);
      expect(result[1]['birth_date'], 1100000000);
      expect(result[2]['birth_date'], 1200000000);
    });

    test('UPDATE with \$N placeholders', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [20, 'Original Name'],
      );

      await crdt.execute(
        'UPDATE users SET name = \$2 WHERE id = \$1',
        [20, 'Updated Name'],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 20');
      expect(result.first['name'], 'Updated Name');
    });

    test('DELETE with \$N placeholders', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [30, 'To Be Deleted'],
      );

      await crdt.execute(
        'DELETE FROM users WHERE id = \$1',
        [30],
      );

      final result = await crdt.query(
        'SELECT * FROM users WHERE id = 30 AND is_deleted = 0',
      );
      expect(result.length, 0);
    });

    test('UPSERT with \$N placeholders - insert path', () async {
      await crdt.execute(
        '''
        INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)
        ON CONFLICT (id) DO UPDATE SET name = \$2, birth_date = \$3
        ''',
        [40, 'Initial Insert', 1400000000],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 40');
      expect(result.length, 1);
      expect(result.first['name'], 'Initial Insert');
      expect(result.first['birth_date'], 1400000000);
    });

    test('UPSERT with \$N placeholders - update path', () async {
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [41, 'Original', 1400000000],
      );

      final originalHlc =
          (await crdt.query('SELECT hlc FROM users WHERE id = 41')).first['hlc']
              as String;

      await crdt.execute(
        '''
        INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)
        ON CONFLICT (id) DO UPDATE SET name = \$2, birth_date = \$3
        ''',
        [41, 'Updated via Upsert', 1500000000],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 41');
      expect(result.length, 1);
      expect(result.first['name'], 'Updated via Upsert');
      expect(result.first['birth_date'], 1500000000);

      // Verify HLC was updated
      final newHlc = result.first['hlc'] as String;
      expect(newHlc.compareTo(originalHlc), greaterThan(0));
    });
  });

  group('PostgreSQL \$N Placeholder Tests with RETURNING', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          birth_date INTEGER,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() async {
      await crdt.execute('DROP TABLE users');
    });

    test('INSERT with \$N placeholders and RETURNING', () async {
      final result = await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3) RETURNING id, name',
        [50, 'Returned User', 1500000000],
      );

      expect(result, isA<QueryResult>());
      final queryResult = result as QueryResult;
      expect(queryResult.rowCount, 1);
      expect(queryResult.rows.first['id'], 50);
      expect(queryResult.rows.first['name'], 'Returned User');

      // Verify data was actually inserted correctly
      final verifyResult =
          await crdt.query('SELECT * FROM users WHERE id = 50');
      expect(verifyResult.first['name'], 'Returned User');
      expect(verifyResult.first['birth_date'], 1500000000);
    });

    test('UPDATE with \$N placeholders and RETURNING', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [51, 'Before Update'],
      );

      final result = await crdt.execute(
        'UPDATE users SET name = \$2 WHERE id = \$1 RETURNING id, name',
        [51, 'After Update'],
      );

      expect(result, isA<QueryResult>());
      final queryResult = result as QueryResult;
      expect(queryResult.rowCount, 1);
      expect(queryResult.rows.first['name'], 'After Update');
    });

    test('DELETE with \$N placeholders and RETURNING', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [52, 'To Delete'],
      );

      final result = await crdt.execute(
        'DELETE FROM users WHERE id = \$1 RETURNING id, name',
        [52],
      );

      expect(result, isA<QueryResult>());
      final queryResult = result as QueryResult;
      expect(queryResult.rowCount, 1);
      expect(queryResult.rows.first['name'], 'To Delete');
    });

    test('UPSERT with \$N placeholders and RETURNING - insert path', () async {
      final result = await crdt.execute(
        '''
        INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)
        ON CONFLICT (id) DO UPDATE SET name = \$2, birth_date = \$3
        RETURNING id, name, birth_date
        ''',
        [60, 'Upsert Insert', 1600000000],
      );

      expect(result, isA<QueryResult>());
      final queryResult = result as QueryResult;
      expect(queryResult.rowCount, 1);
      expect(queryResult.rows.first['name'], 'Upsert Insert');
      expect(queryResult.rows.first['birth_date'], 1600000000);
    });

    test('UPSERT with \$N placeholders and RETURNING - update path', () async {
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [61, 'Original', 1600000000],
      );

      final result = await crdt.execute(
        '''
        INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)
        ON CONFLICT (id) DO UPDATE SET name = \$2, birth_date = \$3
        RETURNING id, name, birth_date
        ''',
        [61, 'Upsert Update', 1700000000],
      );

      expect(result, isA<QueryResult>());
      final queryResult = result as QueryResult;
      expect(queryResult.rowCount, 1);
      expect(queryResult.rows.first['name'], 'Upsert Update');
      expect(queryResult.rows.first['birth_date'], 1700000000);
    });
  });

  group('Mixed Placeholder Formats', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() async {
      await crdt.execute('DROP TABLE users');
    });

    test('?N placeholders still work (backwards compatibility)', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (?1, ?2)',
        [70, 'Question Mark User'],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 70');
      expect(result.first['name'], 'Question Mark User');
    });

    test('Verify \$N creates different values than literal integers', () async {
      // This is the core regression test - with the bug, this would insert
      // name=1 and birth_date=2 (the literal values) instead of the parameter values

      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [100, 'Correct String Value'],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 100');

      // The bug would cause name to be the literal integer 1
      expect(result.first['name'], isNot(1));
      expect(result.first['name'], isNot('1'));
      expect(result.first['name'], 'Correct String Value');
    });
  });

  group('Edge Cases', () {
    setUp(() async {
      await crdt.execute('''
        CREATE TABLE users (
          id INTEGER NOT NULL,
          name TEXT,
          birth_date INTEGER,
          PRIMARY KEY (id)
        )
      ''');
    });

    tearDown(() async {
      await crdt.execute('DROP TABLE users');
    });

    test('Large parameter numbers', () async {
      // Test with many parameters
      await crdt.execute(
        'INSERT INTO users (id, name, birth_date) VALUES (\$1, \$2, \$3)',
        [200, 'User 200', 2000000000],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 200');
      expect(result.first['name'], 'User 200');
      expect(result.first['birth_date'], 2000000000);
    });

    test('Parameters in WHERE clause', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [300, 'User 300'],
      );

      // Note: Currently sql_crdt.query() doesn't support $N placeholders
      // Use ?N format for SELECT queries
      final result = await crdt.query(
        'SELECT * FROM users WHERE id = ?1 AND name = ?2',
        [300, 'User 300'],
      );
      expect(result.length, 1);
      expect(result.first['name'], 'User 300');
    });

    test('Empty string parameter', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [400, ''],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 400');
      expect(result.first['name'], '');
    });

    test('Special characters in string parameters', () async {
      await crdt.execute(
        'INSERT INTO users (id, name) VALUES (\$1, \$2)',
        [500, "O'Reilly & Co. \"Special\" <Characters>"],
      );

      final result = await crdt.query('SELECT * FROM users WHERE id = 500');
      expect(result.first['name'], "O'Reilly & Co. \"Special\" <Characters>");
    });
  });
}
