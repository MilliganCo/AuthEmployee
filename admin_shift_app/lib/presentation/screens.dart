import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as drift;
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:async';
import '../data/db/app_database.dart';
import '../providers/database_provider.dart';
import 'widgets/edit_shift_dialog.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

// -----------------------------------------------------------------------------
// Auxiliary models
// -----------------------------------------------------------------------------
class MonthlySummary {
  final int totalMinutes;
  final int overtimeMinutes;
  final int absences;

  const MonthlySummary({
    required this.totalMinutes,
    required this.overtimeMinutes,
    required this.absences,
  });

  double get totalHours => totalMinutes / 60;
  double get overtimeHours => overtimeMinutes / 60;
}

// -----------------------------------------------------------------------------
// Providers
// -----------------------------------------------------------------------------

/// Хранит текст поискового запроса
final employeeSearchProvider = StateProvider<String>((ref) => '');

/// Поток отфильтрованных сотрудников
final employeesFilteredProvider = StreamProvider<List<Employee>>((ref) {
  final query = ref.watch(employeeSearchProvider);
  final db = ref.watch(dbProvider);
  return db.watchEmployees().map((list) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return list;
    return list.where((e) {
      return e.name.toLowerCase().contains(q) ||
          (e.phone?.toLowerCase().contains(q) ?? false);
    }).toList();
  });
});

/// Для каждой карточки сотрудника получаем открытую смену (если есть)
final currentShiftProvider = StreamProvider.family<Shift?, int>((ref, empId) {
  final db = ref.watch(dbProvider);
  return db.watchCurrentOpenShift(empId);
});

/// Detailed daily record for a month
class DailyRecord {
  final DateTime date;
  final List<Shift> shifts;
  final bool absent;
  final EmployeeComment? comment;

  const DailyRecord({
    required this.date,
    required this.shifts,
    required this.absent,
    this.comment,
  });

  int get totalMinutes => shifts.fold<int>(0, (p, s) => p + s.durationMin);
  double get workHours => totalMinutes / 60;
  int get standardWorkMinutes =>
      date.weekday == DateTime.sunday
          ? 0
          : 9 * 60; // 0 для воскресенья, 9 часов для остальных
  double get overtimeHours {
    final calculatedOvertime = (totalMinutes - standardWorkMinutes).toDouble();
    final manualAdjustment =
        (comment?.manualOvertimeAdjustmentMin ?? 0).toDouble();
    return (calculatedOvertime + manualAdjustment) / 60;
  }

  DateTime? get firstStart => shifts.isEmpty ? null : shifts.first.start;
  DateTime? get lastEnd => shifts.isNotEmpty ? shifts.last.end : null;
  bool get isWeekend =>
      date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
  double get salaryDeviation => overtimeHours - (absent ? 9 : 0);

  // Новый геттер для форматирования интервалов смен
  String get shiftIntervalsText {
    if (shifts.isEmpty) return '';
    return shifts
        .map((s) {
          final start = DateFormat.Hm().format(s.start.toLocal());
          final end =
              s.end != null ? DateFormat.Hm().format(s.end!.toLocal()) : '—';
          return '$start-$end';
        })
        .join(', ');
  }
}

