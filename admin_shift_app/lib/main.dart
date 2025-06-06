import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import 'package:admin_shift_app/presentation/screens.dart';
import 'package:admin_shift_app/data/db/app_database.dart'; // Импорт AppDatabase
import 'package:drift/drift.dart'; // Явный импорт drift для операторов

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    final db = AppDatabase();
    final nowUtc = DateTime.now().toUtc();

    // 1) Автозакрыть незакрытые смены вчера
    await db.autoCloseOpenShifts(nowUtc);

    // 2) Проставить пропуски за вчера (пока без праздников)
    final yesterday = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day - 1);
    final emps = await db.select(db.employees).get();
    for (final e in emps) {
      // Проверяем, была ли смена у сотрудника вчера
      final startOfYesterdayUtc = DateTime.utc(yesterday.year, yesterday.month, yesterday.day);
      final endOfYesterdayUtc = startOfYesterdayUtc.add(const Duration(days: 1));

      final queryShifts = db.select(db.shifts)
        ..where(
            (s) => s.employeeId.equals(e.id) &
                   s.start.isBiggerOrEqualValue(startOfYesterdayUtc) &
                   s.start.isSmallerThanValue(endOfYesterdayUtc));

      final hadShift = await queryShifts.getSingleOrNull();

      // Проверяем, был ли уже записан пропуск за вчера
      final queryAbsences = db.select(db.absences)
        ..where((a) => a.employeeId.equals(e.id) & a.date.equals(yesterday));

      final absent = await queryAbsences.getSingleOrNull();

      // Если не было смены и нет записи о пропуске, отмечаем пропуск
      if (hadShift == null && absent == null) {
        await db.markAbsence(e.id, yesterday);
      }
    }
    await db.close();
    return true; // Task successful
  });
}

Future<void> main() async { // Изменено на Future<void>
  WidgetsFlutterBinding.ensureInitialized();
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: true, // Изменено на true для отладки workmanager
  );
  await Workmanager().registerPeriodicTask(
    'absenceScanner',
    'scanAbsences',
    frequency: const Duration(hours: 24),
    initialDelay: _delayTo00h05(),
    existingWorkPolicy: ExistingWorkPolicy.keep,
  );
  runApp(const ProviderScope(child: MyApp()));
}

Duration _delayTo00h05() {
  final now = DateTime.now();
  // Устанавливаем целевое время на 00:05 следующего дня в локальном времени
  final tomorrowAt0005 = DateTime(now.year, now.month, now.day).add(const Duration(days: 1, minutes: 5));
  // Если текущее время уже после 00:05, планируем на следующий день через один
  if (now.isAfter(tomorrowAt0005)) {
    return tomorrowAt0005.add(const Duration(days: 1)).difference(now);
  }
  return tomorrowAt0005.difference(now);
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Admin Shift',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const EmployeeListScreen(),
    );
  }
}
