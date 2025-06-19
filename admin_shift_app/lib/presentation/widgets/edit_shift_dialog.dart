import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db/app_database.dart';
import '../../providers/database_provider.dart';
import '../screens.dart';

class EditShiftDialog extends ConsumerStatefulWidget {
  final Shift shift;
  const EditShiftDialog({super.key, required this.shift});

  @override
  ConsumerState<EditShiftDialog> createState() => _EditShiftDialogState();
}

class _EditShiftDialogState extends ConsumerState<EditShiftDialog> {
  late final _start = TextEditingController(
    text: DateFormat.Hm().format(widget.shift.start.toLocal()),
  );
  late final _end = TextEditingController(
    text:
        widget.shift.end != null
            ? DateFormat.Hm().format(widget.shift.end!.toLocal())
            : '',
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Корректировка смены'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _start,
            decoration: const InputDecoration(label: Text('Начало (HH:mm)')),
          ),
          TextField(
            controller: _end,
            decoration: const InputDecoration(label: Text('Конец (HH:mm)')),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: Navigator.of(context).pop,
          child: const Text('Отмена'),
        ),
        FilledButton(
          child: const Text('Сохранить'),
          onPressed: () async {
            final day = widget.shift.start.toLocal();
            final newStart = _parse(day, _start.text).toUtc();
            DateTime? newEnd;
            if (_end.text.isNotEmpty) {
              newEnd = _parse(day, _end.text).toUtc();
            }

            final db = ref.read(dbProvider);
            await db.updateShiftTimes(widget.shift.id, newStart, newEnd);

            ref.invalidate(dailyRecordsProvider(widget.shift.employeeId));
            ref.invalidate(monthlySummaryProvider(widget.shift.employeeId));
            ref.invalidate(allEmployeesMonthlyProvider);

            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  DateTime _parse(DateTime day, String hm) {
    final parts = hm.split(':');
    return DateTime(
      day.year,
      day.month,
      day.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
  }
}