/// Все записи по дням для сотрудника за текущий месяц
final dailyRecordsProvider = StreamProvider.family<List<DailyRecord>, int>((
  ref,
  empId,
) {
  final db = ref.watch(dbProvider);
  final now = DateTime.now().toUtc();
  final first = DateTime.utc(now.year, now.month, 1);
  final next = DateTime.utc(now.year, now.month + 1, 1);

  print('dailyRecordsProvider: empId=$empId, first=$first, next=$next');

  final shiftsStream =
      (db.select(db.shifts)..where(
        (tbl) =>
            tbl.employeeId.equals(empId) &
            tbl.start.isBiggerOrEqualValue(first) &
            tbl.start.isSmallerThanValue(next),
      )).watch();
  final absencesStream =
      (db.select(db.absences)..where(
        (tbl) =>
            tbl.employeeId.equals(empId) &
            tbl.date.isBiggerOrEqualValue(first) &
            tbl.date.isSmallerThanValue(next),
      )).watch();
  final commentsStream =
      (db.select(db.comments)..where(
        (tbl) =>
            tbl.employeeId.equals(empId) &
            tbl.date.isBiggerOrEqualValue(first) &
            tbl.date.isSmallerThanValue(next),
      )).watch();

  return Rx.combineLatest3<
    List<Shift>,
    List<Absence>,
    List<EmployeeComment>,
    List<DailyRecord>
  >(shiftsStream, absencesStream, commentsStream, (shifts, absences, comments) {
    print(
      'dailyRecordsProvider: shifts.length=${shifts.length}, absences.length=${absences.length}, comments.length=${comments.length}',
    );
    final mapShifts = <DateTime, List<Shift>>{};
    for (final s in shifts) {
      final d = DateTime.utc(s.start.year, s.start.month, s.start.day);
      mapShifts.putIfAbsent(d, () => []).add(s);
    }
    for (final list in mapShifts.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    final absenceDates = absences.map((a) => a.date).toSet();
    final mapComments = <DateTime, EmployeeComment>{};
    for (final c in comments) {
      final d = DateTime.utc(c.date.year, c.date.month, c.date.day);
      mapComments[d] = c;
    }

    final records = <DailyRecord>[];
    for (
      var day = first;
      day.isBefore(next);
      day = day.add(const Duration(days: 1))
    ) {
      final d = DateTime.utc(day.year, day.month, day.day);
      records.add(
        DailyRecord(
          date: d,
          shifts: mapShifts[d] ?? [],
          absent: absenceDates.contains(d),
          comment: mapComments[d],
        ),
      );
    }
    return records;
  });
});

class EmployeeMonthlySummary {
  final Employee employee;
  final MonthlySummary summary;

  EmployeeMonthlySummary(this.employee, this.summary);
}

/// Сводка за месяц по всем сотрудникам за текущий месяц
final allEmployeesMonthlyProvider = StreamProvider<
  List<EmployeeMonthlySummary>
>((ref) {
  final db = ref.watch(dbProvider);
  final now = DateTime.now().toUtc();
  final first = DateTime.utc(now.year, now.month, 1);
  final next = DateTime.utc(now.year, now.month + 1, 1);

  final employees = db.watchEmployees();
  final shifts =
      (db.select(db.shifts)..where(
        (t) =>
            t.start.isBiggerOrEqualValue(first) &
            t.start.isSmallerThanValue(next),
      )).watch();
  final absences =
      (db.select(db.absences)..where(
        (a) =>
            a.date.isBiggerOrEqualValue(first) &
            a.date.isSmallerThanValue(next),
      )).watch();
  final comments =
      (db.select(db.comments)..where(
        (c) =>
            c.date.isBiggerOrEqualValue(first) &
            c.date.isSmallerThanValue(next),
      )).watch();

  return Rx.combineLatest4(employees, shifts, absences, comments, (
    List<Employee> emps,
    List<Shift> sh,
    List<Absence> abs,
    List<EmployeeComment> cms,
  ) {
    return emps.map((e) {
      final eshifts = sh.where((s) => s.employeeId == e.id).toList();
      final eabs = abs.where((a) => a.employeeId == e.id).toList();
      final ecomments = cms.where((c) => c.employeeId == e.id).toList();

      final totalMin = eshifts.fold<int>(0, (p, s) => p + s.durationMin);

      final mapEshifts = <DateTime, List<Shift>>{};
      for (final s in eshifts) {
        final d = DateTime.utc(s.start.year, s.start.month, s.start.day);
        mapEshifts.putIfAbsent(d, () => []).add(s);
      }
      final mapEcomments = <DateTime, EmployeeComment>{};
      for (final c in ecomments) {
        final d = DateTime.utc(c.date.year, c.date.month, c.date.day);
        mapEcomments[d] = c;
      }

      int totalOvertimeMin = 0;
      int totalAdjustedMinutes =
          totalMin; // Начинаем с фактически отработанных минут
      for (
        var day = first;
        day.isBefore(next);
        day = day.add(const Duration(days: 1))
      ) {
        final d = DateTime.utc(day.year, day.month, day.day);
        final dailyShifts = mapEshifts[d] ?? [];
        final dailyComment = mapEcomments[d];
        final dailyTotalMinutes = dailyShifts.fold<int>(
          0,
          (p, s) => p + s.durationMin,
        );
        final standardWorkMinutes = d.weekday == DateTime.sunday ? 0 : 9 * 60;
        final calculatedOvertime = dailyTotalMinutes - standardWorkMinutes;
        final manualAdjustment = dailyComment?.manualOvertimeAdjustmentMin ?? 0;
        totalOvertimeMin += (calculatedOvertime + manualAdjustment);
        totalAdjustedMinutes +=
            manualAdjustment; // Добавляем ручную корректировку к общему количеству минут
      }

      final summary = MonthlySummary(
        totalMinutes: totalAdjustedMinutes,
        overtimeMinutes: totalOvertimeMin,
        absences: eabs.length,
      );
      return EmployeeMonthlySummary(e, summary);
    }).toList();
  });
});

/// Месячная статистика по сотруднику
final monthlySummaryProvider = StreamProvider.family<MonthlySummary, int>((
  ref,
  empId,
) {
  final db = ref.watch(dbProvider);
  final now = DateTime.now().toUtc();
  final firstOfMonth = DateTime.utc(now.year, now.month, 1);
  final firstOfNext = DateTime.utc(now.year, now.month + 1, 1);

  final shiftsStream =
      (db.select(db.shifts)..where(
        (tbl) =>
            tbl.employeeId.equals(empId) &
            tbl.start.isBiggerOrEqualValue(firstOfMonth) &
            tbl.start.isSmallerThanValue(firstOfNext),
      )).watch();

  final absencesStream =
      (db.select(db.absences)..where(
        (tbl) =>
            tbl.employeeId.equals(empId) &
            tbl.date.isBiggerOrEqualValue(firstOfMonth) &
            tbl.date.isSmallerThanValue(firstOfNext),
      )).watch();

  final commentsStream =
      (db.select(db.comments)..where(
        (tbl) =>
            tbl.employeeId.equals(empId) &
            tbl.date.isBiggerOrEqualValue(firstOfMonth) &
            tbl.date.isSmallerThanValue(firstOfNext),
      )).watch();

  return Rx.combineLatest3<
    List<Shift>,
    List<Absence>,
    List<EmployeeComment>,
    MonthlySummary
  >(shiftsStream, absencesStream, commentsStream, (shifts, absences, comments) {
    final totalMin = shifts.fold<int>(0, (p, s) => p + s.durationMin);

    final mapShifts = <DateTime, List<Shift>>{};
    for (final s in shifts) {
      final d = DateTime.utc(s.start.year, s.start.month, s.start.day);
      mapShifts.putIfAbsent(d, () => []).add(s);
    }
    final absenceDates = absences.map((a) => a.date).toSet();
    final mapComments = <DateTime, EmployeeComment>{};
    for (final c in comments) {
      final d = DateTime.utc(c.date.year, c.date.month, c.date.day);
      mapComments[d] = c;
    }

    int totalOvertimeMin = 0;
    int totalAdjustedMinutes =
        totalMin; // Начинаем с фактически отработанных минут
    for (
      var day = firstOfMonth;
      day.isBefore(firstOfNext);
      day = day.add(const Duration(days: 1))
    ) {
      final d = DateTime.utc(day.year, day.month, day.day);
      final dailyShifts = mapShifts[d] ?? [];
      final dailyComment = mapComments[d];
      final dailyTotalMinutes = dailyShifts.fold<int>(
        0,
        (p, s) => p + s.durationMin,
      );
      final standardWorkMinutes = d.weekday == DateTime.sunday ? 0 : 9 * 60;
      final calculatedOvertime = dailyTotalMinutes - standardWorkMinutes;
      final manualAdjustment = dailyComment?.manualOvertimeAdjustmentMin ?? 0;
      totalOvertimeMin += (calculatedOvertime + manualAdjustment);
      totalAdjustedMinutes +=
          manualAdjustment; // Добавляем ручную корректировку к общему количеству минут
    }

    return MonthlySummary(
      totalMinutes: totalAdjustedMinutes,
      overtimeMinutes: totalOvertimeMin,
      absences: absences.length,
    );
  });
});

// -----------------------------------------------------------------------------
// EmployeeListScreen
// -----------------------------------------------------------------------------

class EmployeeListScreen extends ConsumerWidget {
  const EmployeeListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employeesAsync = ref.watch(employeesFilteredProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Сотрудники'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month),
            onPressed:
                () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AllEmployeesMonthlyScreen(),
                  ),
                ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Поиск по ФИО или телефону',
              ),
              onChanged:
                  (v) => ref.read(employeeSearchProvider.notifier).state = v,
            ),
          ),
          Expanded(
            child: employeesAsync.when(
              data:
                  (list) => ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final emp = list[index];
                      final shiftAsync = ref.watch(
                        currentShiftProvider(emp.id),
                      );
                      final isActive = shiftAsync.asData?.value != null;
                      return ListTile(
                        title: Text(emp.name),
                        subtitle: emp.phone != null ? Text(emp.phone!) : null,
                        trailing: Icon(
                          isActive ? Icons.play_circle_fill : Icons.circle,
                          color: isActive ? Colors.green : Colors.grey,
                        ),
                        onTap:
                            () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder:
                                    (_) => EmployeeDetailScreen(employee: emp),
                              ),
                            ),
                      );
                    },
                  ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, st) => Center(child: Text('Ошибка: $e')),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add),
        onPressed: () => _showAddEmployeeDialog(context, ref),
      ),
    );
  }

  void _showAddEmployeeDialog(BuildContext context, WidgetRef ref) {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Новый сотрудник'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'ФИО'),
                ),
                TextField(
                  controller: phoneCtrl,
                  decoration: const InputDecoration(labelText: 'Номер'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                child: const Text('Сохранить'),
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final db = ref.read(dbProvider);
                  await db.createEmployee(
                    EmployeesCompanion(
                      name: drift.Value(name),
                      phone: drift.Value(
                        phoneCtrl.text.trim().isEmpty
                            ? null
                            : phoneCtrl.text.trim(),
                      ),
                    ),
                  );
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
    );
  }
}

