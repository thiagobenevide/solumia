import 'package:agent/shell.dart';
import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Falso extends Modulo {
  const _Falso(this.nome);

  @override
  final String nome;
  @override
  String get id => nome;
  @override
  String get descricao => '';
  @override
  IconData get icone => Icons.notes;

  @override
  Widget construir(BuildContext context) => Center(
    child: Column(
      children: [
        TextButton(onPressed: () => TituloAba.definir(context, 'Minha nota'), child: Text('tela $nome')),
        TextButton(
          onPressed: () async {
            final r = await abrirTela<String>(
              context,
              (c) => Scaffold(
                appBar: AppBar(title: const Text('Detalhe')),
                body: TextButton(onPressed: () => Navigator.pop(c, 'feito'), child: const Text('concluir')),
              ),
            );
            if (context.mounted) TituloAba.definir(context, 'voltou $r');
          },
          child: const Text('abrir detalhe'),
        ),
      ],
    ),
  );
}

void main() {
  testWidgets('abas: título da tela, nova aba e arrastar para dividir', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Shell(modulos: const [_Falso('Notas'), _Falso('Finanças')], aoSair: () {}, api: ApiCliente('http://x')),
      ),
    );
    await t.tap(find.text('tela Notas'));
    await t.pump();
    expect(find.text('Minha nota'), findsOneWidget);

    await t.tap(find.byTooltip('Nova aba'));
    await t.pump();
    expect(find.text('Notas 2'), findsOneWidget);

    final arrasto = await t.startGesture(t.getCenter(find.text('Notas 2')));
    await arrasto.moveBy(const Offset(20, 0));
    await t.pump();
    await arrasto.moveTo(const Offset(1200, 500));
    await t.pump();
    await arrasto.up();
    await t.pump();
    expect(find.byTooltip('Juntar painéis'), findsOneWidget);

    await t.tap(find.byTooltip('Ocultar menu'));
    await t.pump();
    expect(find.byType(NavigationRail), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('abas: tela aberta de dentro do módulo vira aba e devolve o resultado', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        home: Shell(modulos: const [_Falso('Notas')], aoSair: () {}, api: ApiCliente('http://x')),
      ),
    );
    await t.tap(find.text('abrir detalhe'));
    await t.pumpAndSettle();
    // título da aba vem da AppBar da tela
    expect(find.text('Detalhe'), findsNWidgets(2));

    await t.tap(find.text('concluir'));
    await t.pumpAndSettle();
    expect(find.text('Detalhe'), findsNothing);
    expect(find.text('voltou feito'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
