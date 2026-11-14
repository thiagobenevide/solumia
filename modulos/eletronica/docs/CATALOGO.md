# Catálogo da bancada de eletrônica

Tudo o que a bancada precisa para prototipar e reparar peças de **computador, celular, monitor/TV e som**.
Prioridade: **1** = montar já (sem isso não se trabalha), **2** = crescer (aparece no primeiro mês de uso),
**3** = avançado (reballing, áudio de medição, programação de CIs específicos).

## 1. Segurança (antes de tudo)

| Item | Para quê | P |
|---|---|---|
| Transformador isolador 1:1 (≥ 300 VA) | Mexer em fonte de monitor/TV/ATX ligada sem choque nem estourar a ponta do osciloscópio | 1 |
| Lâmpada em série (60–100 W incandescente, com tomada) | Primeiro liga de fonte reparada: curto acende a lâmpada em vez de explodir | 1 |
| Variac (autotransformador variável) | Subir a tensão da rede aos poucos em fontes e amplificadores | 2 |
| Descarregador de capacitor (resistor 2–10 kΩ / 5–10 W com pontas) | Descarregar capacitor de PFC (400 V) e de fonte de som | 1 |
| Tapete ESD aterrado + pulseira | Placa de celular e memória morrem com estática | 1 |
| Óculos de proteção, extintor CO₂, extrator de fumaça com filtro de carvão | Solda, fluxo e capacitor que estoura | 1 |
| Tomada com DR/disjuntor dedicado na bancada | Desligar tudo de uma vez | 2 |

## 2. Solda e retrabalho

| Item | Para quê | P |
|---|---|---|
| Estação de solda com cartucho (T12/T245/C210) + pontas: faca (K), cônica fina (ILS), chanfrada (D16/BC2) | Solda fina SMD e THT | 1 |
| Estação de ar quente (com controle de fluxo) + bicos | Tirar/pôr CI QFN/SOIC, conector USB, flex | 1 |
| Pré-aquecedor de placa (IR ou placa quente 200 °C) | Placa de celular e de GPU multicamada não solda sem pré-aquecer | 2 |
| Estanho 0,3–0,5 mm Sn63/Pb37 com fluxo; SAC305 (sem chumbo) | Solda geral | 1 |
| Liga de baixa temperatura (Sn42Bi58, 138 °C) | Misturar no sem-chumbo para remover CI sem esquentar a placa | 2 |
| Pasta de solda (seringa) | Reflow com ar quente / stencil | 2 |
| Fluxo em gel (Amtech NC-559 ou similar) e fluxo líquido em caneta | Tudo | 1 |
| Malha dessoldadora 1,5 / 2,5 mm e sugador | Limpar pads | 1 |
| Stencils de reballing (por chip/modelo) + esferas 0,25–0,45 mm + base de reballing | BGA de celular, chipset, GDDR | 3 |
| Microscópio estereoscópico 7–45× (ou trinocular com câmera) | Inspeção e solda 0402/0201, trilha rompida | 2 |
| Lupa de bancada com luz LED | Inspeção rápida | 1 |
| Suporte de placa (garra universal) | Placa firme na solda | 1 |
| Lavadora ultrassônica + IPA 99 % + escova antiestática | Limpar oxidação de celular molhado e resíduo de fluxo | 2 |
| Fio esmaltado 0,02–0,1 mm e fio wire-wrap AWG 30 | Jumper de trilha e de pad arrancado | 1 |
| Máscara de solda UV + lanterna UV | Fixar jumper e proteger trilha reparada | 2 |

## 3. Instrumentos de medição

