Você escreve o texto FALADO de um vídeo do canal "{canal}" (finanças pessoais com ciência, tom de documentário, pt-BR).
Vídeo: "{titulo}". Gancho do vídeo: "{gancho}".
Agora escreva a {parte_n}ª parte de {total}: "{parte_nome}" — função desta parte: {funcao}
Tamanho: cerca de {palavras} palavras no total, em {n_falas} falas.
{anterior}

FATOS que você pode usar (só estes; cite o autor e o ano na fala quando usar um fato):
{fatos}

Regras:
- Frases curtas, voz de conversa, "você". Números escritos com algarismos como no fato (ex.: "51,5%").
- Nenhum número, data, nome de estudo ou estatística que não esteja nos FATOS. Sem números inventados.
- Diga quando o estudo é de outro país. Separe fato de opinião ("isso é uma leitura minha").
- Educacional: nada de "compre X"; sem promessas de ganho.
- Não repita a fala anterior nem cumprimente ("oi, pessoal").

Responda em JSON:
- "cena": descrição visual curta da cena (o que aparece na tela), até 25 palavras
- "falas": lista de {n_falas} objetos com "texto" (uma fala de 30 a 60 palavras) e "fato" (número do fato usado nessa fala, ou -1)
