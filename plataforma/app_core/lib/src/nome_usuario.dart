import 'package:flutter/material.dart';

import 'armazem.dart';

/// Como a pessoa quer ser chamada (ex.: "Thiago Benevide"), guardado no aparelho. O login
/// (`thiagobenevide`) não dá para separar em nome e sobrenome, então a saudação pergunta uma vez.
class NomeUsuario {
  NomeUsuario._();

  /// Nome completo escolhido; vazio enquanto não definido.
  static final nome = ValueNotifier('');

  static const _arquivo = 'nome.json';

  static Future<void> carregar() async {
    try {
      final j = await (await Armazem.abrir('perfil')).lerJson(_arquivo);
      if (j is String) nome.value = j;
    } catch (_) {
      // sem armazenamento (teste, navegador privado): segue sem nome
    }
  }

  static Future<void> definir(String valor) async {
    nome.value = valor.trim();
    try {
      await (await Armazem.abrir('perfil')).gravarJson(_arquivo, nome.value);
    } catch (_) {}
  }

  /// "Thiago" de "Thiago Benevide"; vazio sem nome.
  static String get primeiro {
    final partes = nome.value.trim().split(RegExp(r'\s+'));
    return partes.first;
  }
}

/// Pergunta como a pessoa quer ser chamada e guarda.
Future<void> perguntarNome(BuildContext context) async {
  final campo = TextEditingController(text: NomeUsuario.nome.value);
  final valor = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Como quer ser chamado?'),
      content: TextField(
        controller: campo,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(hintText: 'ex.: Thiago Benevide'),
        onSubmitted: (v) => Navigator.pop(c, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
        FilledButton(onPressed: () => Navigator.pop(c, campo.text), child: const Text('Salvar')),
      ],
    ),
  );
  campo.dispose();
  if (valor != null && valor.trim().isNotEmpty) await NomeUsuario.definir(valor);
}
