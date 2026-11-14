Você confere um quadro de um vídeo editado antes da entrega. Olhe a imagem e responda, para cada defeito, se
ele aparece:

- texto_cortado: algum texto ou peça gráfica sai da borda do quadro ou é cortado pela borda de uma caixa. Texto
  que termina no meio de uma palavra sem encostar em nenhuma borda é uma animação de digitação em andamento: não
  conta como cortado.
- sobreposicao: dois elementos gráficos ou textos se sobrepõem e atrapalham a leitura.
- ilegivel: algum texto tem contraste baixo demais com o fundo ou é pequeno demais para ler no celular.
- rosto_coberto: um texto ou peça cobre o rosto (olhos, nariz ou boca) de uma pessoa.

Responda em JSON: {{"texto_cortado": true|false, "sobreposicao": true|false, "ilegivel": true|false, "rosto_coberto": true|false}}