| Item | Para quê | P |
|---|---|---|
| Multímetro True RMS com diodo, continuidade, capacitância, frequência (ex.: UNI-T UT61E+, Fluke 17B+) | Medida básica; modo diodo é o diagnóstico principal de placa | 1 |
| Segundo multímetro (mais simples) | Medir tensão e corrente ao mesmo tempo | 2 |
| Fonte de bancada 0–30 V / 0–5 A com display de corrente (ideal programável, ex.: Riden RD6006/RD6012) | Alimentar placa e ver consumo: curto, boot, carga | 1 |
| Osciloscópio 2–4 canais ≥ 100 MHz (ex.: Rigol DHO804, Siglent SDS1104X-E) + pontas ×10 e ×100 | PWM de fonte, ripple, clock, barramento, sinal de áudio | 1 |
| Câmera térmica (InfiRay P2 Pro, Hikmicro) ou álcool isopropílico/breu | Achar componente em curto que esquenta | 2 |
| Injetor de tensão (fonte limitada em corrente, 1–3 V com alta corrente) | Forçar o componente em curto a esquentar | 2 |
| Testador de componentes (LCR-T7/TC1) | Identificar transistor/MOSFET/diodo desconhecido | 1 |
| Medidor de ESR / ponte LCR (ex.: DE-5000) | Capacitor eletrolítico seco em fonte e amplificador | 2 |
| Analisador lógico 8–16 canais 24 MHz+ (compatível sigrok) | I²C, SPI, UART, I²S de áudio | 2 |
| Medidor USB-C / PD (ex.: FNIRSI FNB58, ChargerLAB POWER-Z) | Carga de celular, negociação PD, consumo | 1 |
| Carga eletrônica DC | Testar fonte, carregador e bateria sob carga real | 2 |
| Gerador de funções / sinais (ou embutido no osciloscópio) | Injetar sinal em amplificador e filtro | 2 |
| Interface de áudio 24 bit + microfone de medição (UMIK-1/ECM8000) | Resposta de frequência, THD, ruído de amplificador e caixa | 3 |
| Frequencímetro / testador de cristal | Clock que não oscila | 3 |
| Testador de LED de backlight (0–300 V) | Barra de LED de TV/monitor queimada | 2 |
| Testador de fonte ATX | Fonte de PC antes de ligar na placa | 1 |

## 4. Programação, depuração e interfaces

| Item | Para quê | P |
|---|---|---|
| Programador CH341A + clip SOIC8 + adaptador 1,8 V | Regravar BIOS de placa-mãe/notebook, EEPROM de monitor (EDID) | 1 |
| Programador universal (XGecu T48/T56) | Flash NAND/eMMC, EEPROM, MCU, GAL | 3 |
| Adaptadores USB-UART (CP2102/CH340/FT232, 3,3 V e 1,8 V) | Console serial de roteador, TV box, placa de TV | 1 |
| ST-Link / J-Link / Raspberry Pi Pico como debugprobe | Gravar/depurar STM32, RP2040 e ARM | 2 |
| Placa POST code (PCIe/M.2/LPC) | Ver onde a placa-mãe para no boot | 1 |
| Cabo de boot (fonte DC) para celular | Ligar placa de celular sem bateria e ver consumo | 2 |
| Programadores de celular (JC/i2C para bateria, Face ID, True Tone) | Transplante de componente com par serial | 3 |
| Leitor eMMC/UFS (adaptador BGA) | Recuperar dado de celular com placa morta | 3 |
| Breakouts: USB-C, HDMI, DisplayPort, SATA, M.2, ATX 24 p | Medir sinal sem cortar cabo | 2 |

## 5. Ferramentas mecânicas e de desmontagem

| Item | Para quê | P |
|---|---|---|
| Jogo de chaves de precisão (Phillips 000–1, Torx T2–T10, Pentalobe, Tri-wing, Y, hexagonal) | Celular, notebook, console | 1 |
| Pinças ESD (reta fina, curva, cerâmica) | SMD | 1 |
| Espátulas plásticas, palhetas, ventosa, spudger, cartão metálico fino | Abrir celular e moldura de monitor | 1 |
| Separadora de tela (placa quente ~80 °C) + fio de corte de molibdênio | Separar vidro de display | 3 |
| Laminadora OCA e câmara de bolhas | Colar vidro novo em display | 3 |
| Alicate de corte rente, bico, desencapador, crimpador (JST/Dupont) | Fios e conectores | 1 |
| Furadeira micro (Dremel) e brocas 0,5–3 mm | Placa perfurada, gabinete | 2 |
| Impressora 3D (FDM) | Gabinete, suporte, jig de teste | 3 |

## 6. Componentes passivos (kits sortidos)

