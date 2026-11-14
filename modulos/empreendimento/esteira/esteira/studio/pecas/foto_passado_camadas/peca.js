// Foto de época: porta-retrato ou recorte de jornal em sépia, grão de filme, data carimbada e legenda datilografada.
ESTUDIO.peca("foto_passado_camadas", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const camadas = b.disposicao === "camadas";
  const jornal = b.moldura === "jornal";
  const dur = Math.max(1, c.ate - c.t);
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  const m = e.midia;
  const src = (typeof m === "string" ? m : (m && (m.src || m.url || m.caminho || m.arquivo))) || "";

  const corpo = k.$("div", "fe-corpo", box);
  const cena = k.$("div", "fe-cena", corpo);
  const palco = k.$("div", "fe-palco", cena);

  function cartao(i) {
    const car = k.$("div", "fe-cartao " + (jornal ? "fe-jornal" : "fe-retrato") + (i ? " fe-fundo-n" : ""), palco);
    const foto = k.$("div", "fe-foto", car);
    k.$("div", "fe-vazio", foto);
    let img = null;
    if (src) {
      img = k.$("img", "fe-img", foto);
      img.src = src;
      img.alt = "";
      img.onerror = () => { img.style.display = "none"; };
      if (i === 1) img.style.objectPosition = "20% 30%";
      if (i === 2) img.style.objectPosition = "85% 70%";
    }
    const grao = k.$("div", "fe-grao", foto);
    k.$("div", "fe-vinheta", foto);
    if (jornal) k.$("div", "fe-linhas", car, "<i></i><i></i><i></i>");
    return { car, foto, img, grao };
  }

  const tn = c.t + 0.1;
  const principal = cartao(0);
  const main = principal.car;

  if (camadas) {
    const b1 = cartao(1).car, b2 = cartao(2).car;
    const alvo = [
      [b2, { x: 4 * U, y: -3.5 * U, rotation: 5, z: -22 * U }, tn],
      [b1, { x: -4 * U, y: -2 * U, rotation: -4, z: -10 * U }, tn + 0.12]
    ];
    alvo.forEach(([el, to, t]) => {
      k.tl.fromTo(el, { opacity: 0, x: 0, y: 0, rotation: 0, z: -70 * U },
        { opacity: 1, ...to, duration: 0.8, ease: k.SUAVE }, t);
    });
    k.tl.fromTo(main, { opacity: 0, y: 4 * U, z: -30 * U, rotation: -3 },
      { opacity: 1, y: 0, z: 0, rotation: -1, duration: 0.8, ease: k.SUAVE }, tn + 0.3);
    k.tl.fromTo(palco, { rotationY: -6, rotationX: 2 },
      { rotationY: 6, rotationX: -2, duration: dur, ease: "none" }, c.t);
  } else {
    k.tl.fromTo(main, { opacity: 0, y: 4 * U, scale: 0.92, rotation: -3 },
      { opacity: 1, y: 0, scale: 1, rotation: jornal ? -0.8 : 0.8, duration: 0.8, ease: k.SUAVE }, tn);
  }

  // Câmera lenta sobre a foto principal
  if (principal.img) k.tl.fromTo(principal.img, { scale: 1 }, { scale: 1.09, duration: dur, ease: "none" }, c.t);

  // Grão de filme oscilando quadro a quadro (determinístico)
  const passoG = 0.09;
  const nG = Math.min(120, Math.floor(dur / passoG));
  for (let i = 0; i < nG; i++) {
    const x = Math.round(k.rnd(i + 1) * 30 * U), y = Math.round(k.rnd(i + 97) * 30 * U);
    k.tl.set(principal.grao, { backgroundPosition: x + "px " + y + "px", opacity: 0.28 + k.rnd(i + 311) * 0.14 }, c.t + i * passoG);
  }

  // Data carimbada (fora do recorte da foto, para nunca ser cortada)
  let ts = c.batidas.data != null ? c.batidas.data : tn + 1.0;
  ts = Math.max(tn + 0.4, Math.min(ts, c.ate - 1.4));
  if (e.data) {
    const selo = k.$("div", "fe-selo", principal.car, k.esc(e.data));
    k.tl.fromTo(selo, { opacity: 0, scale: 1.6, rotation: -14 },
      { opacity: 1, scale: 1, rotation: -5, duration: 0.28, ease: "power4.in" }, ts);
    k.tl.fromTo(selo, { x: 0 }, { x: 0.5 * U, duration: 0.04, repeat: 3, yoyo: true, ease: "none" }, ts + 0.28);
    k.tl.fromTo(corpo, { y: 0 }, { y: 0.5 * U, duration: 0.06, repeat: 1, yoyo: true, ease: "none" }, ts + 0.28);
  }

  // Legenda datilografada
  if (e.legenda) {
    const txt = String(e.legenda);
    const html = txt.split(" ").map(p =>
      '<span class="fe-pal">' + Array.from(p).map(ch => '<span class="fe-c">' + k.esc(ch) + "</span>").join("") + "</span>"
    ).join(" ");
    const leg = k.$("div", "fe-leg", corpo, html);
    const cs = leg.querySelectorAll(".fe-c");
    const t0 = ts + 0.45;
    const passo = Math.min(0.045, Math.max(0.012, (c.ate - 0.5 - t0) / Math.max(1, cs.length)));
    cs.forEach((el, i) => k.tl.set(el, { opacity: 1 }, t0 + i * passo));
  }
});
