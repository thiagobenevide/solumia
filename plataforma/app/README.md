# agent (app Flutter)

App principal da plataforma: navegação entre os módulos (`lib/shell.dart`), tema e a lista de módulos
(`lib/main.dart`, `lib/modulos.dart`). Cada módulo traz as próprias telas como pacote em `modulos/<m>/app`.

```sh
# na raiz do repositório (pub workspace)
flutter pub get
cd plataforma/app
flutter run -d web-server --web-port 5577     # abrir http://localhost:5577 no navegador
flutter run -d linux                          # precisa de clang, cmake, ninja e libgtk-3-dev
```

O módulo Empreendimento fala com o painel da esteira (`./dark painel`, padrão `http://localhost:8765`).
Outro endereço: `--dart-define=ESTEIRA_URL=http://<ip-do-pc>:8765`.
