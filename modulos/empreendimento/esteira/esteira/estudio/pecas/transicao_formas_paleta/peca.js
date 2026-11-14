// Transição por formas da paleta: cobre a tela (0–45%), segura com a palavra opcional e descobre a próxima cena (55–100%).
ESTUDIO.peca("transicao_formas_paleta", (k, c, box) => {
  const { U, W, H, tl } = k;
  const e = c.encaixes, b = c.botoes;
  const forma = b.forma || "diagonal";
  const inv = b.sentido === "inverso";
  const d = Math.max(0.5, Math.min(1.2, (c.ate - c.t) - 0.05));
  const t0 = c.t;
  const L = Math.hypot(W, H);
  const EA = "power3.inOut";
  const cob = (f) => t0 + d * f;

  if (forma === "diagonal") {
    const S = L * 1.15;
    const wrap = k.$("div", "tf-diag", box);
    wrap.style.width = S + "px";
    wrap.style.height = S + "px";
    wrap.style.marginLeft = -S / 2 + "px";
    wrap.style.marginTop = -S / 2 + "px";
    tl.set(wrap, { rotation: inv ? 18 : -18, scaleX: inv ? -1 : 1 }, t0);
    const cores = ["tf-c1", "tf-c2", "tf-c3"];
    const ps = cores.map((cl) => k.$("div", "tf-painel " + cl, wrap));
    ps.forEach((p, i) => {
      tl.fromTo(p, { xPercent: -101 }, { xPercent: 0, duration: d * 0.3, ease: EA }, cob(i * 0.075));
    });
    [2, 1, 0].forEach((i, j) => {
      tl.to(ps[i], { xPercent: 101, duration: d * 0.3, ease: EA }, cob(0.55 + j * 0.075));
    });
  } else if (forma === "faixas") {
    const N = 6;
    const wrap = k.$("div", "tf-faixas", box);
    tl.set(wrap, { scaleX: inv ? -1 : 1 }, t0);
    const fs = [];
    for (let i = 0; i < N; i++) {
      const f = k.$("div", "tf-faixa tf-c" + (i % 3 === 1 ? 3 : i % 2 === 0 ? 1 : 2), wrap);
      fs.push(f);
      tl.fromTo(f, { scaleX: 0, transformOrigin: "0% 50%" }, { scaleX: 1, duration: d * 0.3, ease: EA }, cob(i * 0.03));
    }
    fs.forEach((f, i) => {
      tl.set(f, { transformOrigin: "100% 50%" }, cob(0.54));
      tl.to(f, { scaleX: 0, duration: d * 0.3, ease: EA }, cob(0.55 + (N - 1 - i) * 0.03));
    });
  } else {
    // íris: discos crescem do ponto de origem; depois um furo cresce e descobre a cena
    const cx = inv ? "100%" : "50%", cy = inv ? "100%" : "50%";
    const wrap = k.$("div", "tf-iris", box);
    const mk = (cl) => {
      const el = k.$("div", "tf-disco " + cl, wrap);
      el.style.left = cx; el.style.top = cy;
      tl.set(el, { xPercent: -50, yPercent: -50, width: 0, height: 0 }, t0);
      return el;
    };
    const ds = ["tf-c1", "tf-c2", "tf-c3"].map(mk);
    ds.forEach((el, i) => {
      tl.to(el, { width: 2 * L, height: 2 * L, duration: d * 0.3, ease: EA }, cob(i * 0.075));
    });
    const furo = k.$("div", "tf-furo", wrap);
    furo.style.left = cx; furo.style.top = cy;
    tl.set(furo, { xPercent: -50, yPercent: -50, width: 0, height: 0, autoAlpha: 0 }, t0);
    tl.set(furo, { autoAlpha: 1 }, cob(0.55));
    tl.set(ds, { autoAlpha: 0 }, cob(0.55));
    tl.to(furo, { width: 2 * L, height: 2 * L, duration: d * 0.45, ease: "power2.inOut" }, cob(0.55));
  }

  if (e.palavra) {
    const pal = k.$("div", "tf-pal", box, k.esc(e.palavra));
    tl.fromTo(pal, { autoAlpha: 0, scale: 0.85 }, { autoAlpha: 1, scale: 1, duration: d * 0.14, ease: k.SUAVE }, cob(0.3));
    tl.to(pal, { autoAlpha: 0, duration: d * 0.08, ease: "power1.in" }, cob(0.62));
  }
});
