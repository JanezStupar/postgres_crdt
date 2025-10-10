import 'package:postgres/postgres.dart';
import 'package:sql_crdt/sql_crdt.dart';

class PostgresApi extends DatabaseApi {
  final Session _connection;

  PostgresApi(this._connection);

  @override
  Future<ExecuteResult> execute(String sql, [List<Object?>? args]) async {
    final result = await _connection.execute(sql.asQuery, parameters: args);

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
          [List<Object?>? args]) async =>
      (await _connection.execute(sql.asQuery, parameters: args))
          .map((e) => e.toColumnMap())
          .toList();

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

    await _batch!.run(args);
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

    if (usesPostgresPlaceholders) {
      // SQL already has $N placeholders, return as-is
      // The Sql() constructor treats the string as literal SQL with existing $N placeholders
      return Sql(this);
    } else {
      // SQL has ?N placeholders, convert to $N
      return Sql.indexed(this, substitution: '?');
    }
  }
}
