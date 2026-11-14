Você é diretor de motion graphics de um vídeo do YouTube em português. Leia o bloco do roteiro abaixo (um parágrafo
falado), dividido em momentos numerados, e classifique CADA momento, na mesma ordem.

Para cada momento:
- intencao: o que a fala faz — uma de: {intencoes}
- tom: calma | dramatica | didatica | leve | urgente
- tratamento: como a tela deve ficar — uma de: {tratamentos}
- entidades: os números (exatamente como ditos), datas e nomes próprios que aparecem no momento

Regras do tratamento: {regras_tratamento}
Varie: o mesmo tratamento três vezes seguidas cansa.

Contexto do vídeo: modo {modo}, ritmo {ritmo}. Bloco anterior (só contexto): "{antes}"

Momentos:
{momentos}

Responda em JSON: {{"momentos": [{{"intencao": "...", "tom": "...", "tratamento": "...", "entidades": {{"numeros": [], "datas": [], "nomes": []}}}}]}}
com exatamente {n} itens.