| Item | Para quê | P |
|---|---|---|
| Resistores SMD 0402, 0603, 0805 (série E24, 0 Ω a 10 MΩ) | Reparo e protótipo | 1 |
| Resistores THT ¼ W E24 + 1–5 W (shunt 0,1 Ω, 0,22 Ω de emissor de amplificador) | Protótipo, fonte, som | 1 |
| Capacitores MLCC 0402/0603/0805 (10 pF a 22 µF) | Desacoplamento, reparo de celular/placa-mãe | 1 |
| Eletrolíticos low-ESR 105 °C (10–1000 µF, 6,3–50 V) | Fonte de monitor/ATX, VRM, amplificador | 1 |
| Eletrolíticos de alta tensão (47–220 µF / 400–450 V) | Capacitor de PFC de fonte | 2 |
| Capacitores de polímero sólido (270–820 µF / 2,5–16 V) | VRM de placa-mãe e GPU | 2 |
| Capacitores de filme (poliéster, polipropileno) e X2/Y2 | Áudio (acoplamento, crossover) e filtro de rede | 2 |
| Tântalo SMD | Reparo de placa antiga e notebook | 2 |
| Indutores SMD de potência (1–100 µH), ferrites, chokes de modo comum | Buck/boost, EMI, linha USB | 1 |
| Fusíveis: vidro 5×20, SMD 0603/1206, PTC (polyfuse) | Proteção | 1 |
| Varistores (MOV 275 V), termistores NTC (5D-9, 10D-11) | Entrada de fonte, inrush | 2 |
| Cristais e ressonadores (32,768 kHz, 8, 12, 16, 24, 25 MHz) | Clock de MCU, RTC, Ethernet | 2 |
| Potenciômetros lineares (B) e logarítmicos (A), trimpots multivoltas | Volume, ajuste de tensão | 1 |

## 7. Semicondutores

| Item | Para quê | P |
|---|---|---|
| Diodos: 1N4148, 1N4007, Schottky SS14/SS34/1N5819, kit de Zener, TVS (SMBJ), pontes retificadoras | Geral, proteção, retificação | 1 |
| Diodos rápidos / ultrarrápidos (UF4007, MUR460, STTH) | Secundário de fonte chaveada | 2 |
| MOSFETs canal N/P lógicos (AO3400/AO3401, IRLZ44N, Si2302) e de potência (IRF540, IRFP260) | Chaveamento, proteção de polaridade | 1 |
| MOSFETs de VRM (dual/single DFN, ex.: 4C10N, AON6xxx, SiRA) e de fonte (600–650 V, ex.: 7N60, 20N60) | Reparo de placa-mãe e de fonte | 2 |
| Transistores BJT (BC547/BC557, 2N2222/2N2907, TIP41/42, par MJL3281/1302) | Lógica, driver, saída de amplificador classe AB | 1 |
| Reguladores lineares (AMS1117-3.3, LM7805, LM317, LDO 1,8 V) | Alimentação de protótipo | 1 |
| Conversores DC-DC (MP1584, LM2596, MP2307 buck; MT3608 boost) | Alimentação eficiente | 1 |
| Controladores PWM de fonte (UC3842/3843/3845, TL431, optoacopladores PC817, controladores de PFC) | Reparo de fonte de monitor/TV/ATX | 2 |
| Controladores de VRM multifase e drivers de MOSFET (família RT, uP, ISL, NCP) | Reparo de placa-mãe/GPU | 3 |
| Amplificadores operacionais (NE5532, TL072, OPA2134, LM358, MCP6002) | Pré-amplificador, filtro, instrumentação | 1 |
| CIs de amplificador: classe D (TPA3116, TPA3255, PAM8403), classe AB (TDA2030, TDA7294, LM3886) | Som | 1 |
| DACs/ADCs e codecs de áudio (PCM5102, ES9038Q2M, PCM1808, WM8960) | Fonte digital de som | 2 |
| Bluetooth áudio (QCC3034/QCC5125, BK3266) | Caixa e receptor Bluetooth | 2 |
| Carga e proteção de bateria (TP4056, IP5306, BQ24xxx, DW01 + 8205A, BMS 2–4S) | Power bank, aparelho a bateria | 1 |
| Controladores USB-C PD (CH224K, IP2721, FUSB302) | Pedir 9–20 V de carregador PD | 2 |
| Drivers de backlight LED (boost de corrente constante, ex.: OZ9967, MP3394) | Monitor/TV sem imagem com som | 2 |
| Memórias SPI/I²C (W25Q64/128, 24C02/24C08) | BIOS, EDID, configuração de TV | 1 |
| Microcontroladores (ESP32-S3, RP2040, STM32F103/G0, ATmega328P/ATtiny85) | Protótipo, jig de teste, controle | 1 |
| Lógica e interface (74HC595, 74HC245, conversor de nível TXS0108, multiplexador CD4051) | Expandir I/O, 3,3 ↔ 5 V | 2 |
| Sensores de corrente/tensão (INA219, INA226, ACS712) | Medição embarcada | 2 |
| LEDs (3 mm, 5 mm, SMD, endereçáveis WS2812) | Sinalização, iluminação | 1 |

