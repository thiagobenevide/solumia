"""Geração local de imagens (RealVisXL V5, SDXL fotorrealista) na GPU. Roda com `.venv-img/bin/python`
(PyTorch e diffusers ficam fora do ambiente principal para não brigar com as libs CUDA do Whisper).

Uso: .venv-img/bin/python esteira/image/generate_sdxl.py pedidos.json
pedidos.json: [{"prompt", "negativo"?, "semente"?, "saida", "largura"?, "altura"?, "passos"?}]
Carrega o modelo uma vez e gera todos; imprime uma linha JSON por imagem pronta.
"""
import json
import sys
import time

import torch
from diffusers import DPMSolverMultistepScheduler, StableDiffusionXLPipeline

MODEL = "SG161222/RealVisXL_V5.0"
NEGATIVE = ("text, watermark, logo, signature, letters, caption, cartoon, anime, illustration, 3d render, "
            "deformed, disfigured, extra fingers, bad hands, blurry, lowres, jpeg artifacts, oversaturated")


def main(file):
    requests = json.load(open(file))
    pipe = StableDiffusionXLPipeline.from_pretrained(MODEL, torch_dtype=torch.float16, variant="fp16",
                                                     use_safetensors=True)
    pipe.scheduler = DPMSolverMultistepScheduler.from_config(pipe.scheduler.config, use_karras_sigmas=True)
    pipe.to("cuda")
    pipe.set_progress_bar_config(disable=True)
    for p in requests:
        t = time.time()
        g = torch.Generator("cuda").manual_seed(p.get("semente", 0))
        img = pipe(prompt=p["prompt"], negative_prompt=p.get("negativo", NEGATIVE), generator=g,
                   width=p.get("largura", 1344), height=p.get("altura", 768),
                   num_inference_steps=p.get("passos", 28), guidance_scale=p.get("guia", 5.0)).images[0]
        img.save(p["saida"])
        print(json.dumps({"saida": p["saida"], "seg": round(time.time() - t, 1)}), flush=True)


if __name__ == "__main__":
    main(sys.argv[1])
