// Citação de estudo em 2,5D: folha sobre a mesa, marca-texto, tradução num cartão à frente e selo de autor/ano.
ESTUDIO.peca("estudo_folha_25d", (k, c, box) => {
  const { U, V } = k;
  const e = c.encaixes, b = c.botoes;
  const t0 = c.t;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  if (b.marcador === "acento") box.classList.add("ep-acento");

  const rico = (s) => k.esc(String(s || "")).replace(/\*([^*]+)\*/g, '<span class="d">$1</span>');

  const cena = k.$("div", "ep-cena", box);
  const palco = k.$("div", "ep-palco", cena);

  // folha
  const folha = k.$("div", "ep-folha", palco);
  k.$("div", "ep-cab", folha, "<span>" + k.esc(e.revista || "") + "</span>");
  const fio = (larg) => { const f = k.$("div", "ep-fio", folha); f.style.width = larg; return f; };
  fio("72%");
  const src = String(e.trecho_en || "");
  let html = "", last = 0, n = 0;
  src.replace(/\*([^*]+)\*/g, (m, g, i) => {
    html += k.esc(src.slice(last, i)) + '<mark class="ep-m">' + k.esc(g) + "</mark>";
    last = i + m.length; n++; return m;
  });
  html += k.esc(src.slice(last));
  if (!n) html = '<mark class="ep-m">' + html + "</mark>";
  const tx = k.$("div", "ep-tx", folha, html);
  fio("94%"); fio("88%"); fio("40%");

  // cartão da tradução
  const card = k.$("div", "ep-card", palco);
  k.$("div", "ep-rot", card, "tradução");
  k.$("div", "ep-ct", card, rico(e.traducao));

  // selo
  const selo = k.$("div", "ep-selo", palco,
    (e.ano ? '<b class="ep-ano">' + k.esc(e.ano) + "</b>" : "") + '<span class="ep-aut">' + k.esc(e.autor || "") + "</span>");

  // câmera: chega sobre a mesa e depois respira até o fim
  const orb = b.camera === "orbita";
  const de = orb
    ? { rotationX: 40, rotationY: -34, rotationZ: -4, z: -20 * U, y: 4 * U }
    : { rotationX: 56, rotationY: -8, rotationZ: -10, z: -30 * U, y: 6 * U };
  const yFim = orb ? 4 : -6;
  k.tl.fromTo(palco, de, { rotationX: 12, rotationY: yFim, rotationZ: -1, z: 0, y: 0, duration: 1.5, ease: k.SUAVE }, t0);
  const t1 = t0 + 1.5;
  if (c.ate > t1 + 0.2) {
    k.tl.fromTo(palco, { rotationX: 12, rotationY: yFim, rotationZ: -1, z: 0 },
      { rotationX: 8, rotationY: -2, rotationZ: 0, z: 3 * U, duration: c.ate - t1, ease: "none", immediateRender: false }, t1);
  }
  k.tl.fromTo(folha, { opacity: 0 }, { opacity: 1, duration: 0.5, ease: "power1.out" }, t0);

  // marca-texto varre as partes marcadas, em sequência
  const ms = Array.from(tx.querySelectorAll(".ep-m"));
  const total = ms.reduce((s, m) => s + m.textContent.length, 0) || 1;
  const orc = Math.min(1.4, Math.max(0.7, (c.ate - t0) * 0.25));
  let tm = t0 + 1.0;
  ms.forEach((m) => {
    const d = orc * m.textContent.length / total;
    k.tl.fromTo(m, { backgroundSize: "0% 72%" }, { backgroundSize: "100% 72%", duration: d, ease: "power1.inOut" }, tm);
    tm += d;
  });

  // cartão vem à frente, na batida da tradução
  let tc = c.batidas.traducao != null ? c.batidas.traducao : t0 + 2.2;
  tc = Math.max(t0 + 1.0, Math.min(tc, c.ate - 1.2));
  k.tl.fromTo(card, { opacity: 0, z: 0, y: 4 * U },
    { opacity: 1, z: (V ? 18 : 28) * U, y: 0, duration: 0.7, ease: k.SUAVE }, tc);

  // selo carimba por último
  const zs = (V ? 10 : 14) * U;
  k.tl.fromTo(selo, { opacity: 0, scale: 1.7, rotation: -12, z: zs },
    { opacity: 1, scale: 1, rotation: -4, z: zs, duration: 0.4, ease: "back.out(1.6)" }, tc + 0.45);
});
