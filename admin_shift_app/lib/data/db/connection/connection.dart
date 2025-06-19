import 'package:drift/drift.dart';

// Этот условный импорт выбирает правильную реализацию connection.dart
// в зависимости от целевой платформы (веб или не-веб).
export 'connection_io.dart' if (dart.library.html) 'connection_web.dart';
