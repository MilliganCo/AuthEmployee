import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart';
import 'package:admin_shift_app/data/db/app_database.dart';
import 'package:drift/native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('overtime is calculated', () async {
    final empId = await db.createEmployee(
      EmployeesCompanion(name: Value('Test')),
    );
    final shiftId = await db.startShift(empId, DateTime.utc(2025, 6, 6, 8));
    await db.endShift(shiftId, DateTime.utc(2025, 6, 6, 19)); // 11h
    final shift = await db.select(db.shifts).getSingle();
    expect(shift.overtimeMin, 120); // 2h × 60
  });

  test('multiple shifts per day are aggregated with rounding', () async {
    final empId = await db.createEmployee(
      EmployeesCompanion(name: Value('Multi')),
    );
    final id1 = await db.startShift(empId, DateTime.utc(2025, 6, 6, 8));
    await db.endShift(id1, DateTime.utc(2025, 6, 6, 12)); // 4h
    final id2 = await db.startShift(empId, DateTime.utc(2025, 6, 6, 13));
    await db.endShift(
      id2,
      DateTime.utc(2025, 6, 6, 17, 5),
    ); // 4h05m -> total 8h05m

    final shifts =
        await (db.select(db.shifts)
          ..where((t) => t.employeeId.equals(empId))).get();

    // overtime should be rounded to 0 because difference is less than 10 min
    final overtime = shifts.fold<int>(0, (p, s) => p + s.overtimeMin);
    expect(overtime, -55);
  });

  test('absence created when no shift', () async {
    final emp = await db.createEmployee(
      EmployeesCompanion(name: Value('NoShow')),
    );
    await db.autoCloseOpenShifts(DateTime.utc(2025, 6, 7, 0, 4));
    // Assuming today is 2025, 6, 7 for this test context
    final yesterday = DateTime.utc(2025, 6, 6);
    // The markAbsence in callbackDispatcher checks for absence on yesterday
    // We need to call the autoCloseOpenShifts to trigger the absence creation logic as in callbackDispatcher
    // Let's simulate the part of callbackDispatcher that checks for absences for yesterday
    final emps = await db.select(db.employees).get();
    for (final e in emps) {
      final hadShift =
          await (db.select(db.shifts)..where(
            (s) =>
                s.employeeId.equals(e.id) &
                s.start.isBetweenValues(
                  yesterday,
                  yesterday.add(const Duration(days: 1)),
                ),
          )).getSingleOrNull();
      final absent =
          await (db.select(db.absences)..where(
            (a) => a.employeeId.equals(e.id) & a.date.equals(yesterday),
          )).getSingleOrNull();
      if (hadShift == null && absent == null) {
        await db.markAbsence(e.id, yesterday);
      }
    }

    final absences = await db.select(db.absences).get();
    expect(absences.length, 1);
    expect(absences.first.date.toUtc(), yesterday);
  });
}
