import 'package:agent_design/src/cache.dart';
import 'package:agent_design/src/modelos.dart';
import 'package:agent_design/src/quadro/exportar.dart';
import 'package:agent_design/src/quadro/entrada.dart';
import 'package:agent_design/src/quadro/estojo.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const traco = Traco(
    't1',
    pincel: Pincel.caneta,
    cor: Color(0xFF1E5EFF),
    espessura: 4,
    pontos: [Ponto(0, 0, 0.5), Ponto(100, 0, 1)],
  );

  test('elementos vão e voltam do JSON', () {
    final elementos = [
      traco,
      const Forma('f1', forma: TipoForma.seta, a: Offset(1, 2), b: Offset(30, 40), cor: Colors.red, espessura: 3),
      const Texto('x1', posicao: Offset(5, 5), texto: 'Olá', cor: Colors.black, tamanho: 24),
    ];
    final volta = [for (final e in elementos) Elemento.fromJson(e.toJson())!.toJson()];
    expect(volta, [for (final e in elementos) e.toJson()]);
    expect(Elemento.fromJson({'id': 'v', 'tipo': 'video'}), isNull);
  });

  test('borracha encosta no traço e na borda da forma, não no vazio', () {
    expect(traco.toca(const Offset(50, 3), 2), isTrue);
    expect(traco.toca(const Offset(50, 30), 2), isFalse);
    const ret = Forma(
      'r',
      forma: TipoForma.retangulo,
      a: Offset.zero,
      b: Offset(100, 100),
      cor: Colors.black,
      espessura: 2,
    );
    expect(ret.toca(const Offset(100, 50), 2), isTrue);
    expect(ret.toca(const Offset(50, 50), 2), isFalse);
  });

  test('mesclar mantém o local, traz o remoto novo e respeita o que foi apagado aqui', () {
    Traco t(String id) => Traco(id, pincel: Pincel.caneta, cor: Colors.black, espessura: 1, pontos: const []);
    final r = mesclar([t('a'), t('c')], [t('a'), t('b'), t('d')], {'d'});
    expect(r.map((e) => e.id), ['b', 'a', 'c']);
  });

  test('caneta desenha, ponta de borracha e botão lateral apagam, dedo só move com caneta vista', () {
    Gesto g(
      PointerDeviceKind tipo, {
      int botoes = kPrimaryButton,
      bool dedo = true,
      Ferramenta f = Ferramenta.caneta,
    }) => classificar(tipo: tipo, botoes: botoes, ferramenta: f, dedoDesenha: dedo);
    expect(g(PointerDeviceKind.stylus), Gesto.desenhar);
    expect(g(PointerDeviceKind.invertedStylus), Gesto.apagar);
    expect(g(PointerDeviceKind.stylus, botoes: kPrimaryButton | kPrimaryStylusButton), Gesto.apagar);
    expect(g(PointerDeviceKind.touch, dedo: false), Gesto.navegar);
    expect(g(PointerDeviceKind.mouse, botoes: kMiddleMouseButton), Gesto.navegar);
    expect(g(PointerDeviceKind.mouse, f: Ferramenta.mao), Gesto.navegar);

    final estojo = Estojo();
    expect(estojo.dedoDesenha, isTrue);
    estojo.canetaVista();
    expect(estojo.dedoDesenha, isFalse);
  });

  test('zoom mantém parado o ponto sob o cursor', () {
    final c = Camera()..deslocamento = const Offset(10, 20);
    final antes = c.paraMundo(const Offset(200, 150));
    c.zoom(2, const Offset(200, 150));
    expect(c.paraMundo(const Offset(200, 150)), antes);
  });

  test('laço pega o que abraça e transformar move, escala e recolore', () {
    const laco = [Offset(-10, -10), Offset(120, -10), Offset(120, 10), Offset(-10, 10)];
    expect(traco.dentroDoLaco(laco), isTrue);
    expect(traco.dentroDoLaco(const [Offset(200, 200), Offset(300, 200), Offset(300, 300)]), isFalse);

    final dobro = traco.transformar((q) => q * 2, fator: 2, id: 'copia', cor: Colors.red);
    expect(dobro.id, 'copia');
    expect(dobro.cor, Colors.red);
    expect(dobro.espessura, 8);
    expect(dobro.pontos.last.offset, const Offset(200, 0));
    expect(dobro.pontos.last.p, 1);
  });

  test('cache guarda o quadro com as mudanças pendentes', () async {
    final cache = await CacheQuadros.abrir();
    final resumo = {
      'id': 'q1',
      'titulo': 'Aula',
      'fundo': 'grade',
      'versao': 3,
      'atualizado': '2026-10-28T10:00:00+00:00',
    };
    await cache.guardar(resumo, [traco], pendente: true, apagados: {'x'});
    final c = cache.ler('q1')!;
    expect((c.resumo.titulo, c.resumo.fundo, c.resumo.versao, c.pendente), ('Aula', Fundo.grade, 3, true));
    expect(c.apagados, {'x'});
    expect(c.elementos.single.toJson(), traco.toJson());
    expect(cache.resumos().single.id, 'q1');
    await cache.remover('q1');
    expect(cache.ler('q1'), isNull);
  });

  test('exporta PNG e PDF', () async {
    final imagem = await png([traco], Fundo.pontos, densidade: 1);
    expect(imagem.sublist(1, 4), 'PNG'.codeUnits);
    final documento = await pdf([traco], Fundo.liso);
    expect(String.fromCharCodes(documento.sublist(0, 4)), '%PDF');
  });

  test('grupo e tabela vão e voltam pelo JSON', () {
    final agrupado = traco.comGrupo('g1');
    expect((Elemento.fromJson(agrupado.toJson())!).grupo, 'g1');
    expect(traco.toJson().containsKey('grupo'), isFalse);

    final t = Tabela.nova('tb', const Offset(10, 20), 2, 3);
    final cheia = t.copia(
      celulas: [
        [const Celula(texto: 'Mês'), const Celula(texto: 'Entrada', fundo: Color(0xFFC8E6C9)), const Celula()],
        [const Celula(texto: 'Jan'), const Celula(texto: '1.000', alinhamento: 2, negrito: true), const Celula()],
      ],
    ).ajustada();
    final volta = Elemento.fromJson(cheia.transformar((q) => q, grupo: 'g2').toJson())! as Tabela;
    expect((volta.linhas, volta.colunas, volta.grupo), (2, 3, 'g2'));
    expect(volta.celulas[0][1].fundo, const Color(0xFFC8E6C9));
    expect(volta.celulas[1][1].alinhamento, 2);
    expect(volta.retangulo.topLeft, const Offset(10, 20));
    final dobro = volta.transformar((q) => q * 2, fator: 2);
    expect(dobro.larguras.first, closeTo(volta.larguras.first * 2, 0.01));
  });
}
