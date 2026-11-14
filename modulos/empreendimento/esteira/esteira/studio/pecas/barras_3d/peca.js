// Barras 3D (Three.js): uma barra por valor cresce até a proporção dele, a câmera orbita devagar e o último valor fica
// em destaque. Rótulos e valores são HTML (fontes da pele), presos ao topo de cada barra pela projeção 3D a cada quadro.
ESTUDIO.peca("barras_3d", (k, c, raiz) => {
  const e = { titulo: "", valores: [], ...c.encaixes }, b = c.botoes;
  if (c.takeover) k.fundo(c);
  const vs = (e.valores || []).slice(0, 5).map((x) => ({ ...x, num: k.numero(x.valor) })).filter((x) => x.num);
  if (vs.length < 2) return k.outra("barras_comparacao", c, raiz);
  const { T, scene, cam, antes } = k.cena3d(raiz, c, { fov: 32 });
  // luz neutra (branca): quem leva a pele são os materiais; luz na cor do texto escurece tudo na pele clara
  scene.add(new T.AmbientLight(new T.Color(1, 1, 1), 0.6));
  const luz = new T.DirectionalLight(new T.Color(1, 1, 1), 1.2);
  luz.position.set(4, 8, 6);
  scene.add(luz);
  const max = Math.max(...vs.map((x) => x.num.n), 1e-6);
  const passo = 1.6, alt = 4.2, n = vs.length;
  const barras = vs.map((x, i) => {
    const ult = i === n - 1;
    const h = Math.max(0.08, (x.num.n / max) * alt);
    const geo = new T.BoxGeometry(1, h, 1);
    geo.translate(0, h / 2, 0); // cresce a partir do chão
    const mat = new T.MeshStandardMaterial({ color: k.cor3d(ult ? "destaque" : "acento"), roughness: 0.45, metalness: 0.1 });
    const m = new T.Mesh(geo, mat);
    m.position.x = (i - (n - 1) / 2) * passo;
    m.scale.y = 0.001;
    scene.add(m);
    const t = c.t + 0.4 + i * 0.3;
    k.tl.to(m.scale, { y: 1, duration: 0.9 * (k.ajuste(c).contagem_s / 0.9), ease: k.SUAVE }, t);
    const rot = k.$("div", "b3-rot" + (ult ? " b3-ult" : ""), raiz, `<div class="b3-v"></div><div class="b3-r">${k.esc(x.rotulo)}</div>`);
    k.entra(rot, t + 0.2, { de: { y: 1.5 * k.U } });
    k.contar(rot.querySelector(".b3-v"), x.num, t + 0.1, 0.9, true);
    return { m, h, rot };
  });
  const chao = new T.GridHelper(n * passo + 2, n * 2 + 2, k.cor3d("texto"), k.cor3d("texto"));
  chao.material.transparent = true;
  chao.material.opacity = 0.12;
  scene.add(chao);
  if (e.titulo) k.entra(k.$("div", "b3-tit", raiz, k.rico(e.titulo)), c.t, { de: { y: 2 * k.U } });
  const amplo = b.orbita === "ampla";
  // enquadramento: o vertical é estreito (câmera bem mais longe); a barra mais alta fica abaixo do título
  const dist = (7.5 + n * 1.3) * (k.V ? 2.2 : 1.15), alvo = new T.Vector3(0, alt * 0.62, 0), v = new T.Vector3();
  antes((t) => {
    const p = Math.min(1, Math.max(0, (t - c.t) / Math.max(1, c.ate - c.t)));
    const ang = (amplo ? -0.55 : -0.3) + p * (amplo ? 1.1 : 0.6);
    cam.position.set(Math.sin(ang) * dist, alt * 0.9, Math.cos(ang) * dist);
    cam.lookAt(alvo);
    cam.updateMatrixWorld();
    const caixa = raiz.getBoundingClientRect();
    barras.forEach(({ m, h, rot }) => {
      v.set(m.position.x, h * m.scale.y + 0.8, 0).project(cam); // acima do topo: o número não encosta na barra
      rot.style.left = ((v.x + 1) / 2) * caixa.width + "px";
      rot.style.top = ((1 - v.y) / 2) * caixa.height + "px";
    });
  });
});