// -----------------------------------------------------------------------------
// EmployeeDetailScreen
// -----------------------------------------------------------------------------

class EmployeeDetailScreen extends ConsumerStatefulWidget {
  final Employee employee;
  const EmployeeDetailScreen({required this.employee, super.key});

  @override
  ConsumerState<EmployeeDetailScreen> createState() =>
      _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends ConsumerState<EmployeeDetailScreen> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shiftAsync = ref.watch(currentShiftProvider(widget.employee.id));
    final summaryAsync = ref.watch(monthlySummaryProvider(widget.employee.id));

    // Проверяем, есть ли активная смена и началась ли она сегодня
    final currentShift = shiftAsync.asData?.value;
    final canEditShift =
        currentShift != null &&
        currentShift.start.toLocal().year == DateTime.now().year &&
        currentShift.start.toLocal().month == DateTime.now().month &&
        currentShift.start.toLocal().day == DateTime.now().day;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.employee.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => _showEditEmployeeDialog(context, widget.employee),
          ),
          if (canEditShift) // Показываем меню только если можно редактировать
            PopupMenuButton<String>(
              onSelected: (String result) {
                if (result == 'editShift') {
                  _showEditShiftDialog(context, currentShift);
                }
              },
              itemBuilder:
                  (BuildContext context) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'editShift',
                      child: Text('Изменить смену'),
                    ),
                  ],
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Номер: ',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(widget.employee.phone ?? '—'),
              ],
            ),
            const SizedBox(height: 24),
            shiftAsync.when(
              data: (shift) {
                print('EmployeeDetailScreen: shift data received: $shift');
                if (shift == null) {
                  return const Text(
                    'Смена не начата',
                    style: TextStyle(fontSize: 18),
                  );
                }
                // Если смена активна, показываем тикающий таймер
                return Consumer(
                  builder: (context, ref, child) {
                    final tickAsync = ref.watch(
                      tickerProvider,
                    ); // Получаем AsyncValue
                    return tickAsync.when(
                      data: (tick) {
                        final dur = tick.difference(shift.start.toLocal());
                        final h = dur.inHours.toString().padLeft(2, '0');
                        final m = (dur.inMinutes % 60).toString().padLeft(
                          2,
                          '0',
                        );
                        final s = (dur.inSeconds % 60).toString().padLeft(
                          2,
                          '0',
                        );
                        return Text(
                          'Время в смене: $h:$m:$s',
                          style: const TextStyle(fontSize: 24),
                        );
                      },
                      loading:
                          () =>
                              const CircularProgressIndicator(), // Пока загружается, показываем индикатор
                      error:
                          (e, st) => Text('Ошибка: $e'), // Обрабатываем ошибки
                    );
                  },
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (e, st) => Text('Ошибка: $e'),
            ),
            const SizedBox(height: 32),
            Text(
              'Статистика за ${DateFormat('LLLL yyyy', 'ru').format(DateTime.now())}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            summaryAsync.when(
              data:
                  (s) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Отработано: ${s.totalHours.toStringAsFixed(1)} ч'),
                      Text(
                        'Подработки: ${s.overtimeHours.toStringAsFixed(1)} ч',
                      ),
                      Text('Пропуски:   ${s.absences} дней'),
                    ],
                  ),
              loading: () => const LinearProgressIndicator(),
              error: (e, st) => Text('Ошибка: $e'),
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: shiftAsync.when(
                    data:
                        (shift) =>
                            shift == null
                                ? ElevatedButton(
                                  onPressed: _startShift,
                                  child: const Text('Начать смену'),
                                )
                                : ElevatedButton(
                                  onPressed: () => _endShift(shift.id),
                                  child: const Text('Закончить смену'),
                                ),
                    loading: () => const SizedBox.shrink(),
                    error: (e, st) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(
                  width: 8,
                ), // Добавим немного пространства между кнопками
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder:
                                (_) => EmployeeDaysScreen(
                                  employee: widget.employee,
                                ),
                          ),
                        ),
                    child: const Text('Посмотреть рабочие дни'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Новый метод для показа диалога редактирования смены
  void _showEditShiftDialog(BuildContext context, Shift shift) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return EditShiftDialog(shift: shift);
      },
    );
  }

  Future<void> _startShift() async {
    final db = ref.read(dbProvider);
    print('Starting shift for employee ${widget.employee.id}');
    await db.startShift(widget.employee.id, DateTime.now().toUtc());
    ref.refresh(currentShiftProvider(widget.employee.id));
    ref.invalidate(monthlySummaryProvider(widget.employee.id));
    ref.invalidate(allEmployeesMonthlyProvider);
    print('Shift started and providers refreshed/invalidated.');
  }

  Future<void> _endShift(int shiftId) async {
    final db = ref.read(dbProvider);
    print('Ending shift $shiftId');
    await db.endShift(shiftId, DateTime.now().toUtc());
    ref.refresh(currentShiftProvider(widget.employee.id));
    ref.invalidate(monthlySummaryProvider(widget.employee.id));
    ref.invalidate(allEmployeesMonthlyProvider);
    print('Shift ended and providers refreshed/invalidated.');
  }

  void _showEditEmployeeDialog(BuildContext context, Employee employee) {
    final nameCtrl = TextEditingController(text: employee.name);
    final phoneCtrl = TextEditingController(text: employee.phone);

    showDialog(
      context: context,
      builder:
          (_) => AlertDialog(
            title: const Text('Редактировать сотрудника'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'ФИО'),
                ),
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Номер'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Отмена'),
              ),
              ElevatedButton(
                child: const Text('Сохранить'),
                onPressed: () async {
                  final name = nameCtrl.text.trim();
                  final phone =
                      phoneCtrl.text.trim().isEmpty
                          ? null
                          : phoneCtrl.text.trim();

                  if (name.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('ФИО не может быть пустым')),
                    );
                    return;
                  }

                  final db = ref.read(dbProvider);
                  try {
                    await db.updateEmployee(employee.id, name, phone);
                    Navigator.of(context).pop();
                  } on SqliteException catch (e) {
                    if (e.message?.contains('UNIQUE constraint failed') ??
                        false) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Номер телефона уже существует'),
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Ошибка сохранения: ${e.message}'),
                        ),
                      );
                    }
                  }
                },
              ),
            ],
          ),
    );
  }
}

