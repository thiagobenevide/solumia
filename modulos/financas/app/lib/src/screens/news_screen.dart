import 'package:agent_core/agent_core.dart';
import 'package:flutter/material.dart';

import '../finance_api.dart';
import '../format.dart';
import 'common.dart';

const _topics = {
  'economia': ('Economia', Icons.public),
  'acoes': ('Ações', Icons.show_chart),
  'fiis': ('FIIs', Icons.apartment),
  'impostos': ('Impostos', Icons.gavel),
  'juros': ('Juros e inflação', Icons.percent),
};

/// Headlines of the last 24 h by topic (Google News and publisher feeds via VPS), laid out like a
/// news portal: a featured story, photo cards and the latest ones with a thumbnail. Tapping opens
/// the article in the browser.
class NewsScreen extends StatefulWidget {
  const NewsScreen({super.key, required this.api});

  final FinanceApi api;

  @override
  State<NewsScreen> createState() => _NewsScreenState();
}

class _NewsScreenState extends State<NewsScreen> {
  String _topic = 'economia';
  late Future<Doc> _news = widget.api.news(topic: _topic);

  void _reload() => setState(() => _news = widget.api.news(topic: _topic));

  void _choose(String topic) {
    _topic = topic;
    _reload();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async => _reload(),
    child: ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _Header(topic: _topic, onChoose: _choose, onReload: _reload),
        const SizedBox(height: 12),
        Waiting(
          future: _news,
          reload: _reload,
          construir: (d) {
            final items = (d['noticias'] as List).cast<Doc>();
            if (items.isEmpty) {
              return const Padding(padding: EdgeInsets.all(16), child: Text('Nenhuma notícia nas últimas 24 horas.'));
            }
            return LayoutBuilder(
              builder: (context, box) => _NewsLayout(items: items, width: box.maxWidth, topic: _topic),
            );
          },
        ),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.topic, required this.onChoose, required this.onReload});

  final String topic;
  final void Function(String) onChoose;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 4, height: 30, color: cores.primary),
            const SizedBox(width: 10),
            Expanded(child: Text('Notícias em destaque', style: text.headlineSmall)),
            IconButton(tooltip: 'Atualizar', onPressed: onReload, icon: const Icon(Icons.refresh)),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final MapEntry(key: key, value: (name, icone)) in _topics.entries)
              ChoiceChip(
                avatar: Icon(icone, size: 18),
                label: Text(name),
                selected: topic == key,
                onSelected: (_) => onChoose(key),
              ),
          ],
        ),
      ],
    );
  }
}

/// PC: featured + two photo cards + "mais recentes" column, then a grid. Tablet: featured and a
/// two-column grid. Phone: featured, then rows with a thumbnail.
class _NewsLayout extends StatelessWidget {
  const _NewsLayout({required this.items, required this.width, required this.topic});

  final List<Doc> items;
  final double width;
  final String topic;

  @override
  Widget build(BuildContext context) {
    final photos = <Doc>[];
    final rest = <Doc>[];
    for (final n in items) {
      if ('${n['imagem'] ?? ''}'.isNotEmpty) {
        photos.add(n);
      } else {
        rest.add(n);
      }
    }
    // the featured story is the newest one with a photo (or the newest at all)
    final featured = photos.isNotEmpty ? photos.removeAt(0) : rest.removeAt(0);
    if (width >= 980) return _wide(featured, photos, rest);
    if (width >= 600) return _medium(featured, photos, rest);
    return _narrow(featured, photos, rest);
  }

  Widget _wide(Doc featured, List<Doc> photos, List<Doc> rest) {
    final side = photos.take(2).toList();
    final grid = photos.skip(2).toList();
    final latest = rest.take(6).toList();
    final others = rest.skip(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 5, child: _NewsCard(n: featured, topic: topic, big: true)),
            const SizedBox(width: 20),
            Expanded(
              flex: 4,
              child: Column(
                spacing: 16,
                children: [for (final n in side) _NewsCard(n: n, topic: topic)],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(flex: 4, child: _LatestColumn(items: latest, topic: topic)),
          ],
        ),
        if (grid.isNotEmpty) ...[
          const SizedBox(height: 24),
          _CardGrid(items: grid, columns: 4, topic: topic),
        ],
        if (others.isNotEmpty) ...[
          const SizedBox(height: 24),
          _RowList(items: others, topic: topic),
        ],
      ],
    );
  }

  Widget _medium(Doc featured, List<Doc> photos, List<Doc> rest) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NewsCard(n: featured, topic: topic, big: true),
        const SizedBox(height: 20),
        if (photos.isNotEmpty) _CardGrid(items: photos, columns: 2, topic: topic),
        const SizedBox(height: 20),
        _RowList(items: rest, topic: topic),
      ],
    );
  }

  Widget _narrow(Doc featured, List<Doc> photos, List<Doc> rest) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _NewsCard(n: featured, topic: topic, big: true),
        const SizedBox(height: 16),
        _RowList(items: [...photos, ...rest], topic: topic),
      ],
    );
  }
}

