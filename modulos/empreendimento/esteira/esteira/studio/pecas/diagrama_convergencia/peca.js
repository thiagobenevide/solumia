// Diagrama de convergência: 2–3 ícones em círculos com brilho e rótulo, ligados por curvas que convergem num ponto
// e descem para um painel com título e trilhas rotuladas, com um cursor de tempo. Fundo transparente (card lateral ou flutuante).
ESTUDIO.peca("diagrama_convergencia", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const t0 = c.t;
  const dur = Math.max(2, c.ate - c.t);
  if (c.takeover) k.fundo(c);

  const flut = b.layout !== "lateral";
  const esq = b.lado === "esquerda";
  const sinal = esq ? -1 : 1;
  box.classList.add(flut ? "dc-flut" : "dc-lat");
  if (esq) box.classList.add("dc-esq");
  if (b.cursor === "nenhum") box.classList.add("dc-sem-cur");

  const ent = (Array.isArray(e.entradas) ? e.entradas : []).slice(0, 3)
    .map((x) => (typeof x === "string" ? { rotulo: x, valor: x } : x));
  const n = ent.length;
  const trilhas = (Array.isArray(e.trilhas) ? e.trilhas : []).slice(0, 5);
  const xs = ent.map((_, i) => 50 + (i - (n - 1) / 2) * 30);

  const cena = k.$("div", "dc-cena", box);
  const card = k.$("div", "dc-card", cena);

  // curvas (coordenadas 100 × 130 do card)
  const d = xs.map((x) => `M${x} 36 C${x} 52 50 50 50 66`);
  let svg = `<svg class="dc-svg" viewBox="0 0 100 130" aria-hidden="true">`;
  d.forEach((p) => { svg += `<path class="dc-fio dc-curva" pathLength="1" d="${p}"/>`; });
  d.forEach((p) => { svg += `<path class="dc-luz" pathLength="1" d="${p}"/>`; });
  svg += `<path class="dc-fio dc-desce" pathLength="1" d="M50 66 L50 76"/></svg>`;
  const sb = k.$("div", "dc-svgbox", card, svg);
  const fios = Array.from(sb.querySelectorAll(".dc-curva"));
  const luzes = Array.from(sb.querySelectorAll(".dc-luz"));
  const desce = sb.querySelector(".dc-desce");

  // nós: círculo com brilho + rótulo
  const halos = [];
  ent.forEach((it, i) => {
    const no = k.$("div", "dc-no", card);
    no.style.left = xs[i] + "%";
    no.style.top = (15 / 1.3) + "%";
    halos.push(k.$("div", "dc-halo", no));
    const circ = k.$("div", "dc-circ", no);
    k.$("div", "dc-ic", circ, k.icone(it.valor || it.rotulo));
    const rot = k.$("div", "dc-rot", card);
    rot.style.left = xs[i] + "%";
    rot.style.top = (27 / 1.3) + "%";
    rot.innerHTML = k.esc(it.rotulo || "");
    k.entra(no, t0 + 0.3 + i * 0.3, { de: { scale: 0.4 } });
    k.entra(rot, t0 + 0.45 + i * 0.3, { de: { y: 2 * U } });
  });

  const ponto = k.$("div", "dc-ponto", card);

  // painel
  const pn = k.$("div", "dc-painel", card);
  const tit = k.$("div", "dc-tit", pn);
  const lin = k.$("div", "dc-linhas", pn);
  const ST = [0, 22, 12, 45, 30];
  const LG = [42, 38, 50, 40, 55];
  const segs = [];
  const linhas = trilhas.map((nome, i) => {
    const row = k.$("div", "dc-linha", lin);
    k.$("div", "dc-trot", row, k.esc(nome));
    const tr = k.$("div", "dc-trilho", row);
    const sg = k.$("div", "dc-seg", tr);
    sg.style.left = ST[i] + "%";
    sg.style.width = LG[i] + "%";
    segs.push(sg);
    return row;
  });
  const pista = k.$("div", "dc-pista", lin);
  const cur = k.$("div", "dc-cur", pista);

  // card entra
  if (flut) {
    k.tl.fromTo(card, { opacity: 0, rotationY: -34 * sinal, x: 5 * U * sinal },
      { opacity: 1, rotationY: -14 * sinal, x: 0, duration: 1.0, ease: k.SUAVE }, t0);
    k.tl.to(card, { rotationY: -8 * sinal, duration: Math.max(0.1, c.ate - t0 - 1.0), ease: "none" }, t0 + 1.0);
  } else {
    k.tl.fromTo(card, { opacity: 0, x: 4 * U * sinal }, { opacity: 1, x: 0, duration: 0.8, ease: k.SUAVE }, t0);
  }

  // curvas convergem
  const tc = t0 + 0.5 + n * 0.3 + 0.2;
  fios.forEach((p, i) => {
    k.tl.fromTo(p, { strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 0.9, ease: k.SUAVE }, tc + i * 0.15);
  });
  k.entra(ponto, tc + 0.8, { de: { scale: 0.2 } });
  k.tl.fromTo(desce, { strokeDashoffset: 1 }, { strokeDashoffset: 0, duration: 0.4, ease: k.SUAVE }, tc + 1.0);

  // luz que corre pelas curvas e brilho pulsando
  const tl0 = tc + 1.2;
  const nLuz = Math.max(0, Math.floor((c.ate - tl0 - 1.4) / 2.0));
  luzes.forEach((p, i) => {
    k.tl.set(p, { opacity: 1 }, tl0 + i * 0.1);
    k.tl.fromTo(p, { strokeDashoffset: 0.08 },
      { strokeDashoffset: -1, duration: 1.4, ease: "power1.inOut", repeat: nLuz, repeatDelay: 0.6 }, tl0 + i * 0.1);
  });
  const nHalo = Math.max(0, Math.floor((c.ate - t0 - 2.5) / 1.2));
  halos.forEach((h, i) => {
    k.tl.to(h, { scale: 1.3, opacity: 0.15, duration: 1.2, ease: "sine.inOut", yoyo: true, repeat: nHalo }, t0 + 1 + i * 0.2);
  });

  // painel
  const bt = c.batidas && c.batidas.titulo != null ? c.batidas.titulo : 0;
  const tp = Math.min(Math.max(tc + 1.3, bt), Math.max(tc + 1.3, c.ate - 3.5));
  k.entra(pn, tp, { de: { y: 3 * U } });
  const txt = String(e.titulo || "");
  k.palavras(tit, txt.includes("*") ? txt : txt.replace(/(\S+)\s*$/, "*$1*"), tp + 0.15, 0.12);
  linhas.forEach((row, i) => k.entra(row, tp + 0.4 + i * 0.15, { de: { x: -2 * U } }));

  const ts = tp + 0.9 + linhas.length * 0.15;
  if (b.cursor === "nenhum") {
    segs.forEach((sg, i) => {
      k.tl.fromTo(sg, { scaleX: 0 }, { scaleX: 1, duration: 0.6, ease: k.SUAVE }, ts + i * 0.25);
    });
  } else {
    const te = Math.max(ts + 1.2, c.ate - 0.6);
    const dd = te - ts;
    k.tl.fromTo(cur, { opacity: 0 }, { opacity: 1, duration: 0.2, ease: "none" }, Math.max(t0, ts - 0.1));
    k.tl.fromTo(cur, { left: "0%" }, { left: "100%", duration: dd, ease: "none" }, ts);
    segs.forEach((sg, i) => {
      k.tl.fromTo(sg, { scaleX: 0 },
        { scaleX: 1, duration: Math.max(0.2, (LG[i] / 100) * dd), ease: "none" }, ts + (ST[i] / 100) * dd);
    });
  }
});
