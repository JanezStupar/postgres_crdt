import 'dart:typed_data';

import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

class PostgresApi extends DatabaseApi {
  final Session _connection;

  PostgresApi(this._connection);

  @override
  Future<ExecuteResult> execute(String sql, [List<Object?>? args]) async {
    final convertedArgs = _convertArgs(args);
    final query = sql.asQuery;
    final result = await _connection.execute(query, parameters: convertedArgs);

    // Return QueryResult if data was returned, VoidResult otherwise
    return result.isEmpty
        ? const VoidResult()
        : QueryResult(
            result.map((row) => row.toColumnMap()).toList(),
            sql: sql,
          );
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql,
      [List<Object?>? args]) async {
    final convertedArgs = _convertArgs(args);
    return (await _connection.execute(sql.asQuery, parameters: convertedArgs))
        .map((e) => e.toColumnMap())
        .toList();
  }

  @override
  Future<void> transaction(Future<void> Function(DatabaseApi txn) actions) =>
      (_connection as SessionExecutor).runTx((t) => actions(PostgresApi(t)));

  @override
  Future<void> executeBatch(Future<void> Function(WriteApi api) actions) async {
    await (_connection as SessionExecutor).runTx((t) async {
      final batch = _BatchApi(t);
      await actions(batch);
      await batch.commit();
    });
  }
}

class _BatchApi extends WriteApi {
  final Session _connection;
  String? _batchedSql;
  Statement? _batch;

  _BatchApi(this._connection);

  @override
  Future<ExecuteResult> execute(String sql, [List<Object?>? args]) async {
    if (sql != _batchedSql) {
      await _batch?.dispose();
      _batch = await _connection.prepare(sql.asQuery);
      _batchedSql = sql;
    }

    await _batch!.run(_convertArgs(args));
    // Batch operations don't return data
    return const VoidResult();
  }

  Future<void> commit() async {
    await _batch!.dispose();
  }
}

extension on String {
  Sql get asQuery {
    // Check if SQL uses PostgreSQL-style $N placeholders
    final usesPostgresPlaceholders = RegExp(r'(?<!\\)\$\d+').hasMatch(this);

    // Check if SQL uses SQLite-style placeholders (numbered or automatic)
    final usesSqlitePlaceholders = RegExp(r'\?(\d+)?').hasMatch(this);

    if (usesPostgresPlaceholders) {
      // SQL has $N placeholders - convert to ?N first, then use Sql.indexed
      // This is needed because Sql() treats the string as literal with no placeholders
      final sqlWithQuestion = replaceAllMapped(
        RegExp(r'\$(\d+)'),
        (match) => '?${match.group(1)}',
      );
      final query = Sql.indexed(sqlWithQuestion, substitution: '?');
      _logPlaceholderStatus(query, this);
      return query;
    } else if (usesSqlitePlaceholders) {
      // SQL has ?N placeholders, convert to $N
      final query = Sql.indexed(this, substitution: '?');
      _logPlaceholderStatus(query, this);
      return query;
    } else {
      // No placeholders detected - return as-is
      // This handles queries like "SELECT * FROM table" with no parameters
      return Sql(this);
    }
  }

  /// Previously emitted placeholder diagnostics; now intentionally silent.
  void _logPlaceholderStatus(Sql query, String originalSql) {}
}

/// Ensures binary arguments keep their byte semantics when sent to Postgres.
List<Object?>? _convertArgs(List<Object?>? args) {
  if (args == null) return null;

  var didChange = false;
  final converted = List<Object?>.of(args, growable: false);

  for (var i = 0; i < converted.length; i++) {
    final value = converted[i];
    if (value is TypedValue) {
      continue;
    }
    if (value is Uint8List) {
      converted[i] = TypedValue(Type.byteArray, value);
      didChange = true;
    }
  }

  return didChange ? converted : args;
}
