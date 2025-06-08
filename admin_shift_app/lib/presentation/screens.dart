import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:drift/drift.dart' as drift;
import 'package:intl/intl.dart';
import 'package:rxdart/rxdart.dart';
import '../data/db/app_database.dart';
import '../providers/database_provider.dart';
import 'widgets/edit_shift_dialog.dart';

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
  final Shift? shift;
  final bool absent;

  const DailyRecord({required this.date, this.shift, required this.absent});

  double get overtimeHours => (shift?.overtimeMin ?? 0) / 60;
  double get workHours => (shift?.durationMin ?? 0) / 60;
  bool get isWeekend =>
      date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
  double get salaryDeviation => overtimeHours - (absent ? 9 : 0);
}

/// Все записи по дням для сотрудника за текущий месяц
final dailyRecordsProvider =
    StreamProvider.family<List<DailyRecord>, int>((ref, empId) {
  final db = ref.watch(dbProvider);
  final now = DateTime.now().toUtc();
  final first = DateTime.utc(now.year, now.month, 1);
  final next = DateTime.utc(now.year, now.month + 1, 1);

  final shiftsStream = (db.select(db.shifts)
        ..where((tbl) => tbl.employeeId.equals(empId) &
            tbl.start.isBiggerOrEqualValue(first) &
            tbl.start.isSmallerThanValue(next)))
      .watch();
  final absencesStream = (db.select(db.absences)
        ..where((tbl) => tbl.employeeId.equals(empId) &
            tbl.date.isBiggerOrEqualValue(first) &
            tbl.date.isSmallerThanValue(next)))
      .watch();

  return Rx.combineLatest2<List<Shift>, List<Absence>, List<DailyRecord>>(
      shiftsStream, absencesStream, (shifts, absences) {
    final mapShift = {
      for (final s in shifts)
        DateTime.utc(s.start.year, s.start.month, s.start.day): s
    };
    final absenceDates = absences.map((a) => a.date).toSet();
    final records = <DailyRecord>[];
    for (var day = first; day.isBefore(next); day = day.add(const Duration(days: 1))) {
      final d = DateTime.utc(day.year, day.month, day.day);
      records.add(DailyRecord(
        date: d,
        shift: mapShift[d],
        absent: absenceDates.contains(d),
      ));
    }
    return records;
  });
});

class EmployeeMonthlySummary {
  final Employee employee;
  final MonthlySummary summary;

  EmployeeMonthlySummary(this.employee, this.summary);
}

/// Сводка за месяц по всем сотрудникам за текущий месяц 2025 года
final allEmployeesMonthlyProvider =
    StreamProvider<List<EmployeeMonthlySummary>>((ref) {
  final db = ref.watch(dbProvider);
  final now = DateTime.now().toUtc();
  final first = DateTime.utc(2025, now.month, 1);
  final next = DateTime.utc(2025, now.month + 1, 1);

  final employees = db.watchEmployees();
  final shifts = (db.select(db.shifts)
        ..where((t) => t.start.isBiggerOrEqualValue(first) &
            t.start.isSmallerThanValue(next)))
      .watch();
  final absences = (db.select(db.absences)
        ..where((a) => a.date.isBiggerOrEqualValue(first) &
            a.date.isSmallerThanValue(next)))
      .watch();

  return Rx.combineLatest3(employees, shifts, absences,
      (List<Employee> emps, List<Shift> sh, List<Absence> abs) {
    return emps.map((e) {
      final eshifts = sh.where((s) => s.employeeId == e.id).toList();
      final eabs = abs.where((a) => a.employeeId == e.id).toList();
      final totalMin = eshifts.fold<int>(0, (p, s) => p + s.durationMin);
      final overtimeMin = eshifts.fold<int>(0, (p, s) => p + s.overtimeMin);
      final summary = MonthlySummary(
          totalMinutes: totalMin,
          overtimeMinutes: overtimeMin,
          absences: eabs.length);
      return EmployeeMonthlySummary(e, summary);
    }).toList();
  });
});

