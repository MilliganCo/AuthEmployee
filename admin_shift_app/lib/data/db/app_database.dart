import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'app_database.g.dart';

/// ---------------------------
/// TABLES
/// ---------------------------

@DataClassName('Employee')
class Employees extends Table {
  IntColumn get id    => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
}

@DataClassName('Shift')
class Shifts extends Table {
  IntColumn get id         => integer().autoIncrement()();
  IntColumn get employeeId => integer()
      .references(Employees, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end   => dateTime().nullable()();
  IntColumn get durationMin =>
      integer().withDefault(const Constant(0))();              // реально отработано
  IntColumn get overtimeMin =>
      integer().withDefault(const Constant(0))();              // переработка (+) или недоработка (–)
}

@DataClassName('Absence')
class Absences extends Table {
  IntColumn get id         => integer().autoIncrement()();
  IntColumn get employeeId => integer()
      .references(Employees, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get date  => dateTime()();                    // хранится как 00:00 UTC
  @override
  List<Set<Column>>? get uniqueKeys => [
    {employeeId, date},
  ];
}

@DataClassName('EmployeeComment')
class Comments extends Table {
  IntColumn get id         => integer().autoIncrement()();
  TextColumn get commentText      => text()();
  IntColumn get employeeId => integer()
      .references(Employees, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get createdAt =>
      dateTime().withDefault(currentDateAndTime)();
}

/// ---------------------------
/// DATABASE
/// ---------------------------

@DriftDatabase(
  tables: [Employees, Shifts, Absences, Comments],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  @override
  int get schemaVersion => 1;

  // --------------- EMPLOYEES
  Future<int> createEmployee(EmployeesCompanion data) =>
      into(employees).insert(data);

  Stream<List<Employee>> watchEmployees() =>
      (select(employees)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  // --------------- SHIFTS
  Future<Shift?> currentOpenShift(int empId) =>
      (select(shifts)
            ..where((tbl) => tbl.employeeId.equals(empId) & tbl.end.isNull()))
          .getSingleOrNull();

  /// Stream of open shift to react to DB changes
  Stream<Shift?> watchCurrentOpenShift(int empId) =>
      (select(shifts)
            ..where((tbl) => tbl.employeeId.equals(empId) & tbl.end.isNull()))
          .watchSingleOrNull();

  Future<int> startShift(int empId, DateTime startUtc) =>
      into(shifts).insert(ShiftsCompanion.insert(
        employeeId: empId,
        start: startUtc,
      ));

  Future<void> endShift(int shiftId, DateTime endUtc) async {
    final s = await (select(shifts)..where((t) => t.id.equals(shiftId)))
        .getSingle();

    final minutes = endUtc.difference(s.start).inMinutes;

    // Update end and duration for the shift itself first
    await (update(shifts)..where((t) => t.id.equals(shiftId))).write(
      ShiftsCompanion(
        end: Value(endUtc),
        durationMin: Value(minutes),
      ),
    );

    // Recalculate overtime for all shifts of that employee on the same day
    final dayStart = DateTime.utc(s.start.year, s.start.month, s.start.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final dayShifts = await (select(shifts)
          ..where((tbl) => tbl.employeeId.equals(s.employeeId) &
              tbl.start.isBiggerOrEqualValue(dayStart) &
              tbl.start.isSmallerThanValue(dayEnd) &
              tbl.end.isNotNull()))
        .get();

    if (dayShifts.isEmpty) return; // should not happen, but guard

    final totalMinutes =
        dayShifts.fold<int>(0, (prev, sh) => prev + sh.durationMin);
    int overtime = totalMinutes - 540; // 9h * 60
    if (overtime.abs() <= 10) overtime = 0; // rounding +/- 10 minutes

    // Clear previous overtime values for the day
    await (update(shifts)
          ..where((tbl) => tbl.employeeId.equals(s.employeeId) &
              tbl.start.isBiggerOrEqualValue(dayStart) &
              tbl.start.isSmallerThanValue(dayEnd)))
        .write(const ShiftsCompanion(overtimeMin: Value(0)));

    // Assign overtime to the last shift of the day
    dayShifts.sort((a, b) => a.end!.compareTo(b.end!));
    final lastShift = dayShifts.last;
    await (update(shifts)..where((t) => t.id.equals(lastShift.id))).write(
      ShiftsCompanion(overtimeMin: Value(overtime)),
    );
  }

  // --------------- ABSENCES
  Future<void> markAbsence(int empId, DateTime dateUtc) async {
    await into(absences).insertOnConflictUpdate(
      AbsencesCompanion.insert(employeeId: empId, date: dateUtc),
    );
  }

  // --------------- AUTO CLOSE SHIFTS
  Future<void> autoCloseOpenShifts(DateTime nowUtc) async {
    final open = await (select(shifts)..where((s) => s.end.isNull())).get();
    for (final s in open) {
      // закрываем на 00:00 локального дня сотрудника (Europe/Tallinn = UTC+3 летом)
      final local = nowUtc.toLocal();
      final end = DateTime.utc(local.year, local.month, local.day, 0, 0);
      await endShift(s.id, end);
    }
  }
}

/// ---------------------------
/// CONNECTION
/// ---------------------------
LazyDatabase _open() => LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final dbFile = File(p.join(dir.path, 'admin_shift.db'));
      return NativeDatabase(dbFile);
    }); 