## 8. Conectores, cabos e montagem

| Item | Para quê | P |
|---|---|---|
| Protoboards (830 pontos), placas perfuradas, adaptadores SMD→DIP (SOIC, SOT-23, QFN, TSSOP) | Protótipo | 1 |
| Jumpers Dupont (M-M, M-F, F-F), barras de pinos, soquetes torneados | Protótipo | 1 |
| JST PH 2,0 / XH 2,54 / SH 1,0 e kit de crimpagem | Bateria, ventoinha, módulo | 1 |
| Conectores FPC/FFC (0,5 / 1,0 mm, 4–60 vias) e cabos flat | Display, câmera, teclado de notebook | 2 |
| Cabos LVDS e eDP, conectores board-to-board de celular | Display de monitor/notebook/celular | 2 |
| Conectores USB-C, micro-USB e Lightning (fêmea SMD) | Troca de conector de carga | 1 |
| Áudio: P2 (3,5 mm), P10, RCA, XLR, Speakon, bornes de caixa | Som | 1 |
| Conectores de PC: ATX 24 p, EPS 8 p, PCIe 6+2, SATA, Molex, ventoinha 4 p PWM | Fonte e placa-mãe | 2 |
| Bornes de parafuso, terminais, termorretrátil, abraçadeiras, espaguete | Montagem | 1 |
| Fios cabinho AWG 22–28 (cores) e de silicone AWG 12–20 | Sinal e potência | 1 |
| Dissipadores, isoladores de mica/silicone, buchas, pasta térmica e thermal pads (0,5–3 mm) | Amplificador, fonte, VRM, GPU | 1 |

## 9. Módulos prontos para prototipar

| Item | Para quê | P |
|---|---|---|
| Placas ESP32-S3 DevKit, Raspberry Pi Pico, Arduino Nano, STM32 "Blue Pill" | Cérebro do protótipo | 1 |
| Displays: OLED 0,96" I²C, TFT 1,8–3,5" SPI, LCD 16×2 | Interface de protótipo | 1 |
| Controladora LCD universal HDMI/VGA → LVDS/eDP (ex.: M.NT68676, V59, placas eDP) | Transformar tela de notebook em monitor; testar painel | 2 |
| Placa T-con e main board universais de TV | Teste e substituição em TV/monitor | 3 |
| Módulos amplificadores (TPA3116 2×50 W, TPA3255, TDA7498) e pré com tonalidade | Protótipo de som | 1 |
| Módulos Bluetooth/DAC (QCC3034 + PCM5102) | Fonte de áudio | 2 |
| Módulos buck, boost, buck-boost, carregador de bateria, BMS | Alimentação | 1 |
| Módulo relé e de proteção de alto-falante (uPC1237) | Desligar caixa com DC na saída | 2 |
| Fonte chaveada fechada 12 V / 24 V / 48 V | Alimentar amplificador e protótipo | 1 |

## 10. Peças por área de trabalho

### Computadores
- Fontes ATX: capacitor de PFC, MOSFET/diodo de PFC, controlador PWM, standby 5VSB (o defeito mais comum), TL431, optoacoplador, ventoinha.
- Placa-mãe: MOSFETs e controladores de VRM, indutores, capacitores de polímero, chip BIOS SPI (W25Q128), bateria CR2032 e suporte, super I/O, reguladores de memória/chipset.
- GPU: MOSFETs/drivers de VRM, capacitores de polímero, thermal pads, memória GDDR (reballing — P3).
- Notebook: conector DC, chip de carga (BQ24xxx/ISL), EC, teclado/flat, dobradiças.
- Periféricos: switches de teclado, sensores de mouse, hubs USB.

