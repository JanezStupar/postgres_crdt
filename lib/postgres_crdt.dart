import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

import 'src/postgres_api.dart';

export 'package:postgres/postgres.dart' show PoolSettings, SslMode;
export 'package:sql_crdt/sql_crdt.dart';

class PostgresCrdt extends SqlCrdt {
  final Pool? _pool;
  final Set<String>? _excludeTables;

  PostgresCrdt._(super.db, this._pool, [this._excludeTables]);

  /// Open a database connection as a SqlCrdt instance.
  ///
  /// Use [sslMode] to specify the connection security with Postgres.
  ///
  /// Use [maxConnectionAge] to control how often the connection should reset.
  /// Because of an ongoing memory leak, this defaults to one day.
  /// Set to [null] to disable.
  ///
  /// Use [poolSettings] to provide custom pool settings including [onOpen]
  /// callbacks for per-connection initialization (e.g., setting search_path
  /// for schema isolation). If provided, [sslMode] and [maxConnectionAge]
  /// parameters are ignored in favor of the settings in [poolSettings].
  ///
  /// Use [excludeTables] to specify tables that should be excluded from CRDT
  /// initialization and discovery. Excluded tables will not appear in
  /// [getTables] results.
  static Future<PostgresCrdt> open(
    String databaseName, {
    String host = 'localhost',
    int port = 5432,
    String? username,
    String? password,
    SslMode? sslMode,
    Duration? maxConnectionAge = const Duration(days: 1),
    PoolSettings? poolSettings,
    Set<String>? excludeTables,
  }) async {
    final settings = poolSettings ??
        PoolSettings(
          sslMode: sslMode,
          maxConnectionAge: maxConnectionAge,
        );

    final db = Pool.withEndpoints(
      [
        Endpoint(
          host: host,
          port: port,
          database: databaseName,
          username: username,
          password: password,
        )
      ],
      settings: settings,
    );

    final crdt = PostgresCrdt._(PostgresApi(db), db, excludeTables);
    await crdt.init();
    return crdt;
  }

  /// Close the database connection and release resources.
  Future<void> close() async {
    await _pool?.close();
  }

  @override
  Future<Iterable<String>> getTables({String? schema}) async {
    final excludedList = _excludeTables?.toList();
    final hasExclusions = excludedList != null && excludedList.isNotEmpty;

    if (schema != null) {
      final baseQuery = '''
    SELECT table_name
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema = ?''';
      final query = hasExclusions
          ? '''$baseQuery
      AND table_name NOT IN (${List.filled(excludedList.length, '?').join(', ')})'''
          : baseQuery;

      final args = [schema, if (hasExclusions) ...excludedList];
      return (await this.query(query, args))
          .map((e) => e['table_name'] as String?)
          .whereType<String>();
    } else {
      final baseQuery = '''
    SELECT table_name
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE'
      AND table_schema = current_schema()''';
      final query = hasExclusions
          ? '''$baseQuery
      AND table_name NOT IN (${List.filled(excludedList.length, '?').join(', ')})'''
          : baseQuery;

      return (await this.query(query, hasExclusions ? excludedList : null))
          .map((e) => e['table_name'] as String?)
          .whereType<String>();
    }
  }

  @override
  Future<Iterable<String>> getTableKeys(String table, {String? schema}) async {
    if (schema != null) {
      return (await query('''
    SELECT a.attname AS name
    FROM
      pg_class AS c
      JOIN pg_index AS i ON c.oid = i.indrelid AND i.indisprimary
      JOIN pg_attribute AS a ON c.oid = a.attrelid AND a.attnum = ANY(i.indkey)
    WHERE c.oid = (?1 || '.' || ?2)::regclass
  ''', [schema, table])).map((e) => e['name'] as String);
    } else {
      return (await query('''
    SELECT a.attname AS name
    FROM
      pg_class AS c
      JOIN pg_index AS i ON c.oid = i.indrelid AND i.indisprimary
      JOIN pg_attribute AS a ON c.oid = a.attrelid AND a.attnum = ANY(i.indkey)
    WHERE c.oid = (current_schema() || '.' || ?1)::regclass
  ''', [table])).map((e) => e['name'] as String);
    }
  }
}
