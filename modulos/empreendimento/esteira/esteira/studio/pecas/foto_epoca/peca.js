// Foto de época: porta-retrato ou recorte de jornal em sépia, grão de filme, data carimbada e legenda datilografada.
ESTUDIO.peca("foto_epoca", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const dur = Math.max(2, c.ate - c.t);
  const empilhada = b.camadas === "empilhada";
  if (c.takeover) k.fundo(c); else k.veu(c, "cheio");
  box.classList.add(b.moldura === "jornal" ? "fe-jornal" : "fe-retrato");
  box.classList.add(b.grao === "forte" ? "fe-grao-forte" : "fe-grao-leve");
  if (empilhada) box.classList.add("fe-emp");

  const m = e.midia;
  const src = typeof m === "string" ? m : (m && (m.src || m.url || m.caminho)) || "";
  const corpo = k.$("div", "fe-corpo", box);
  const cena = k.$("div", "fe-cena", corpo);
  const palco = k.$("div", "fe-palco", cena);
  const texto = k.$("div", "fe-texto", corpo);
  const graos = [];

  const quadro = (pai) => {
    const q = k.$("div", "fe-quadro", pai);
    const j = k.$("div", "fe-janela", q);
    let im = null;
    if (src) { im = k.$("img", "fe-img", j); im.src = src; im.alt = ""; }
    else k.$("div", "fe-vazio", j);
    graos.push(k.$("div", "fe-grao", j));
    k.$("div", "fe-vinheta", j);
    return { q, im };
  };

  // camadas de trás (só na variação empilhada), depois a foto da frente
  if (empilhada) {
    const cfg = [
      { rot: 6, x: 3.2 * U, y: -1.6 * U, z: -9 * U, t: 0.0 },
      { rot: -5, x: -3 * U, y: 1.8 * U, z: -4.5 * U, t: 0.14 }
    ];
    cfg.forEach((d) => {
      const { q, im } = quadro(palco);
      q.classList.add("fe-atras");
      if (im) im.style.filter = "sepia(1) brightness(.7) contrast(.95)";
      k.tl.fromTo(q, { opacity: 0, y: d.y - 14 * U, x: d.x, z: d.z, rotation: d.rot * 2.2 },
        { opacity: 1, y: d.y, x: d.x, z: d.z, rotation: d.rot, duration: 0.7, ease: k.SUAVE }, c.t + d.t);
    });
  }
  const f = quadro(palco);
  f.q.classList.add("fe-frente");
  k.tl.fromTo(f.q, { opacity: 0, y: 6 * U, scale: 0.93, rotation: -6, z: empilhada ? 3 * U : 0 },
    { opacity: 1, y: 0, scale: 1, rotation: -1.5, z: empilhada ? 3 * U : 0, duration: 0.85, ease: k.SUAVE }, c.t + (empilhada ? 0.28 : 0.1));
  if (f.im) {
    // "revelação" da foto: do clarão dessaturado ao sépia
    k.tl.fromTo(f.im,
      { filter: `sepia(1) brightness(1.7) contrast(.7) blur(${0.7 * U}px)`, scale: 1 },
      { filter: "sepia(.85) brightness(.95) contrast(1.05) blur(0px)", scale: 1.08, duration: dur, ease: "none" }, c.t + 0.2);
  }
  // respiração da câmera
  if (empilhada) k.tl.fromTo(palco, { rotationY: -9, rotationX: 3 }, { rotationY: 6, rotationX: -2, duration: dur, ease: "none" }, c.t);
  else k.tl.fromTo(palco, { scale: 1 }, { scale: 1.04, duration: dur, ease: "none" }, c.t);

  // grão de filme: salta de posição a cada 0,12 s
  const passos = Math.min(70, Math.floor(dur / 0.12));
  for (let i = 0; i < passos; i++) {
    const x = Math.round(k.rnd(i * 2 + 1) * 200), y = Math.round(k.rnd(i * 2 + 2) * 200);
    k.tl.set(graos, { backgroundPosition: `${x}px ${y}px` }, c.t + i * 0.12);
  }

  // data carimbada
  const tD = c.batidas.data != null ? c.batidas.data : c.t + 0.9;
  if (e.data) {
    const car = k.$("div", "fe-carimbo", texto, k.esc(e.data));
    k.tl.fromTo(car, { opacity: 0, scale: 2.3, rotation: -16 },
      { opacity: 1, scale: 1, rotation: -4, duration: 0.22, ease: "power3.in" }, tD);
    k.tl.fromTo(car, { y: 0 }, { y: 0.5 * U, duration: 0.06, yoyo: true, repeat: 1, ease: "none" }, tD + 0.22);
  }

  // legenda datilografada, letra por letra
  const leg = k.$("div", "fe-leg", texto);
  const chars = [];
  let pal = k.$("span", "fe-pal", leg);
  String(e.legenda || "").split("*").forEach((p, pi) => {
    for (const ch of p) {
      if (ch === " ") { leg.appendChild(document.createTextNode(" ")); pal = k.$("span", "fe-pal", leg); continue; }
      const s = k.$("span", "fe-ch", pal);
      if (pi % 2) s.classList.add("d");
      s.textContent = ch;
      chars.push(s);
    }
  });
  const t0 = c.t + 1.3;
  const livre = Math.max(0.8, dur - 1.3 - 0.7);
  const passo = Math.min(0.05, Math.max(0.012, livre / Math.max(1, chars.length)));
  chars.forEach((s, i) => k.tl.set(s, { opacity: 1 }, t0 + i * passo));
  // cursor piscando no fim
  const cur = k.$("span", "fe-cursor", leg, "&nbsp;");
  const tf = t0 + chars.length * passo;
  k.tl.set(cur, { opacity: 1 }, t0);
  for (let i = 0; i < 6; i++) k.tl.set(cur, { opacity: i % 2 ? 1 : 0 }, tf + 0.1 + i * 0.4);
});