// -----------------------------------------------------------------------------
// EmployeeDaysScreen
// -----------------------------------------------------------------------------

class EmployeeDaysScreen extends ConsumerStatefulWidget {
  final Employee employee;
  const EmployeeDaysScreen({super.key, required this.employee});

  @override
  ConsumerState<EmployeeDaysScreen> createState() => _EmployeeDaysScreenState();
}

class _EmployeeDaysScreenState extends ConsumerState<EmployeeDaysScreen> {
  final TextEditingController _hoursController = TextEditingController();
  final TextEditingController _commentController = TextEditingController();

  @override
  void dispose() {
    _hoursController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _showAdjustHoursDialog(
    int employeeId,
    DateTime date, {
    bool isAdd = true,
  }) async {
    _hoursController.clear();
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(isAdd ? 'Добавить часы' : 'Вычесть часы'),
          content: TextField(
            controller: _hoursController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'Введите часы (целые)'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () async {
                final hours = int.tryParse(_hoursController.text);
                if (hours != null) {
                  final db = ref.read(dbProvider);
                  final minutesToAdjust = hours * 60 * (isAdd ? 1 : -1);
                  await db.adjustShiftOvertime(
                    employeeId,
                    date,
                    minutesToAdjust,
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Часы ${isAdd ? 'добавлены' : 'вычтены'}: ${hours}',
                      ),
                    ),
                  );
                  ref.invalidate(dailyRecordsProvider(employeeId));
                }
                Navigator.of(context).pop();
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCommentDialog(int employeeId, DateTime date) async {
    _commentController.clear();
    final db = ref.read(dbProvider);
    final existingComment = await db.getCommentForDay(employeeId, date);
    if (existingComment != null) {
      _commentController.text = existingComment.commentText;
    }

    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Добавить комментарий'),
          content: TextField(
            controller: _commentController,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Введите комментарий'),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Отмена'),
            ),
            ElevatedButton(
              onPressed: () async {
                final commentText = _commentController.text.trim();
                if (commentText.isNotEmpty) {
                  await db.addOrUpdateComment(employeeId, date, commentText);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Комментарий сохранен')),
                  );
                  ref.invalidate(dailyRecordsProvider(employeeId));
                } else {
                  // Если пользователь очистил текст, удаляем комментарий и корректировку
                  await db.deleteComment(employeeId, date);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Комментарий удален')),
                  );
                  ref.invalidate(dailyRecordsProvider(employeeId));
                }
                Navigator.of(context).pop();
              },
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final recordsAsync = ref.watch(dailyRecordsProvider(widget.employee.id));
    return Scaffold(
      appBar: AppBar(title: Text('Дни ${widget.employee.name}')),
      body: recordsAsync.when(
        data:
            (records) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                // ширина не фиксируется, DataTable сам растянется по колонкам
                child: SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Дата')),
                      DataColumn(label: Text('Смены')),
                      DataColumn(label: Text('Перераб.')),
                      DataColumn(label: Text('Пропуск')),
                      DataColumn(label: Text('Отклонение')),
                      DataColumn(label: Text('Упр. часами')),
                      DataColumn(label: Text('Комментарий')),
                    ],
                    rows: [
                      for (final r in records)
                        DataRow(
                          cells: [
                            DataCell(
                              Text(
                                DateFormat('dd.MM').format(r.date.toLocal()),
                              ),
                            ),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: r.shiftIntervalsText,
                                      child: Text(
                                        r.shiftIntervalsText,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            DataCell(Text(r.overtimeHours.toStringAsFixed(1))),
                            DataCell(Text(r.absent ? 'Да' : '')),
                            DataCell(
                              Text(r.salaryDeviation.toStringAsFixed(1)),
                            ),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.add),
                                    onPressed: () {
                                      _showAdjustHoursDialog(
                                        widget.employee.id,
                                        r.date,
                                        isAdd: true,
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.remove),
                                    onPressed: () {
                                      _showAdjustHoursDialog(
                                        widget.employee.id,
                                        r.date,
                                        isAdd: false,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                            DataCell(
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Expanded(
                                    child: Tooltip(
                                      message: r.comment?.commentText ?? '',
                                      child: Text(
                                        r.comment?.commentText ?? '',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit),
                                    onPressed: () {
                                      _showCommentDialog(
                                        widget.employee.id,
                                        r.date,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Ошибка: $e')),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// AllEmployeesMonthlyScreen
// -----------------------------------------------------------------------------

class AllEmployeesMonthlyScreen extends ConsumerWidget {
  const AllEmployeesMonthlyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(allEmployeesMonthlyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Отчёт за месяц')),
      body: dataAsync.when(
        data:
            (list) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Номер')),
                  DataColumn(label: Text('Сотрудник')),
                  DataColumn(label: Text('Часы')),
                  DataColumn(label: Text('Перераб.')),
                  DataColumn(label: Text('Пропуски')),
                ],
                rows: [
                  for (final item in list)
                    DataRow(
                      cells: [
                        DataCell(Text(item.employee.phone ?? '—')),
                        DataCell(Text(item.employee.name)),
                        DataCell(
                          Text(item.summary.totalHours.toStringAsFixed(1)),
                        ),
                        DataCell(
                          Text(item.summary.overtimeHours.toStringAsFixed(1)),
                        ),
                        DataCell(Text(item.summary.absences.toString())),
                      ],
                    ),
                ],
              ),
            ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Ошибка: $e')),
      ),
    );
  }
}
