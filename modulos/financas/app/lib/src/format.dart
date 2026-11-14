import 'package:flutter/material.dart';

/// JSON document of the API (`/api/financas`).
typedef Doc = Map<String, dynamic>;

const _months = ['jan', 'fev', 'mar', 'abr', 'mai', 'jun', 'jul', 'ago', 'set', 'out', 'nov', 'dez'];

/// 1234.5 → "1.234,50".
String number(num? v, {int decimals = 2}) {
  if (v == null) return '—';
  final parts = v.abs().toStringAsFixed(decimals).split('.');
  final integer = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return '${v < 0 ? '-' : ''}$integer${decimals > 0 ? ',${parts[1]}' : ''}';
}

String currency(num? v) => v == null ? '—' : 'R\$ ${number(v)}';

String pct(num? v) => v == null ? '—' : '${number(v, decimals: 1)}%';

/// Accepts "1.234,56", "1234.56" and "R$ 10"; empty or invalid → null.
double? readNumber(String text) {
  var s = text.trim().replaceAll('R\$', '').replaceAll(' ', '');
  if (s.isEmpty) return null;
  if (s.contains(',')) s = s.replaceAll('.', '').replaceAll(',', '.');
  return double.tryParse(s);
}

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String mesIso(DateTime d) => iso(d).substring(0, 7);

/// "2026-10-05" → "05/10/2026".
String dataBr(String? v) =>
    v == null || v.length < 10 ? '—' : '${v.substring(8, 10)}/${v.substring(5, 7)}/${v.substring(0, 4)}';

/// "2026-10" → "out/2026".
String mesBr(String v) => v.length < 7 ? v : '${_months[int.parse(v.substring(5, 7)) - 1]}/${v.substring(0, 4)}';

String shortMonth(String v) => v.length < 7 ? v : _months[int.parse(v.substring(5, 7)) - 1];

DateTime addMonths(DateTime d, int n) => DateTime(d.year, d.month + n);

Color? hexColor(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Color of a signed value: green comes in, red goes out.
Color valueColor(num? v, ColorScheme cs) => (v ?? 0) >= 0 ? Colors.green.shade400 : cs.error;

double n(dynamic v) => (v as num?)?.toDouble() ?? 0;

double? nn(dynamic v) => (v as num?)?.toDouble();

/// Payment methods of the entries (same values as the backend).
const paymentMethods = {
  '': '—',
  'pix': 'Pix',
  'debito': 'Débito',
  'credito': 'Crédito',
  'boleto': 'Boleto',
  'ted': 'TED',
  'doc': 'DOC',
  'transferencia': 'Transferência',
  'saque': 'Saque',
  'deposito': 'Depósito',
  'tarifa': 'Tarifa/juros',
  'investimento': 'Investimento',
  'dinheiro': 'Dinheiro',
  'outro': 'Outro',
};