/// Месячная статистика по сотруднику
final monthlySummaryProvider = StreamProvider.family<MonthlySummary, int>((ref, empId) {
  final db = ref.watch(dbProvider);
  final now = DateTime.now().toUtc();
  final firstOfMonth = DateTime.utc(now.year, now.month, 1);
  final firstOfNext = DateTime.utc(now.year, now.month + 1, 1);

  final shiftsStream = (db.select(db.shifts)
        ..where((tbl) => tbl.employeeId.equals(empId) &
            tbl.start.isBiggerOrEqualValue(firstOfMonth) &
            tbl.start.isSmallerThanValue(firstOfNext)))
      .watch();

  final absencesStream = (db.select(db.absences)
        ..where((tbl) => tbl.employeeId.equals(empId) &
            tbl.date.isBiggerOrEqualValue(firstOfMonth) &
            tbl.date.isSmallerThanValue(firstOfNext)))
      .watch();

  return Rx.combineLatest2<List<Shift>, List<Absence>, MonthlySummary>(
      shiftsStream, absencesStream, (shifts, absences) {
    final totalMin = shifts.fold<int>(0, (p, s) => p + s.durationMin);
    final overtimeMin = shifts.fold<int>(0, (p, s) => p + s.overtimeMin);
    return MonthlySummary(
        totalMinutes: totalMin,
        overtimeMinutes: overtimeMin,
        absences: absences.length);
  });
});

// -----------------------------------------------------------------------------
// EmployeeListScreen
// -----------------------------------------------------------------------------

