import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Открывает подключение к базе данных для веб-платформ.
LazyDatabase openConnection() => LazyDatabase(() async {
  // ВНИМАНИЕ: Для работы на вебе необходимо загрузить
  // sqlite3.wasm и drift_worker.js
  // из релизов пакета sqlite3 (https://github.com/simolus3/sqlite3.dart/releases)
  // и поместить их в папку 'web/' вашего проекта.
  final result = await WasmDatabase.open(
    databaseName: 'admin_shift_app', // Название файла для IndexedDb
    sqlite3Uri: Uri.parse('/sqlite3.wasm'),
    driftWorkerUri: Uri.parse('/drift_worker.js'),
  );
  return result.resolvedExecutor;
});
