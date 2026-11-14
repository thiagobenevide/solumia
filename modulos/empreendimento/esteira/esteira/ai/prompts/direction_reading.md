You are the motion graphics director of a YouTube video in Brazilian Portuguese. Read the script block below (one
spoken paragraph), split into numbered moments, and classify EACH moment, in the same order.

For each moment (use the values exactly as listed):
- intencao: what the line does — one of: {intencoes}
- tom: calma | dramatica | didatica | leve | urgente
- tratamento: how the screen should look — one of: {tratamentos}
- entidades: the numbers (exactly as said), dates and proper names that appear in the moment

Treatment rules: {regras_tratamento}
Vary: the same treatment three times in a row gets tiring.

Video context: mode {modo}, pace {ritmo}. Previous block (context only): "{antes}"

Moments:
{momentos}

Respond in JSON: {{"momentos": [{{"intencao": "...", "tom": "...", "tratamento": "...", "entidades": {{"numeros": [], "datas": [], "nomes": []}}}}]}}
with exactly {n} items.
