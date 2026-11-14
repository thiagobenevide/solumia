Você escolhe o fundo visual (banco de vídeos/fotos: Pexels, Pixabay) de uma cena de um vídeo do canal "{canal}"
({estilo}). A cena dura {dur:.0f}s e o narrador fala:
"{texto}"

Antes: "{antes}"
Depois: "{depois}"
{nota}
Termos já usados nas cenas anteriores (evite repetir): {usados}

Primeiro descubra O QUE ESTA FALA MOSTRA: o objeto, a pessoa ou a ação de que ela trata. A imagem tem de
ilustrar ESTA fala, não o tema geral do vídeo. Ex.: "o cartão é a dívida mais comum" → cartão de crédito;
"quem ganha até um salário mínimo" → trabalhador com pouco dinheiro; "a Selic está em 15%" → banco central /
gráfico de juros; "a pessoa riscou a conta da lista" → mão riscando lista de papel.

Regras:
- "chave_en": 1–3 palavras em inglês com o que TEM de aparecer na imagem (o sujeito da fala), ex.:
  "credit card", "bills", "worker", "checklist". Serve para conferir as tags do resultado.
- "busca_en": 2–4 palavras em inglês, começando pela chave, CONCRETAS e filmáveis (pessoas, objetos, lugares,
  ações), da mais importante para a menos. Nunca conceitos abstratos: "medo" → "worried man dark room";
  "juros altos" → "credit card bills stack"; datas/épocas → objeto da época.
- "alternativas": até 2 outras buscas em inglês para a MESMA fala (outro enquadramento do mesmo sujeito),
  ex.: ["paying with credit card", "credit card close up"].
- "busca": a busca principal em português.
- "tipo": "video" para ação, ambiente, pessoas fazendo algo, cidade; "imagem" para objeto específico,
  documento, pessoa específica, lugar histórico.
- "clima": "tensao" (problema, risco, perda), "revelacao" (virada, descoberta, número chocante),
  "dado" (explicação, fato, número), "respiro" (conclusão, calma, solução) ou "neutro".

Responda em JSON: {{"chave_en": str, "busca_en": str, "alternativas": [str], "busca": str, "tipo": "video"|"imagem", "clima": str}}
