// Fluxo de etapas: 3 a 5 etapas em sequência, ligadas por uma linha que se desenha de nó em nó.
ESTUDIO.peca("fluxo_etapas", (k, c, box) => {
  const { U } = k;
  const e = c.encaixes, b = c.botoes;
  const vel = { lenta: 1.5, normal: 1.0, rapida: 0.65 }[b.velocidade] || 1.0;
  if (c.takeover) k.fundo(c);
  else k.veu(c, "cheio");

  const etapas = (Array.isArray(e.etapas) ? e.etapas : []).slice(0, 5);
  const corpo = k.$("div", "fe-corpo", box);
  let t0 = c.t + 0.1;
  if (e.titulo) {
    const tit = k.$("div", "fe-titulo", corpo, k.rico(k.esc(e.titulo).replace(/\\\*/g, "*")));
    k.entra(tit, c.t + 0.1, { de: { y: 2 * U } });
    t0 = c.t + 0.6;
  }
  const lista = k.$("div", "fe-lista", corpo);
  const n = Math.max(etapas.length, 1);
  const total = Math.max(c.ate - c.t, 2);
  const passo = Math.max(0.3, Math.min(1.1 * vel, (total - (t0 - c.t) - 1.2) / n));
  const marca = b.marcador === "check";

  etapas.forEach((txt, i) => {
    const ti = t0 + i * passo;
    const ult = i === n - 1;
    const et = k.$("div", "fe-etapa", lista);
    const no = k.$("div", "fe-no", et, `<span>${marca ? "✓" : i + 1}</span>`);
    const rot = k.$("div", "fe-rot", et, k.esc(txt));
    if (!ult) {
      const lig = k.$("div", "fe-lig", et);
      const ini = k.V ? { scaleY: 0 } : { scaleX: 0 };
      const fin = k.V ? { scaleY: 1 } : { scaleX: 1 };
      k.tl.fromTo(lig, { ...ini, opacity: 1 }, { ...fin, opacity: 1, duration: passo * 0.8, ease: k.SUAVE }, ti + 0.25 * vel);
    }
    k.entra(no, ti, { de: { scale: 0.5 } });
    k.entra(rot, ti + 0.12, { de: { y: 1.5 * U } });
    if (ult && b.final !== "nenhum") {
      no.classList.add("fe-ult");
      const halo = k.$("div", "fe-halo", no);
      k.tl.fromTo(halo, { scale: 1, opacity: 0.8 }, { scale: 1.6, opacity: 0, duration: 0.9, ease: k.SUAVE, repeat: 1 }, ti + 0.5);
    }
  });
});