class EmployeeListScreen extends ConsumerWidget {
  const EmployeeListScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employeesAsync = ref.watch(employeesFilteredProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Сотрудники'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month),
            onPressed: () => Navigator.of(context).push(
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
              onChanged: (v) => ref.read(employeeSearchProvider.notifier).state = v,
            ),
          ),
          Expanded(
            child: employeesAsync.when(
              data: (list) => ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final emp = list[index];
                  final shiftAsync = ref.watch(currentShiftProvider(emp.id));
                  final isActive = shiftAsync.asData?.value != null;
                  return ListTile(
                    title: Text(emp.name),
                    subtitle: emp.phone != null ? Text(emp.phone!) : null,
                    trailing: Icon(
                      isActive ? Icons.play_circle_fill : Icons.circle,
                      color: isActive ? Colors.green : Colors.grey,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => EmployeeDetailScreen(employee: emp),
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
      builder: (_) => AlertDialog(
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
              decoration: const InputDecoration(labelText: 'Телефон'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
          ElevatedButton(
            child: const Text('Сохранить'),
            onPressed: () async {
              final name = nameCtrl.text.trim();
              if (name.isEmpty) return;
              final db = ref.read(dbProvider);
              await db.createEmployee(
                EmployeesCompanion(
                  name: drift.Value(name),
                  phone: drift.Value(phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim()),
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
  const EmployeeDetailScreen({required this.employee, Key? key}) : super(key: key);

  @override
  ConsumerState<EmployeeDetailScreen> createState() => _EmployeeDetailScreenState();
}

class _EmployeeDetailScreenState extends ConsumerState<EmployeeDetailScreen> {
  late final Stream<DateTime> _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    final shiftAsync = ref.watch(currentShiftProvider(widget.employee.id));
    final summaryAsync = ref.watch(monthlySummaryProvider(widget.employee.id));

    // Проверяем, есть ли активная смена и началась ли она сегодня
    final currentShift = shiftAsync.asData?.value;
    final canEditShift = currentShift != null &&
        currentShift.start.toLocal().year == DateTime.now().year &&
        currentShift.start.toLocal().month == DateTime.now().month &&
        currentShift.start.toLocal().day == DateTime.now().day;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.employee.name),
        actions: [
          if (canEditShift) // Показываем меню только если можно редактировать
            PopupMenuButton<String>(
              onSelected: (String result) {
                if (result == 'editShift') {
                  _showEditShiftDialog(context, currentShift!);
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
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
                const Text('Телефон: ', style: TextStyle(fontWeight: FontWeight.bold)),
                Text(widget.employee.phone ?? '—'),
              ],
            ),
            const SizedBox(height: 24),
            shiftAsync.when(
              data: (shift) {
                if (shift == null) {
                  return const Text('Смена не начата', style: TextStyle(fontSize: 18));
                }
                // Если смена активна, показываем тикающий таймер
                return StreamBuilder<DateTime>(
                  stream: _ticker,
                  builder: (_, __) {
                    final dur = DateTime.now().difference(shift.start.toLocal());
                    final h = dur.inHours.toString().padLeft(2, '0');
                    final m = (dur.inMinutes % 60).toString().padLeft(2, '0');
                    final s = (dur.inSeconds % 60).toString().padLeft(2, '0');
                    return Text('Время в смене: $h:$m:$s', style: const TextStyle(fontSize: 24));
                  },
                );
              },
              loading: () => const CircularProgressIndicator(),
              error: (e, st) => Text('Ошибка: $e'),
            ),
            const SizedBox(height: 32),
            Text('Статистика за ${DateFormat('LLLL yyyy', 'ru').format(DateTime.now())}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            summaryAsync.when(
              data: (s) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Отработано: ${s.totalHours.toStringAsFixed(1)} ч'),
                  Text('Подработки: ${s.overtimeHours.toStringAsFixed(1)} ч'),
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
                shiftAsync.when(
                  data: (shift) => shift == null
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
                ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => EmployeeDaysScreen(employee: widget.employee),
                    ),
                  ),
                  child: const Text('Посмотреть рабочие дни'),
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
    await db.startShift(widget.employee.id, DateTime.now().toUtc());
  }

  Future<void> _endShift(int shiftId) async {
    final db = ref.read(dbProvider);
    await db.endShift(shiftId, DateTime.now().toUtc());
  }
}

// -----------------------------------------------------------------------------
// EmployeeDaysScreen
// -----------------------------------------------------------------------------

class EmployeeDaysScreen extends ConsumerWidget {
  final Employee employee;
  const EmployeeDaysScreen({super.key, required this.employee});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordsAsync = ref.watch(dailyRecordsProvider(employee.id));
    return Scaffold(
      appBar: AppBar(title: Text('Дни ${employee.name}')),
      body: recordsAsync.when(
        data: (records) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(columns: const [
            DataColumn(label: Text('Дата')),
            DataColumn(label: Text('Начало')),
            DataColumn(label: Text('Конец')),
            DataColumn(label: Text('Перераб.')),
            DataColumn(label: Text('Пропуск')),
            DataColumn(label: Text('Отклонение')),
          ], rows: [
            for (final r in records)
              DataRow(cells: [
                DataCell(Text(DateFormat('dd.MM').format(r.date.toLocal()))),
                DataCell(Text(r.shift != null
                    ? DateFormat.Hm().format(r.shift!.start.toLocal())
                    : '')),
                DataCell(Text(r.shift?.end != null
                    ? DateFormat.Hm().format(r.shift!.end!.toLocal())
                    : '')),
                DataCell(Text(r.overtimeHours.toStringAsFixed(1))),
                DataCell(Text(r.absent ? 'Да' : '')),
                DataCell(Text(r.salaryDeviation.toStringAsFixed(1))),
              ])
          ]),
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
        data: (list) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(columns: const [
            DataColumn(label: Text('Сотрудник')),
            DataColumn(label: Text('Часы')),
            DataColumn(label: Text('Перераб.')),
            DataColumn(label: Text('Пропуски')),
          ], rows: [
            for (final item in list)
              DataRow(cells: [
                DataCell(Text(item.employee.name)),
                DataCell(Text(item.summary.totalHours.toStringAsFixed(1))),
                DataCell(Text(item.summary.overtimeHours.toStringAsFixed(1))),
                DataCell(Text(item.summary.absences.toString())),
              ])
          ]),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Ошибка: $e')),
      ),
    );
  }
}