class _CardGrid extends StatelessWidget {
  const _CardGrid({required this.items, required this.columns, required this.topic});

  final List<Doc> items;
  final int columns;
  final String topic;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += columns) {
      final cells = <Widget>[];
      for (var k = 0; k < columns; k++) {
        final index = i + k;
        cells.add(
          Expanded(child: index < items.length ? _NewsCard(n: items[index], topic: topic) : const SizedBox()),
        );
      }
      rows.add(Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 16, children: cells));
    }
    return Column(spacing: 20, children: rows);
  }
}

class _LatestColumn extends StatelessWidget {
  const _LatestColumn({required this.items, required this.topic});

  final List<Doc> items;
  final String topic;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Mais recentes', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        for (final n in items) _NewsRow(n: n, topic: topic),
      ],
    );
  }
}

class _RowList extends StatelessWidget {
  const _RowList({required this.items, required this.topic});

  final List<Doc> items;
  final String topic;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final n in items) RevelarAoRolar(distancia: 24, child: _NewsRow(n: n, topic: topic))],
    );
  }
}

/// Photo on top (16:9, slow zoom on hover), section chip and the headline.
class _NewsCard extends StatefulWidget {
  const _NewsCard({required this.n, required this.topic, this.big = false});

  final Doc n;
  final String topic;
  final bool big;

  @override
  State<_NewsCard> createState() => _NewsCardState();
}

class _NewsCardState extends State<_NewsCard> {
  bool _over = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.n;
    final text = Theme.of(context).textTheme;
    final titleStyle = widget.big ? text.headlineSmall : text.titleMedium;
    return RevelarAoRolar(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _over = true),
        onExit: (_) => setState(() => _over = false),
        child: GestureDetector(
          onTap: () => abrirLink(context, '${n['url']}'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: AnimatedScale(
                    scale: _over ? 1.06 : 1,
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    child: _Photo(n: n, topic: widget.topic),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _Meta(n: n),
              const SizedBox(height: 6),
              Text(
                '${n['titulo']}',
                maxLines: widget.big ? 4 : 3,
                overflow: TextOverflow.ellipsis,
                style: titleStyle?.copyWith(fontWeight: FontWeight.w600, height: 1.25),
              ),
              if (widget.big && '${n['resumo'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  '${n['resumo']}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Thumbnail on the left, section chip and headline on the right.
class _NewsRow extends StatelessWidget {
  const _NewsRow({required this.n, required this.topic});

  final Doc n;
  final String topic;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => abrirLink(context, '${n['url']}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(width: 112, height: 72, child: _Photo(n: n, topic: topic, small: true)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  _Meta(n: n),
                  Text(
                    '${n['titulo']}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(height: 1.25),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section chip (when the feed has one), source and time.
class _Meta extends StatelessWidget {
  const _Meta({required this.n});

  final Doc n;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.labelSmall;
    final category = '${n['categoria'] ?? ''}';
    final info = [n['fonte'], _when(n['data'] as String?)].where((x) => '${x ?? ''}'.isNotEmpty).join(' · ');
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (category.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: cores.primaryContainer, borderRadius: BorderRadius.circular(6)),
            child: Text(category, style: small?.copyWith(color: cores.onPrimaryContainer)),
          ),
        Text(info, style: small?.copyWith(color: cores.onSurfaceVariant)),
      ],
    );
  }
}

/// The article photo (cached on the device) fading in; without one, a gradient with the topic icon.
class _Photo extends StatelessWidget {
  const _Photo({required this.n, required this.topic, this.small = false});

  final Doc n;
  final String topic;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final url = '${n['imagem'] ?? ''}';
    final fallback = _Placeholder(topic: topic, small: small);
    if (url.isEmpty) return fallback;
    return Image(
      image: ImagemRede(url),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback,
      frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
        opacity: sync || frame != null ? 1 : 0,
        duration: const Duration(milliseconds: 400),
        child: frame == null && !sync ? fallback : child,
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.topic, required this.small});

  final String topic;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final cores = Theme.of(context).colorScheme;
    final icone = (_topics[topic] ?? _topics['economia']!).$2;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cores.primaryContainer, cores.tertiaryContainer],
        ),
      ),
      child: Center(
        child: Icon(icone, size: small ? 28 : 56, color: cores.onPrimaryContainer.withValues(alpha: 0.6)),
      ),
    );
  }
}

/// "há 25 min", "há 3 h" or "ontem 18:40".
String _when(String? iso) {
  final d = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 60) return 'há ${diff.inMinutes.clamp(1, 59)} min';
  if (diff.inHours < 24) return 'há ${diff.inHours} h';
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