### Celulares
- Baterias, conectores de bateria e de tela, flex de carga, conector USB-C/Lightning.
- CIs de carga/USB (Tristar/Hydra no iPhone, chips de carga Android), PMIC, backlight IC (em LCD), filtros e bobinas.
- Telas (LCD/OLED), vidro, OCA, adesivos de moldura, câmeras, alto-falantes, microfones MEMS, motores de vibração.
- Stencils de reballing por modelo, programadores de bateria/Face ID (P3).

### Monitores e TVs
- Fontes: capacitores de entrada e saída, MOSFET principal, controlador PWM, NTC, fusível, varistor.
- Backlight: barras/LEDs SMD, driver de backlight, inversor (CCFL em monitor antigo).
- Placas: main board (scaler), T-con, buffer/gamma IC, EEPROM de EDID (24C02) e de firmware.
- Cabos LVDS/eDP/V-by-One, botões, receptor de IR.

### Som
- Amplificadores classe AB e D, pré-amplificadores, controle de tonalidade, equalizador.
- Fonte linear: transformador toroidal (2×18 a 2×35 V), ponte, capacitores de filtro 4 700–10 000 µF, fonte simétrica.
- Crossovers passivos: indutores de núcleo de ar, capacitores de poliéster/polipropileno, resistores de fio.
- Alto-falantes, tweeters, drivers, cones, reparo de suspensão, cabos e conectores.
- Proteção de alto-falante (relé com atraso e detecção de DC), dissipação térmica, potenciômetros logarítmicos.

## 11. Consumíveis

Pasta térmica, thermal pads, fita kapton (8–50 mm), fita de alumínio, dupla face, cola B-7000/T-7000, cola UV,
termorretrátil, IPA 99 %, limpa-contato, flux remover, verniz conformal, placa de fenolite/fibra virgem,
percloreto (ou só PCB encomendada), lixa fina, cotonetes e palitos antiestáticos, organizadores com gavetas.

## 12. Software e recursos

| Recurso | Para quê |
|---|---|
| KiCad | Esquemático, PCB, BOM, gerber para fábrica |
| LTspice / ngspice / Qucs-S, Falstad (online) | Simulação antes de montar |
| sigrok / PulseView | Analisador lógico e alguns osciloscópios/multímetros |
| flashrom, NeoProgrammer / AsProgrammer | Gravar CH341A (BIOS, EEPROM) |
| OpenBoardView (`.brd`, `.bvr`, `.fz`) | Boardview de placa-mãe/notebook/celular |
| Esquemáticos e boardviews de reparo (sites especializados; ZXW/Borneo pagos para celular) | Diagnóstico |
| REW (Room EQ Wizard), Audacity, VituixCAD (crossover), WinISD (caixa) | Medição e projeto de som |
| FreeCAD | Gabinete, suporte, peças 3D |
| PlatformIO / Arduino IDE / ESP-IDF / Pico SDK | Firmware dos microcontroladores |
| Datasheets: LCSC, Mouser, Digi-Key, alldatasheet, Octopart | Pinagem e equivalência |
| Fabricação: JLCPCB / PCBWay (PCB + montagem SMT) | Placa própria |
| Compras no Brasil: Santa Ifigênia (SP), Baú da Eletrônica, Eletrogate, Mouser BR, LCSC/AliExpress | Peças |

## 13. Bancada mínima para começar (resumo da prioridade 1)

Isolador + lâmpada em série + ESD · estação de solda + ar quente · multímetro TRMS · fonte de bancada com
display de corrente · osciloscópio 2 canais · testador de componentes · medidor USB-C · CH341A + clip ·
USB-UART · placa POST · testador ATX · chaves de precisão, pinças e espátulas · kits de resistores, capacitores,
diodos, transistores, reguladores, op-amps · protoboard, jumpers, placas perfuradas · ESP32/Pico/Arduino ·
módulos de amplificador e de alimentação · consumíveis (estanho, fluxo, malha, IPA, kapton, pasta térmica).
