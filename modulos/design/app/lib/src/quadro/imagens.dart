import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../api_design.dart';

/// Imagens do quadro já decodificadas, por id. A pintura é síncrona: pede a imagem, desenha um
/// marcador enquanto ela não chega e repinta (este notificador) quando chega.
class CacheImagens extends ChangeNotifier {
  CacheImagens._();

  static final instancia = CacheImagens._();

  ApiDesign? api;
  final Map<String, ui.Image> _prontas = {};
  final Map<String, Future<void>> _pedidas = {};

  ui.Image? obter(String id) {
    final i = _prontas[id];
    if (i == null) unawaited(carregar(id));
    return i;
  }

  Future<void> carregar(String id) {
    final api = this.api;
    if (api == null || id.isEmpty) return Future.value();
    return _pedidas[id] ??= () async {
      try {
        final codec = await ui.instantiateImageCodec(await api.imagem(id));
        _prontas[id] = (await codec.getNextFrame()).image;
        notifyListeners();
      } catch (_) {
        // Fica no marcador; tenta de novo na próxima abertura do quadro.
      }
    }();
  }

  /// Exportar/miniatura: espera as imagens [ids] antes de desenhar.
  Future<void> garantir(Iterable<String> ids) => Future.wait({...ids}.map(carregar));
}

/// Resultado da busca sendo arrastado do painel para o quadro.
class ImagemArrastada {
  const ImagemArrastada(this.resultado);

  final Map<String, dynamic> resultado;
}

/// Painel lateral de busca no Google Imagens: digitar, rolar os resultados (carrega mais ao chegar
/// no fim) e tocar na imagem (vai para o centro) ou arrastá-la para o quadro.
class PainelImagens extends StatefulWidget {
  const PainelImagens({super.key, required this.api, required this.inserir, required this.fechar});

  final ApiDesign api;

  /// Recebe o resultado escolhido (`url`, `largura`, `altura`, `titulo`); termina quando inserido.
  final Future<void> Function(Map<String, dynamic> resultado) inserir;
  final VoidCallback fechar;

  @override
  State<PainelImagens> createState() => _PainelImagensState();
}

class _PainelImagensState extends State<PainelImagens> {
  static const _tipos = [('foto', 'Fotos'), ('icone', 'Ícones'), ('figura', 'Figuras'), ('todos', 'Todos')];
  // A API do Google só devolve os 100 primeiros (10 páginas de 10).
  static const _maxPaginas = 10;

  final _busca = TextEditingController();
  final _rolagem = ScrollController();
  String _tipo = 'foto';
  final List<Map<String, dynamic>> _resultados = [];
  int _pagina = 0;
  bool _carregando = false, _fim = false;
  String? _erro, _inserindo;

  @override
  void initState() {
    super.initState();
    _rolagem.addListener(() {
      if (_rolagem.position.extentAfter < 300) _maisResultados();
    });
  }

  @override
  void dispose() {
    _busca.dispose();
    _rolagem.dispose();
    super.dispose();
  }

  void _buscar() {
    setState(() {
      _resultados.clear();
      _pagina = 0;
      _fim = false;
      _erro = null;
    });
    _maisResultados();
  }

  Future<void> _maisResultados() async {
    final q = _busca.text.trim();
    if (_carregando || _fim || q.isEmpty) return;
    setState(() => _carregando = true);
    try {
      final novos = await widget.api.buscarImagens(q, tipo: _tipo, pagina: _pagina);
      if (!mounted || q != _busca.text.trim()) return;
      setState(() {
        _resultados.addAll(novos);
        _pagina++;
        _fim = novos.isEmpty || _pagina >= _maxPaginas;
      });
    } catch (e) {
      if (mounted) setState(() => _erro = '$e');
    } finally {
      if (mounted) setState(() => _carregando = false);
    }
  }

  Future<void> _escolher(Map<String, dynamic> r) async {
    if (_inserindo != null) return;
    setState(() => _inserindo = r['url'] as String);
    try {
      await widget.inserir(r);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Não deu para usar a imagem: $e')));
      }
    } finally {
      if (mounted) setState(() => _inserindo = null);
    }
  }

  /// Miniatura do resultado; se ela não abrir (alguns provedores bloqueiam), tenta a imagem original.
  Widget _miniatura(Map<String, dynamic> r) {
    final url = r['url'] as String;
    final mini = r['miniatura'] as String? ?? '';
    Widget original() => Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: 280,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: mini.isEmpty ? original() : Image.network(mini, fit: BoxFit.cover, errorBuilder: (_, _, _) => original()),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
        child: Row(
          children: [
            Expanded(child: Text('Google Imagens', style: Theme.of(context).textTheme.titleSmall)),
            IconButton(tooltip: 'Fechar', onPressed: widget.fechar, icon: const Icon(Icons.close)),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: TextField(
          controller: _busca,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _buscar(),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Buscar imagens…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(tooltip: 'Buscar', onPressed: _buscar, icon: const Icon(Icons.search)),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Wrap(
          spacing: 6,
          children: [
            for (final (valor, rotulo) in _tipos)
              ChoiceChip(
                label: Text(rotulo),
                selected: _tipo == valor,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  setState(() => _tipo = valor);
                  _buscar();
                },
              ),
          ],
        ),
      ),
      if (_erro != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(_erro!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      Expanded(
        child: GridView.builder(
          controller: _rolagem,
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 140,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
          ),
          itemCount: _resultados.length + (_carregando ? 1 : 0),
          itemBuilder: (context, i) {
            if (i >= _resultados.length) return const Center(child: CircularProgressIndicator());
            final r = _resultados[i];
            // Na horizontal: o arrasto vertical continua rolando a grade.
            return Draggable<ImagemArrastada>(
              data: ImagemArrastada(r),
              affinity: Axis.horizontal,
              feedback: Opacity(opacity: 0.8, child: SizedBox.square(dimension: 100, child: _miniatura(r))),
              child: Tooltip(
                message: '${r['titulo'] ?? ''}',
                child: InkWell(
                  onTap: () => _escolher(r),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _miniatura(r),
                      if (_inserindo == r['url']) const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}
