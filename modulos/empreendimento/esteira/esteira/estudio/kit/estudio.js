// Runtime das cenas do Estúdio (HyperFrames + GSAP). Monta a composição a partir de dados:
//   CFG    {W, H, pele:{...}, legenda:{ativa}, ...}   (estilo resolvido para o formato)
//   MIDIA  [{ini, fim, src, tipo: "imagem"|"video", mov}]  (mídia curada do episódio = base)
//   CENAS  [{cena, t, ate, titulo, valores:[{rotulo, valor}], frase, takeover}]  (mapa do diretor)
//   WORDS  [{text, start, end}]  (legenda)
//   CFG.camera (modo apresentador) {src, foco:{x,y,h}, punch, punch_impacto, segs:[{t, ate, layout, punch}]}
//     layout: full (câmera cheia + punch-in) · split (peça + câmera num card) · tela (só motion) · broll (mídia)
// Tudo é posicionado em função de U (1% do lado menor) para valer em 16:9 e 9:16.
(function () {
  const $ = (tag, cls, pai, html) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html != null) e.innerHTML = html;
    (pai || document.body).appendChild(e);
    return e;
  };
  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  // número falado em português → {antes, n, depois, casas}: "R$ 1.200" → R$ | 1200 | "" ; "81,7%" → 81.7 %
  function numero(txt) {
    const m = String(txt || "").match(/^(.*?)(\d[\d.]*(?:,\d+)?)(.*)$/);
    if (!m) return null;
    const bruto = m[2];
    const casas = bruto.includes(",") ? bruto.split(",")[1].length : 0;
    const n = parseFloat(bruto.replace(/\./g, "").replace(",", "."));
    return isNaN(n) ? null : { antes: m[1], n, depois: m[3], casas, bruto };
  }
  const fmt = (v, casas) => v.toLocaleString("pt-BR", { minimumFractionDigits: casas, maximumFractionDigits: casas });

  const ICONES = {
    lampada: '<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-4 10.5c.8.8 1 1.5 1 2.5h6c0-1 .2-1.7 1-2.5A6 6 0 0 0 12 3z"/>',
    documento: '<path d="M7 3h7l4 4v14H7z"/><path d="M14 3v4h4M10 12h5M10 16h5"/>',
    dinheiro: '<rect x="3" y="6" width="18" height="12" rx="2"/><circle cx="12" cy="12" r="3"/>',
    grafico: '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
    alerta: '<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18v.5"/>',
    check: '<circle cx="12" cy="12" r="9"/><path d="M8 12l3 3 5-6"/>',
    relogio: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    cartao: '<rect x="2" y="5" width="20" height="14" rx="2"/><path d="M2 10h20M6 15h4"/>',
    cerebro: '<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 1V5a3 3 0 0 0-3-1zM15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 1"/>',
    pergunta: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.7M12 17v.5"/>',
    alvo: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',
    casa: '<path d="M3 11l9-7 9 7v9H3z"/><path d="M10 20v-6h4v6"/>',
  };
  const PALAVRAS_ICONE = [
    ["cartao", /cart[aã]o|fatura|cr[eé]dito|rotativo/i], ["dinheiro", /dinheiro|real|reais|sal[aá]rio|renda|pag/i],
    ["grafico", /juro|taxa|%|cresc|sub|aument|m[eé]dia/i], ["alerta", /cuidado|aten[cç][aã]o|perig|atras|inadimpl/i],
    ["cerebro", /c[eé]rebro|psicolog|mente|motiva|emo[cç]/i], ["documento", /estudo|pesquisa|artigo|relat[oó]rio|dado/i],
    ["relogio", /tempo|m[eê]s|ano|prazo|hoje|minuto/i], ["casa", /casa|fam[ií]lia|aluguel/i],
    ["alvo", /meta|objetivo|regra|foco/i], ["check", /certo|funciona|resolv|simples/i],
  ];
  const rnd = (i) => { const x = Math.sin(i * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };
  const NS = "http://www.w3.org/2000/svg";
  const svg = (tag, at, pai) => {
    const e = document.createElementNS(NS, tag);
    Object.entries(at || {}).forEach(([k, v]) => e.setAttribute(k, String(v)));
    if (pai) pai.appendChild(e);
    return e;
  };
  const icone = (texto) => {
    const k = (PALAVRAS_ICONE.find(([, re]) => re.test(texto)) || ["lampada"])[0];
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">${ICONES[k].replace(/<(path|circle|rect)/g, '<$1 pathLength="1"')}</svg>`;
  };

  // peças do acervo (estudio/pecas/<id>/peca.js, juntadas em assets/pecas.js): registram-se aqui antes do init
  const PECAS = {};
  window.__errosPecas = [];

  window.ESTUDIO = {
    peca(id, fn) { PECAS[id] = fn; },
    init({ tl, cfg, midia, cenas, words, sfx }) {
      const { W, H } = cfg;
      const V = H > W; // vertical
      const U = Math.min(W, H) / 100;
      const raiz = document.getElementById("root");
      const P = cfg.pele;
      const css = raiz.style;
      css.setProperty("--fundo", P.fundo); css.setProperty("--fundo2", P.fundo2 || P.fundo);
      css.setProperty("--texto", P.texto); css.setProperty("--destaque", P.destaque);
      css.setProperty("--apoio", P.apoio || P.destaque); css.setProperty("--acento", P.acento || P.texto);
      css.setProperty("--fD", P.fonte_destaque); css.setProperty("--fT", P.fonte_texto); css.setProperty("--fM", P.fonte_tecnica);
      css.setProperty("--fL", P.fonte_legenda || P.fonte_destaque); css.setProperty("--fE", P.fonte_editorial || P.fonte_destaque);
      const EF = { flash: 1, zoom: 1, brilho: 1, grade: 1, ...(cfg.efeitos || {}) };
      css.setProperty("--brilhoF", String(EF.brilho)); css.setProperty("--gradeF", String(EF.grade));
      css.setProperty("--U", U + "px");
      raiz.classList.add(V ? "vertical" : "horizontal");
      // variações do estilo (dado): fundo das cenas de motion, alinhamento, cartões, cantos; entradas alternam por cena
      const VIS = { entradas: ["desfoque"], fundo: "veu", alinhamento: "centro", cartao: "vidro", cantos: 1, ...(cfg.visual || {}) };
      raiz.classList.add("fundo-" + VIS.fundo, "al-" + VIS.alinhamento, "cartao-" + VIS.cartao);
      css.setProperty("--R", String(VIS.cantos));
      // linguagem de movimento (aba Identidade), layouts do apresentador e regras de cor (dados do estilo)
      const MOV = { curva: "suave", entrada: "", entrada_s: 0.4, saida: "fade", saida_s: 0.25, proibidos: [], ...(cfg.movimento || {}) };
      const PROIB = new Set((MOV.proibidos || []).map((s) => String(s).toLowerCase()));
      if (PROIB.has("flash")) EF.flash = 0;
      const LY = { split_lado: "direita", split_largura: 0.36, vertical_peca: "cima", reservar_inferior: false, ...(cfg.layouts || {}) };
      const RC = { inativos: 0.4, ...(cfg.regras_cor || {}) };
      css.setProperty("--inativo", String(RC.inativos));

      // ── base: mídia curada com movimento suave ──
      const camMidia = document.getElementById("midia");
      midia.forEach((m, i) => {
        const dur = Math.max(0.1, m.fim - m.ini);
        const el = m.tipo === "video" ? $("video", "clip m", camMidia) : $("img", "clip m", camMidia);
        el.src = m.src;
        el.id = "m" + i;
        el.setAttribute("data-start", m.ini.toFixed(3));
        el.setAttribute("data-duration", dur.toFixed(3));
        if (m.corte) el.setAttribute("data-media-start", m.corte.toFixed(3)); // trecho (render de um bloco)
        el.setAttribute("data-track-index", String(10 + (i % 2)));
        if (m.tipo === "video") { el.muted = true; el.setAttribute("muted", ""); el.setAttribute("playsinline", ""); }
        const mov = m.mov || "zoom_in";
        // força do movimento pela intensidade dos efeitos (zoom 0,5 = metade do deslocamento)
        const z = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, k === "scale" ? 1 + (v - 1) * EF.zoom : v * EF.zoom]));
        const de = z({ zoom_in: { scale: 1.02 }, zoom_out: { scale: 1.14 }, pan_esq: { scale: 1.12, x: 3 * U }, pan_dir: { scale: 1.12, x: -3 * U } }[mov] || { scale: 1.04 });
        const ate = z({ zoom_in: { scale: 1.14 }, zoom_out: { scale: 1.02 }, pan_esq: { x: -3 * U }, pan_dir: { x: 3 * U } }[mov] || { scale: 1.1 });
        tl.fromTo(el, de, { ...ate, duration: dur, ease: "none" }, m.ini);
      });

      // ── câmera do apresentador: um vídeo só, a caixa dele muda de layout (troca animada, nunca seca) ──
      const CAM = cfg.camera;
      // lado dos dados nos layouts lateral/flutuante/sólido: oposto ao rosto na gravação (ou o fixado no estilo)
      const LADO = LY.lado_dados === "esquerda" || LY.lado_dados === "direita" ? LY.lado_dados
        : CAM ? (CAM.foco.x > 0.5 ? "esquerda" : "direita") : "esquerda";
      if (CAM) {
        raiz.classList.add("apresentador");
        const caixa = $("div", "camcaixa", document.getElementById("cam"));
        const v = $("video", "clip camv", caixa);
        v.src = CAM.src; v.id = "camera"; v.muted = true; v.setAttribute("muted", ""); v.setAttribute("playsinline", "");
        v.setAttribute("data-start", "0");
        if (CAM.inicio) v.setAttribute("data-media-start", CAM.inicio.toFixed(3)); // trecho: a câmera começa no bloco
        v.setAttribute("data-duration", String(CAM.segs[CAM.segs.length - 1].ate));
        v.setAttribute("data-track-index", "5");
        v.style.objectPosition = `${(CAM.foco.x * 100).toFixed(1)}% ${(CAM.foco.y * 100).toFixed(1)}%`;
        v.style.transformOrigin = `${(CAM.foco.x * 100).toFixed(1)}% ${(CAM.foco.y * 100).toFixed(1)}%`;
        const r = 3 * U;
        // SPLIT pelo estilo: lado e largura do apresentador (16:9); peça em cima ou embaixo e 20% inferiores livres (9:16)
        const lw = LY.split_largura * W, m = r;
        const altV = LY.reservar_inferior ? 0.3 * H : 0.36 * H;
        const CARD = V ? { left: 0.06 * W, top: LY.vertical_peca === "baixo" ? 0.05 * H : 0.58 * H, width: 0.88 * W, height: altV, borderRadius: r }
          : { left: LY.split_lado === "esquerda" ? m : W - lw + m, top: m, width: lw - 2 * m, height: H - 2 * m, borderRadius: r };
        const CHEIA = { left: 0, top: 0, width: W, height: H, borderRadius: 0 };
        // lateral/flutuante: a câmera continua cheia e os dados ocupam o lado livre da gravação; com o rosto no meio
        // do quadro, a câmera desliza para o lado oposto aos dados (com punch suficiente para não mostrar borda)
        const VISIVEL = new Set(["full", "split", "lateral", "flutuante", "galeria"]);
        const caixaDe = (l) => ({ ...(l === "split" ? CARD : CHEIA), opacity: VISIVEL.has(l) ? 1 : 0 });
        const centrado = Math.abs(CAM.foco.x - 0.5) < 0.1;
        const solto = (l) => l === "lateral" || l === "flutuante";
        const quadro = (s) => {
          if (s.layout === "full") return { scale: s.punch ? CAM.punch_impacto : CAM.punch, x: 0 };
          if (solto(s.layout) && centrado && !V) return { scale: Math.max(CAM.punch, 1.25), x: (LADO === "esquerda" ? 1 : -1) * 0.1 * W };
          return { scale: solto(s.layout) || s.layout === "galeria" ? CAM.punch : 1, x: 0 };
        };
        CAM.segs.forEach((s, i) => {
          if (!i) { tl.set(caixa, caixaDe(s.layout), 0); tl.set(v, quadro(s), 0); return; }
          const ant = CAM.segs[i - 1];
          const geo = ant.layout === "split" || s.layout === "split" || solto(ant.layout) !== solto(s.layout);
          const d = geo ? 0.45 : 0.25;
          if (ant.layout !== s.layout) tl.to(caixa, { ...caixaDe(s.layout), duration: d, ease: "power3.inOut" }, Math.max(0, s.t - d / 2));
          // punch extra de impacto em corte seco; a volta ao punch base acompanha a troca de layout
          if (ant.layout === s.layout || !geo) tl.set(v, quadro(s), s.t);
          else tl.to(v, { ...quadro(s), duration: d, ease: "power3.inOut" }, Math.max(0, s.t - d / 2));
        });
      }
      const layoutEm = (t) => (CAM ? (CAM.segs.find((s) => s.t <= t + 1e-3 && t < s.ate) || {}).layout : null);

      // ── camadas ──
      // Linguagem das peças da esteira (graficos/modelos, as que viraram EffectCraft): rótulo mono espaçado, traço na
      // cor de destaque, número gigante contando, serifa itálica nos capítulos, entradas com desfoque e saída esmaecendo.
      const TK = document.getElementById("takeover");
      let tk = TK;
      const UI = document.getElementById("ui");
      let ui = UI; // o laço das cenas troca pelo grupo da cena (cor do gatilho) ou pela área do SPLIT
      const fx = document.getElementById("fx");
      const CURVAS = { suave: "power3.out", firme: "expo.out", elastica: PROIB.has("bounce") ? "power3.out" : "back.out(1.6)", linear: "none" };
      const SUAVE = CURVAS[MOV.curva] || "expo.out";
      const ENTRADAS = {
        desfoque: { de: { y: 3 * U, filter: "blur(10px)" }, ate: {} },
        deslizar: { de: { x: -6 * U, y: 0, filter: "blur(4px)" }, ate: {} },
        fade_deslize: { de: { y: 2.4 * U, filter: "blur(0px)" }, ate: {} },
        fade: { de: { y: 0, filter: "blur(0px)" }, ate: {} },
        revelar: { de: { y: 0, filter: "blur(0px)", clipPath: "inset(0% 100% 0% 0%)" }, ate: { clipPath: "inset(0% 0% 0% 0%)" } },
        mascara: { de: { y: 0, filter: "blur(0px)", clipPath: "inset(100% 0% 0% 0%)" }, ate: { clipPath: "inset(0% 0% 0% 0%)" } },
        escala: { de: { y: 0, scale: 0.86, filter: "blur(6px)" }, ate: {} },
      };
      let ENT = ENTRADAS.desfoque; // a da cena atual (o laço das cenas troca)
      const DUR_E = Math.max(0.35, MOV.entrada_s + 0.35);
      const entra = (el, t, vars = {}) => tl.fromTo(el, { opacity: 0, ...ENT.de, ...vars.de },
        { opacity: 1, y: 0, x: 0, scale: 1, rotation: 0, filter: "blur(0px)", duration: DUR_E, ease: SUAVE, ...ENT.ate, ...vars.ate }, t);
      const SAIDAS = { fade: {}, deslize: { y: -2 * U }, desfoque: { filter: "blur(8px)" }, corte: {} };
      const sai = (el, t) => tl.to(el, { opacity: 0, ...(SAIDAS[MOV.saida] || {}), duration: MOV.saida === "corte" ? 0.01 : Math.max(0.12, MOV.saida_s + 0.1), ease: "power2.in" }, t);
      const traco = (el, t, dur = 0.8) => tl.fromTo(el, { scaleX: 0 }, { scaleX: 1, duration: dur, ease: SUAVE }, t);
      const flash = (t) => {
        if (!EF.flash) return;
        tl.fromTo(fx, { opacity: 0 }, { opacity: Math.min(0.6, 0.35 * EF.flash), duration: 0.08 }, t);
        tl.to(fx, { opacity: 0, duration: 0.35 }, t + 0.08);
      };
      // *palavra* do diretor ou do apontamento → cor de destaque
      const rico = (s) => esc(s).replace(/\*(.+?)\*/g, "<b>$1</b>");
      const fim = (c) => Math.max(c.t + 0.6, c.ate - 0.4);
      // letras uma a uma (agrupadas por palavra para a quebra de linha não partir palavra)
      const letras = (el, txt, t, passo = 0.024) => {
        let k = 0;
        let marcada = false;
        String(txt).split(/\s+/).filter(Boolean).forEach((p0) => {
          const w = $("span", "pl", el);
          const abre = p0.startsWith("*"), p = p0.replace(/\*/g, "");
          if (abre) marcada = true;
          if (marcada) w.style.color = "var(--destaque)";
          if (/\*\W*$/.test(p0)) marcada = false;
          [...p].forEach((ch) => { entra($("span", "l", w, esc(ch)), t + k++ * passo, { de: { y: 1.2 * U, filter: "blur(14px)" } }); });
          el.appendChild(document.createTextNode(" "));
          k++;
        });
      };
      // palavras uma a uma; a última (ou as *marcadas*) em destaque
      const palavras = (el, txt, t, passo) => {
        const marcadas = /\*/.test(txt);
        const lista = String(txt).replace(/\*(.+?)\*/g, (_, m) => m.split(/\s+/).map((x) => "*" + x).join(" ")).split(/\s+/).filter(Boolean);
        lista.forEach((p, i) => {
          const d = marcadas ? p.startsWith("*") : i === lista.length - 1 && lista.length > 1;
          entra($("span", d ? "pw d" : "pw", el, esc(p.replace(/^\*/, ""))), t + i * passo, { de: { y: 2 * U, scale: 0.96, filter: "blur(12px)" } });
        });
      };
      // `inteiro`: o elemento é o valor todo (com a unidade); senão a unidade fica num <small> ao lado
      const contar = (el, num, t, dur, inteiro) => {
        const o = { v: 0 };
        const ano = !num.casas && num.n >= 1900 && num.n <= 2100 && !/[.,]/.test(String(num.bruto));
        const txt = () => num.antes + (ano ? String(Math.round(o.v)) : fmt(o.v, num.casas)) + (inteiro ? num.depois : "");
        el.textContent = txt();
        tl.to(o, { v: num.n, duration: dur, ease: "power4.out", onUpdate: () => { el.textContent = txt(); } }, t);
      };
      const valorHtml = (txt) => {
        const num = numero(txt);
        return num ? { num, html: `<span class="nn">${esc(num.antes)}0</span><small>${esc(num.depois)}</small>` } : { num: null, html: esc(txt) };
      };

      // véu das cenas só de motion: escurece e desfoca a mídia (a profundidade fica), com grade e brilho da pele
      const fundoTk = (c) => {
        const f = $("div", "tkfundo", TK, '<div class="grade"></div><div class="brilho"></div>');
        if (tk.classList.contains("soltas")) f.style.display = "none"; // lateral/flutuante/sólido: a imagem (ou o sólido) fica
        else if (tk !== TK) TK.insertBefore(f, tk); // no SPLIT o fundo fica atrás da área da peça
        tl.fromTo(f, { opacity: 0 }, { opacity: 1, duration: 0.45, ease: "power2.out" }, c.t - 0.1);
        tl.fromTo(f.querySelector(".brilho"), { x: -10 * U }, { x: 10 * U, duration: Math.max(0.5, c.ate - c.t), ease: "none" }, c.t);
        // poeira de luz subindo devagar (posições fixas por semente: o render em paralelo vê sempre as mesmas)
        if (!PROIB.has("particulas")) {
          const po = $("div", "poeira", f);
          for (let k = 0; k < 18; k++) {
            const d = $("i", "", po);
            d.style.left = (rnd(k + c.t) * 100).toFixed(1) + "%";
            d.style.top = (20 + rnd(k * 3.1 + c.t) * 80).toFixed(1) + "%";
            d.style.width = d.style.height = ((0.25 + rnd(k * 7.7) * 0.6) * U).toFixed(1) + "px";
            tl.fromTo(d, { y: 0, opacity: 0 }, { y: -(5 + rnd(k) * 12) * U, opacity: 0.15 + 0.45 * rnd(k * 1.3), duration: Math.max(1, c.ate - c.t), ease: "none" }, c.t);
          }
        }
        // varredura de luz na entrada
        if (!PROIB.has("luz")) {
          const lz = $("div", "luz", f);
          tl.fromTo(lz, { xPercent: -130, opacity: 0 }, { xPercent: 130, opacity: 1, duration: 1.1, ease: "power2.inOut" }, c.t - 0.05);
          tl.to(lz, { opacity: 0, duration: 0.3 }, c.t + 0.75);
        }
        sai(f, fim(c));
        return f;
      };
      // véu parcial das peças sobre a mídia (escurece só a faixa onde está o texto); no SPLIT a área já é limpa
      const veu = (c, cls) => {
        if (ui === tk) return;
        const v = $("div", "veu " + cls, ui);
        ui.insertBefore(v, ui.firstChild); // sempre atrás do conteúdo (a caixa da peça já existe quando ela pede o véu)
        tl.fromTo(v, { opacity: 0 }, { opacity: 1, duration: 0.4 }, c.t - 0.05);
        tl.to(v, { opacity: 0, duration: 0.4 }, fim(c));
      };
      const kicker = (pai, txt, t) => { if (!txt) return null; const k = $("div", "kicker", pai, `<i></i>${rico(txt)}`); entra(k, t, { de: { x: -3 * U, y: 0 } }); traco(k.querySelector("i"), t); return k; };

      const CENA = {
        midia() {},
      };

      // ── peças do vocabulário VSL: proporção, conta, evolução, ranking, termo, alerta, tipografia cinética… ──
      // Cada uma tem várias camadas animadas (trilho, marcas, brilho, contagem, traço) e respeita o ajuste da peça
      // no estilo (`cfg.pecas[cena]`: contagem, tamanho, fonte) e a cor que o gatilho escolheu (var --destaque do grupo).
      const PC = (c) => ({ contagem_s: 0.9, tamanho: 1, fonte: "fonte_destaque", ...((cfg.pecas || {})[c.cena] || {}) });
      const FONTES = { fonte_destaque: "--fD", fonte_texto: "--fT", fonte_tecnica: "--fM", fonte_editorial: "--fE" };
      const proporcao = (c) => {
        const txt = [c.titulo, c.frase, ...(c.valores || []).map((x) => x.valor)].join(" ");
        const m = txt.match(/(\d+)\s+(?:em|de)\s+cada\s+(\d+)/i);
        if (m && +m[2]) return { p: (100 * +m[1]) / +m[2], num: { antes: "", n: +m[1], depois: ` em ${m[2]}`, casas: 0 }, rot: "" };
        const vs = c.valores || [];
        const v = vs.find((x) => /%/.test(x.valor)) || vs.find((x) => numero(x.valor) && !/fonte|ano/i.test(x.rotulo));
        const num = numero(v ? v.valor : (txt.match(/\d[\d.]*(?:,\d+)?\s*%/) || [""])[0]);
        if (!num) return null;
        return { p: Math.max(0, Math.min(100, num.n)), num: { ...num, depois: num.depois.trim() || "%" }, rot: v ? v.rotulo : "" };
      };
      const fonteDe = (c) => ((c.valores || []).find((x) => /fonte|ano/i.test(x.rotulo)) || {}).valor || "";
      const numeros = (c) => (c.valores || []).map((x) => ({ ...x, num: numero(x.valor) })).filter((x) => x.num);
      // número que conta + unidade pequena, entrando com escala
      const numeroGrande = (pai, num, t, dur, cls = "") => {
        const n = $("div", "ngr " + cls, pai, `<span class="nn"></span><small>${esc(num.depois)}</small>`);
        entra(n, t, { de: { y: 3 * U, scale: 0.9 } });
        contar(n.querySelector(".nn"), { ...num, depois: "" }, t + 0.05, dur, true);
        return n;
      };
      const auraFinal = (el, t) => tl.fromTo(el, { boxShadow: "0 0 0 0 rgba(0,0,0,0)" },
        { boxShadow: `0 0 ${5 * U}px ${0.6 * U}px color-mix(in srgb, var(--destaque) 45%, transparent)`, duration: 0.35, yoyo: true, repeat: 1 }, t);


      // 3D real (Three.js; peças `peso: "3d"`): cena, câmera e renderizador num canvas na caixa da peça. A cena é desenhada
      // pela própria timeline a cada quadro (onUpdate da timeline, depois de todos os tweens), só enquanto a peça está na
      // tela; nunca por requestAnimationFrame — o HyperFrames posiciona a timeline e o canvas segue (determinístico).
      const R3D = [];
      const cena3d = (raiz, c, op = {}) => {
        const T = window.THREE;
        if (!T) throw new Error("Three.js não carregado (peça 3d sem assets/three.min.js)");
        const cv = $("canvas", "cena3d", raiz);
        const renderer = new T.WebGLRenderer({ canvas: cv, antialias: true, alpha: true, preserveDrawingBuffer: true });
        renderer.setPixelRatio(1);
        renderer.setSize(W, H, false);
        const scene = new T.Scene();
        const cam = new T.PerspectiveCamera(op.fov || 35, W / H, 0.1, 1000);
        const item = { ini: c.t - 0.1, fim: c.ate + 0.6, antes: op.antes || null, render: () => renderer.render(scene, cam) };
        R3D.push(item);
        return { T, scene, cam, renderer, item, antes: (f) => { item.antes = f; } };
      };
      const cor3d = (papel) => new window.THREE.Color(getComputedStyle(raiz).getPropertyValue("--" + papel).trim() || "#808080");
      tl.eventCallback("onUpdate", () => {
        const t = tl.time();
        R3D.forEach((x) => { if (t >= x.ini && t <= x.fim) { if (x.antes) x.antes(t); x.render(); } });
      });

      // peça do acervo: o kit cria a caixa .peca.p-<id> na camada da cena, a peça anima dentro dela só com os
      // utilitários e a pele (variáveis CSS) e o kit faz a saída; erro numa peça não derruba o vídeo
      const K = { tl, U, V, W, H, $, esc, svg, entra, sai, traco, palavras, letras, contar, numero, fmt, icone, veu, kicker,
        flash, fim, rico, SUAVE, fundo: fundoTk, camada: (c) => (c.takeover ? tk : ui),
        // utilitários comuns das peças de dados (número grande, proporção, aura) e o que o estilo decidiu
        ajuste: PC, valorHtml, proporcao, fonteDe, numeros, numeroGrande, auraFinal, rnd, MOV, PROIB, EF,
        inativos: RC.inativos, midia: camMidia, cena3d, cor3d };
      // uma peça pode cair em outra quando o conteúdo não serve (anel sem porcentagem → contador)
      K.outra = (id, c, raiz) => (PECAS[id] ? PECAS[id](K, c, raiz) : null);
      Object.entries(PECAS).forEach(([id, fn]) => {
        CENA[id] = (c, i) => {
          const box = $("div", "peca p-" + id, K.camada(c));
          try {
            fn(K, { encaixes: {}, botoes: {}, batidas: {}, ...c }, box, i);
          } catch (e) {
            window.__errosPecas.push(id + ": " + e.message);
            console.error("peça " + id, e);
          }
          sai(box, fim(c));
        };
      });

      // peça do motor EffectCraft: já vem renderizada (WebM com alfa) e escrita no HTML pela compilação, na camada #ec
      // (o HyperFrames só extrai quadros dos vídeos que estão no HTML antes dos scripts); aqui não há nada a montar
      const pecaEC = () => {};

      // galeria: 3–4 cards de vidro em perspectiva com as mídias do episódio em volta do rosto (entrada escalonada)
      const POS_G = V ? [[.06, .05, .40, .22, 10], [.54, .07, .40, .2, -10], [.2, .3, .3, .17, 6]]
        : [[.06, .13, .17, .33, 12], [.25, .15, .13, .28, 7], [.62, .32, .17, .38, -8], [.79, .14, .13, .27, -12]];
      let galeriaN = 0;
      const galeria = (c) => {
        const depois = midia.filter((m) => m.fim > c.t), antes = midia.filter((m) => m.fim <= c.t).reverse();
        const vistas = new Set(), itens = [];
        for (const m of [...depois, ...antes]) if (!vistas.has(m.src) && itens.length < POS_G.length) { vistas.add(m.src); itens.push(m); }
        const dur = Math.max(0.5, c.ate - c.t);
        itens.forEach((m, k) => {
          const [l, t, w, h, giro] = POS_G[k];
          const card = $("div", "gcard", TK);
          Object.assign(card.style, { left: l * W + "px", top: t * H + "px", width: w * W + "px", height: h * H + "px" });
          const el = m.tipo === "video" ? $("video", "clip", card) : $("img", "clip", card);
          el.src = m.src;
          el.id = `g${galeriaN}_${k}`;
          el.setAttribute("data-start", c.t.toFixed(3));
          el.setAttribute("data-duration", dur.toFixed(3));
          if (m.tipo === "video") {
            el.setAttribute("data-media-start", ((m.corte || 0) + 0.5).toFixed(3));
            el.muted = true; el.setAttribute("muted", ""); el.setAttribute("playsinline", "");
          }
          el.setAttribute("data-track-index", String(60 + ((galeriaN * 4 + k) % 20)));
          const t0 = c.t - 0.1 + k * 0.12;
          tl.set(card, { transformPerspective: 1200, rotationY: giro, rotationX: 4 }, 0);
          tl.fromTo(card, { opacity: 0, y: 4 * U, scale: 0.9 }, { opacity: 1, y: 0, scale: 1, duration: 0.55, ease: "back.out(1.4)" }, t0);
          tl.to(card, { y: -1.2 * U, duration: dur, ease: "sine.inOut" }, t0 + 0.55); // flutua devagar
          tl.to(card, { opacity: 0, scale: 0.94, duration: 0.35, ease: "power2.in" }, fim(c) + k * 0.05);
        });
        galeriaN += 1;
      };

      cenas.forEach((c, i) => {
        // SPLIT: a peça fica na área livre (lado oposto ao apresentador) e a câmera no card; cada cena tem o seu grupo
        // (a cor do gatilho vale só para ela)
        const lay = c.layout || layoutEm(c.t + 0.05);
        if (lay === "galeria") galeria(c);
        const split = lay === "split" && CAM;
        if (lay === "lateral" || lay === "flutuante" || lay === "solido") {
          // dados soltos sobre a imagem (lateral: véu em degradê; flutuante: card de vidro em perspectiva) ou sobre
          // um fundo sólido na cor do estilo (sólido: card flutuante, sem a imagem atrás)
          if (lay === "solido") {
            const fs = $("div", "solido-fundo", TK, '<div class="grade"></div>');
            tl.fromTo(fs, { opacity: 0 }, { opacity: 1, duration: 0.4, ease: "power2.out" }, c.t - 0.12);
            tl.to(fs, { opacity: 0, duration: 0.4 }, fim(c));
          }
          const caixa = $("div", `solta ${lay} lado-${LADO}`, TK);
          tk = $("div", "area soltas", caixa);
          const card = lay === "flutuante"; // o sólido fica de frente, no centro (não há ninguém ao lado)
          const giro = card && !V ? (LADO === "esquerda" ? 14 : -14) : 0;
          const dx = lay === "solido" ? 0 : (LADO === "esquerda" ? -1 : 1) * 6 * U;
          tl.set(caixa, { transformPerspective: 1400, rotationY: giro, rotationX: card && !V ? 3 : 0 }, 0);
          tl.fromTo(caixa, { opacity: 0, x: dx, rotationY: giro * 1.8 }, { opacity: 1, x: 0, rotationY: giro, duration: 0.6, ease: "power3.out" }, c.t - 0.1);
          tl.to(caixa, { opacity: 0, x: dx, duration: 0.4, ease: "power2.in" }, fim(c));
          ui = tk;
        } else if (split) {
          tk = $("div", "area split", TK);
          if (V) {
            if (LY.vertical_peca === "baixo") { tk.style.top = "40%"; tk.style.height = LY.reservar_inferior ? "42%" : "58%"; }
          } else {
            const lw = LY.split_largura * 100;
            tk.style.left = LY.split_lado === "esquerda" ? lw + "%" : "0";
            tk.style.width = 100 - lw + "%";
          }
          ui = tk;
        } else {
          tk = c.takeover ? $("div", "grupo", TK) : TK;
          ui = c.takeover ? UI : $("div", "grupo", UI);
        }
        const pc = PC(c);
        const grupo = c.takeover || split || ui === tk ? tk : ui;
        if (c.cor && c.cor !== "destaque" && pc.cor !== "destaque" && P[c.cor]) grupo.style.setProperty("--destaque", P[c.cor]);
        if (pc.tamanho !== 1) grupo.style.setProperty("--esc", String(pc.tamanho));
        if (FONTES[pc.fonte] && pc.fonte !== "fonte_destaque") grupo.style.setProperty("--fD", `var(${FONTES[pc.fonte]})`);
        const ent = pc.entrada || (VIS.entradas.length > 1 || !MOV.entrada ? VIS.entradas[i % VIS.entradas.length] : MOV.entrada);
        ENT = ENTRADAS[ent] || ENTRADAS.desfoque;
        // atraso da peça em quadros relativo à palavra-âncora (o diretor já entra 0,08 s antes ≈ −3 quadros)
        const c2 = pc.atraso_q != null ? { ...c, t: Math.max(0, c.t + (pc.atraso_q + 3) / 30) } : c;
        (c.ec_src ? pecaEC : CENA[c.cena] || CENA.midia)(c2, i);
        // efeitos altos: flash na entrada das cenas de motion e "soco" de zoom na mídia nas peças por cima dela
        if (EF.flash >= 1.5 && c.takeover && c.cena !== "titulo_capitulo") flash(c.t);
        if (EF.zoom >= 1.4 && !c.takeover && c.cena !== "midia")
          tl.fromTo(camMidia, { scale: 1 + 0.03 * EF.zoom }, { scale: 1, duration: 0.4, ease: "power2.out" }, c.t);
      });
      tk = TK;
      ui = UI;

      // ── selo de progresso (layouts.selo): "● SELO | k/n capítulo" fixo no canto, com a barra do vídeo ──
      if (LY.selo) {
        const caps = cenas.filter((c) => c.cena === "titulo_capitulo" && c.titulo);
        const fimV = Math.max(1, ...cenas.map((c) => c.ate), ...midia.map((m) => m.fim), ...(CAM ? CAM.segs.map((s) => s.ate) : []));
        const selo = $("div", `selo lado-${LADO === "esquerda" ? "direita" : "esquerda"}`, UI,
          `<i></i><b>${esc(LY.selo)}</b><span class="selo-caps"></span><em><u></u></em>`);
        const lugar = selo.querySelector(".selo-caps");
        caps.forEach((c, k) => {
          const el = $("span", "selo-cap", lugar, `<small>${String(k + 1).padStart(2, "0")}/${String(caps.length).padStart(2, "0")}</small> ${esc(c.titulo)}`);
          tl.set(el, { opacity: 0 }, 0);
          tl.to(el, { opacity: 1, duration: 0.3 }, c.t);
          if (caps[k + 1]) tl.to(el, { opacity: 0, duration: 0.2 }, caps[k + 1].t - 0.1);
        });
        tl.fromTo(selo, { opacity: 0, y: -2 * U }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out" }, 0.6);
        tl.fromTo(selo.querySelector("u"), { scaleX: 0 }, { scaleX: 1, duration: fimV, ease: "none" }, 0);
      }

      // ── legenda palavra a palavra (1–3 palavras), escondida nas cenas de motion ──
      const LG = cfg.legenda || {};
      if (LG.ativa && words.length) {
        const cap = document.getElementById("cap");
        cap.classList.add(LG.posicao || "baixo", LG.caixa === "alta" ? "alta" : "normal", LG.acabamento || "sombra");
        css.setProperty("--capT", String(LG.tamanho || 1));
        const norm = (t) => t.toLowerCase().normalize("NFD").replace(/[^\p{L}\p{N}]/gu, "");
        const chaves = new Set((LG.chaves || []).map(norm));
        const ehChave = (t) => LG.destaque_chave !== false && (/\d/.test(t) || chaves.has(norm(t)));
        // rosto: logo abaixo do queixo na câmera cheia (object-fit cover + object-position no foco + punch)
        let topoRosto = null;
        if (LG.posicao === "rosto" && CAM && CAM.dim) {
          const [cw, ch] = CAM.dim, esc0 = Math.max(W / cw, H / ch), alt = ch * esc0;
          const yRosto = (H - alt) * CAM.foco.y + CAM.foco.y * alt, queixo = yRosto + 0.62 * CAM.foco.h * alt;
          topoRosto = H / 2 + (queixo - H / 2) * CAM.punch + 1.5 * U;
        }
        const ocupado = (ini, fim) => cenas.some((c) => c.cena !== "midia" && ini < c.ate && fim > c.t - 0.05);
        const max = Math.max(1, Math.min(3, LG.palavras || 3));
        let grupo = [];
        const solta = () => {
          if (!grupo.length) return;
          const ini = grupo[0].start, fim = grupo[grupo.length - 1].end;
          if (!ocupado(ini, fim)) {
            const html = grupo.map((w) => (ehChave(w.text) ? `<b class="ch">${esc(w.text)}</b>` : esc(w.text))).join(" ");
            const el = $("div", "pal", cap, `<span>${html}</span>`);
            const naCamera = topoRosto !== null && layoutEm(ini) === "full";
            if (naCamera) { el.style.top = topoRosto.toFixed(0) + "px"; el.style.bottom = "auto"; }
            tl.set(el, { opacity: 1 }, ini);
            tl.set(el, { opacity: 0 }, fim + 0.02);
          }
          grupo = [];
        };
        words.forEach((w, i) => {
          grupo.push(w);
          const prox = words[i + 1];
          if (grupo.length >= max || /[.,!?;:]$/.test(w.text) || !prox || prox.start - w.end > 0.25) solta();
        });
      }

      // ── efeitos sonoros (o compilador já limitou a densidade) ──
      const aud = document.getElementById("sfx");
      (sfx || []).forEach((s, i) => {
        const a = $("audio", "clip", aud);
        a.src = s.src; a.id = "s" + i;
        a.setAttribute("data-start", s.t.toFixed(3));
        a.setAttribute("data-duration", s.dur.toFixed(3));
        a.setAttribute("data-track-index", String(40 + (i % 8)));
        a.setAttribute("data-volume", String(s.vol));
      });
    },
  };
})();
