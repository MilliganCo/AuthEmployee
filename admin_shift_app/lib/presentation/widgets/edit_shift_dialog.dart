import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:drift/drift.dart' as drift;

import '../../data/db/app_database.dart';

class EditShiftDialog extends StatefulWidget {
  final Shift shift;
  final AppDatabase db;
  const EditShiftDialog({super.key, required this.shift, required this.db});

  @override
  State<EditShiftDialog> createState() => _EditShiftDialogState();
}

class _EditShiftDialogState extends State<EditShiftDialog> {
  late final _start = TextEditingController(
      text: DateFormat.Hm().format(widget.shift.start.toLocal()));
  late final _end = TextEditingController(
      text: widget.shift.end != null
          ? DateFormat.Hm().format(widget.shift.end!.toLocal())
          : '');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Корректировка смены'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _start, decoration: const InputDecoration(label: Text('Начало (HH:mm)'))),
        TextField(controller: _end, decoration: const InputDecoration(label: Text('Конец (HH:mm)'))),
      ]),
      actions: [
        TextButton(child: const Text('Отмена'), onPressed: Navigator.of(context).pop),
        FilledButton(
          child: const Text('Сохранить'),
          onPressed: () {
            final day = widget.shift.start.toLocal();
            final s = _parse(day, _start.text).toUtc();
            final e = _parse(day, _end.text).toUtc();
            widget.db.endShift(widget.shift.id, e);
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  DateTime _parse(DateTime day, String hm) {
    final parts = hm.split(':');
    return DateTime(day.year, day.month, day.day, int.parse(parts[0]), int.parse(parts[1]));
  }
} 