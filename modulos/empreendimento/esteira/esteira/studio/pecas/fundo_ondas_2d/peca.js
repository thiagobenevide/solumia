// Fundo de ondas: linhas finas que deslizam em laço, sem texto. Neutra.
ESTUDIO.peca("fundo_ondas_2d", (k, c, box) => {
  const e = c.encaixes, b = c.botoes;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "baixo");
  const vel = b.ritmo === "normal" ? 1 : 1.7;
  const n = b.densidade === "muitas" ? 9 : 5;
  const dur = Math.max(1, c.ate - c.t);
  const cls = ["fo-a", "fo-b", "fo-c"];
  // o assunto não aparece na tela: só muda a semente do desenho das ondas
  const txt = String(e.assunto || "");
  let sem = 0;
  for (let j = 0; j < txt.length; j++) sem = (sem * 31 + txt.charCodeAt(j)) % 997;
  const cena = k.$("div", "fo-cena", box);
  for (let i = 0; i < n; i++) {
    const r = k.rnd(i + 3 + sem);
    const base = 14 + (72 * (i + 0.5)) / n;
    const amp = 4 + 7 * r;
    const ciclos = 2 + (i % 3);
    const fase = r * Math.PI * 2;
    let d = "";
    for (let x = 0; x <= 400; x += 5) {
      const y = base + amp * Math.sin((Math.PI * 2 * ciclos * x) / 200 + fase);
      d += (x === 0 ? "M" : "L") + x + " " + y.toFixed(2) + " ";
    }
    const el = k.$("div", "fo-onda", cena,
      `<svg viewBox="0 0 400 100" preserveAspectRatio="none"><path class="${cls[i % 3]}" d="${d}"/></svg>`);
    const dir = i % 2 ? -1 : 1;
    const dd = (dur * 0.9 + 14 + 4 * i) * vel;
    const alvo = 0.3 + 0.25 * ((i % 3) / 2);
    k.tl.fromTo(el, { opacity: 0 }, { opacity: alvo, duration: 1.2, ease: k.SUAVE }, c.t + 0.08 * i);
    k.tl.fromTo(el, { xPercent: dir > 0 ? 0 : -50 }, { xPercent: dir > 0 ? -50 : 0, duration: dd, ease: "none" }, c.t);
    k.tl.to(el, { y: (i % 2 ? -1 : 1) * 1.2 * k.U, duration: dur, ease: "sine.inOut" }, c.t);
  }
});
