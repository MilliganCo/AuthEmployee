import 'package:drift/drift.dart';
import 'package:admin_shift_app/data/db/connection/connection.dart'; // Импортируем новый файл

part 'app_database.g.dart';

/// ---------------------------
/// TABLES
/// ---------------------------

@DataClassName('Employee')
class Employees extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable().unique()();
}

@DataClassName('Shift')
class Shifts extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get employeeId =>
      integer().references(Employees, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get start => dateTime()();
  DateTimeColumn get end => dateTime().nullable()();
  IntColumn get durationMin =>
      integer().withDefault(const Constant(0))(); // реально отработано
  IntColumn get overtimeMin =>
      integer().withDefault(
        const Constant(0),
      )(); // переработка (+) или недоработка (–)
}

@DataClassName('Absence')
class Absences extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get employeeId =>
      integer().references(Employees, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get date => dateTime()(); // хранится как 00:00 UTC
  @override
  List<Set<Column>>? get uniqueKeys => [
    {employeeId, date},
  ];
}

@DataClassName('EmployeeComment')
class Comments extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get commentText => text()();
  IntColumn get employeeId =>
      integer().references(Employees, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get date =>
      dateTime()(); // Добавляем столбец для привязки к конкретному дню
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  IntColumn get manualOvertimeAdjustmentMin =>
      integer().withDefault(
        const Constant(0),
      )(); // Ручная корректировка переработки в минутах
  @override
  List<Set<Column>>? get uniqueKeys => [
    {employeeId, date},
  ];
}

/// ---------------------------
/// DATABASE
/// ---------------------------

@DriftDatabase(tables: [Employees, Shifts, Absences, Comments])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? openConnection());

  @override
  int get schemaVersion => 1;

  // --------------- EMPLOYEES
  Future<int> createEmployee(EmployeesCompanion data) =>
      into(employees).insert(data);

  Stream<List<Employee>> watchEmployees() =>
      (select(employees)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();

  Future<void> updateEmployee(int id, String name, String? phone) {
    return (update(employees)..where(
      (t) => t.id.equals(id),
    )).write(EmployeesCompanion(name: Value(name), phone: Value(phone)));
  }

  // --------------- SHIFTS
  Future<Shift?> currentOpenShift(int empId) =>
      (select(shifts)..where(
        (tbl) => tbl.employeeId.equals(empId) & tbl.end.isNull(),
      )).getSingleOrNull();

  /// Stream of open shift to react to DB changes
  Stream<Shift?> watchCurrentOpenShift(int empId) {
    print('Watching current open shift for employee $empId');
    return (select(shifts)..where(
      (tbl) => tbl.employeeId.equals(empId) & tbl.end.isNull(),
    )).watchSingleOrNull().map((shift) {
      print('watchCurrentOpenShift emitted: $shift');
      return shift;
    });
  }

  Future<int> startShift(int empId, DateTime startUtc) async {
    print('DB: Starting shift for employee $empId at $startUtc');
    // Закрыть все предыдущие открытые смены для этого сотрудника
    final openShifts =
        await (select(shifts)..where(
          (tbl) => tbl.employeeId.equals(empId) & tbl.end.isNull(),
        )).get();

    for (final s in openShifts) {
      print('DB: Closing previous open shift ${s.id}');
      await endShift(s.id, startUtc);
    }

    // Затем начать новую смену
    final newShiftId = await into(
      shifts,
    ).insert(ShiftsCompanion.insert(employeeId: empId, start: startUtc));
    print('DB: New shift started with id $newShiftId');
    return newShiftId;
  }

  Future<void> endShift(int shiftId, DateTime endUtc) async {
    print('DB: Ending shift $shiftId at $endUtc');
    final s =
        await (select(shifts)..where((t) => t.id.equals(shiftId))).getSingle();

    final minutes = endUtc.difference(s.start).inMinutes;

    // Update end and duration for the shift itself first
    await (update(shifts)..where(
      (t) => t.id.equals(shiftId),
    )).write(ShiftsCompanion(end: Value(endUtc), durationMin: Value(minutes)));
    print('DB: Shift $shiftId ended and updated.');
    // Больше не рассчитываем и не назначаем overtimeMin здесь,
    // так как это будет управляться через manualOvertimeAdjustmentMin в DailyRecord
  }

  // Новый метод для обновления времени начала и окончания смены
  Future<void> updateShiftTimes(
    int shiftId,
    DateTime newStartUtc,
    DateTime? newEndUtc,
  ) async {
    print(
      'DB: Updating shift $shiftId with new start $newStartUtc and end $newEndUtc',
    );
    int duration = 0;
    if (newEndUtc != null) {
      duration = newEndUtc.difference(newStartUtc).inMinutes;
    }

    await (update(shifts)..where((tbl) => tbl.id.equals(shiftId))).write(
      ShiftsCompanion(
        start: Value(newStartUtc),
        end: Value(newEndUtc),
        durationMin: Value(duration),
      ),
    );
    print('DB: Shift $shiftId times updated.');
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

  Future<void> adjustShiftOvertime(
    int employeeId,
    DateTime date,
    int minutesToAdjust,
  ) async {
    final existingComment = await getCommentForDay(
      employeeId,
      date,
    ); // Используем существующий метод

    if (existingComment != null) {
      // Обновляем существующий комментарий
      await (update(comments)
        ..where((tbl) => tbl.id.equals(existingComment.id))).write(
        CommentsCompanion(
          manualOvertimeAdjustmentMin: Value(
            existingComment.manualOvertimeAdjustmentMin + minutesToAdjust,
          ),
        ),
      );
    } else {
      // Создаем новую запись комментария только для корректировки часов
      await into(comments).insert(
        CommentsCompanion.insert(
          employeeId: employeeId,
          date: date,
          commentText: '', // Пустой текст, если только корректировка часов
          manualOvertimeAdjustmentMin: Value(minutesToAdjust),
        ),
      );
    }
  }

  // --------------- COMMENTS
  Future<void> addOrUpdateComment(
    int employeeId,
    DateTime date,
    String commentText, {
    int? manualOvertimeAdjustmentMin, // Добавляем необязательный параметр
  }) async {
    await into(comments).insert(
      CommentsCompanion.insert(
        employeeId: employeeId,
        date: date,
        commentText: commentText,
        manualOvertimeAdjustmentMin:
            manualOvertimeAdjustmentMin != null
                ? Value(manualOvertimeAdjustmentMin)
                : const Value.absent(),
      ),
      onConflict: DoUpdate(
        (old) => CommentsCompanion(
          commentText: Value(commentText),
          manualOvertimeAdjustmentMin:
              manualOvertimeAdjustmentMin != null
                  ? Value(manualOvertimeAdjustmentMin)
                  : const Value.absent(),
        ),
        target: [comments.employeeId, comments.date],
      ),
    );
  }

  Future<EmployeeComment?> getCommentForDay(int employeeId, DateTime date) {
    return (select(comments)..where(
      (c) => c.employeeId.equals(employeeId) & c.date.equals(date),
    )).getSingleOrNull();
  }

  Future<void> deleteComment(int employeeId, DateTime date) {
    return (delete(comments)..where(
      (c) => c.employeeId.equals(employeeId) & c.date.equals(date),
    )).go();
  }
}
