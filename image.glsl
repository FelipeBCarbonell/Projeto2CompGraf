// ============================================================================
//  IMAGE  -  Visualizador de audio neon (circunferencia + retangulos + warp)
//
//  Canais:  iChannel0 = Buffer A   (audio ja tratado: suavizado, filtrado, batida)
//           (a musica fica so no Buffer A; esta aba nao precisa de mais nenhum canal)
//
//  Controles:  clique e arraste o mouse -> X escolhe a paleta, Y desloca a cor.
//              sem mouse, a paleta troca sozinha (com transicao) a cada PAL_TIME s.
//
//  Tarefa C   : circunferencia e retangulos (1 por canal de FFT) seguindo a curva
//  Tarefa C+  : aleatoriedade (espessura, cor, resposta em frequencia, fundo),
//               glow/neon com SDF 2D de retangulo, controle de cores
//  Extras     : starfield/warp, camera shake + UV displacement + aberracao cromatica,
//               poligonos que reagem a musica, audio tratado (Buffer A),
//               paletas procedurais (cosine palettes - iquilezles.org/articles/palettes)
// ============================================================================

#define N_BARS    64        // precisa ser igual ao da aba Buffer A
#define PAL_TIME  18.0      // segundos entre trocas automaticas de paleta
#define N_PAL     5

#define R_RING    0.24      // raio base da circunferencia
#define BAR_GAP   0.035     // distancia entre a circunferencia e o inicio dos retangulos
#define BAR_MIN   0.012     // comprimento minimo de um retangulo
#define BAR_MAX   0.20      // comprimento maximo (barra no nivel 1.0)
#define GLOW      55.0      // queda do halo (maior = halo mais curto)

#define PI  3.14159265
#define TAU 6.28318531

// ---- dados vindos do Buffer A (preenchidos no mainImage) --------------------
float gBass, gPulse, gAng, gMid, gTre, gPalT, gBeats, gVol;
// ---- paleta atual -----------------------------------------------------------
int   gPalA, gPalB;
float gPalMix, gHue;

float hash11(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }
vec2  hash21(float n) { return fract(sin(vec2(n * 127.1, n * 269.5) + vec2(311.7, 183.3)) * 43758.5453); }

mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, s, -s, c); }   // gira o vetor por +a

// ---- SDFs 2D (iquilezles.org/articles/distfunctions2d) ----------------------
float sdRoundBox(vec2 p, vec2 b, float r)
{
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float sdNgon(vec2 p, float r, float n)      // poligono regular de n lados
{
    float an = PI / n;
    float bn = mod(atan(p.x, p.y), 2.0 * an) - an;
    p = length(p) * vec2(cos(bn), abs(sin(bn)));
    p -= r * vec2(cos(an), sin(an));
    p.y += clamp(-p.y, 0.0, r * sin(an));
    return length(p) * sign(p.x);
}

// ---- paletas procedurais ----------------------------------------------------
vec3 cosPal(float t, vec3 a, vec3 b, vec3 c, vec3 d) { return a + b * cos(TAU * (c * t + d)); }

vec3 preset(int id, float t)
{
    if (id == 0) return cosPal(t, vec3(0.50, 0.30, 0.75), vec3(0.50, 0.30, 0.25), vec3(1.0),           vec3(0.00, 0.10, 0.30)); // roxo/azul/magenta
    if (id == 1) return cosPal(t, vec3(0.50),             vec3(0.50),             vec3(1.0),           vec3(0.00, 0.33, 0.67)); // arco-iris
    if (id == 2) return cosPal(t, vec3(0.50),             vec3(0.50),             vec3(1.0, 1.0, 0.5), vec3(0.80, 0.90, 0.30)); // fogo
    if (id == 3) return cosPal(t, vec3(0.20, 0.55, 0.60), vec3(0.30, 0.45, 0.40), vec3(1.0, 0.7, 0.4), vec3(0.00, 0.15, 0.20)); // ciano/verde
    return              cosPal(t, vec3(0.80, 0.50, 0.40), vec3(0.20, 0.40, 0.20), vec3(2.0, 1.0, 1.0), vec3(0.00, 0.25, 0.25)); // rosa/ambar
}

vec3 palette(float t)
{
    t += gHue;
    return mix(preset(gPalA, t), preset(gPalB, t), gPalMix);
}

// ---- neon: preenchimento com anti-aliasing + halo (glow) a partir da distancia
vec3 neon(float d, vec3 col, float w, float gain)
{
    float core = smoothstep(w, -w, d);
    float glow = exp(-max(d, 0.0) * GLOW);
    return col * glow * gain + mix(col, vec3(1.0), 0.40) * core;
}

// ---- fundo: gradiente + pontilhado (meio-tom) que pulsa com o volume --------
vec3 background(vec2 p)
{
    float r = length(p);
    vec3 col = palette(0.60 + gPalT * 0.5) * vec3(0.05, 0.03, 0.09) * (0.5 + 0.9 * exp(-r * 2.5));

    vec2  f   = fract(p * 70.0) - 0.5;
    float rad = 0.10 + 0.22 * (0.25 + gVol + 0.6 * gPulse) * exp(-r * 2.0);
    float dots = smoothstep(rad, rad - 0.10, length(f));
    col += palette(0.30 + r * 0.4 + gPalT) * dots * 0.10 * (0.4 + exp(-r * 3.0));
    return col;
}

// ---- starfield / warp drive: raios que nascem no centro e aceleram para fora
vec3 warp(vec2 p)
{
    float r  = length(p);
    float a  = atan(p.y, p.x);
    float wt = gAng * 1.6 + iTime * 0.15;               // "relogio" do warp: acelera com os graves
    float energy = 0.35 + 1.4 * gTre + 1.1 * gPulse;
    vec3 acc = vec3(0.0);

    for (int l = 0; l < 4; l++)
    {
        float fl = float(l);
        float n  = 70.0 + 55.0 * fl;                     // setores angulares (raios possiveis)
        float sa = a / TAU * n;
        float id = floor(sa);
        float h  = hash11(id + 17.0 * fl);
        float h2 = hash11(id * 3.1 + 5.0 * fl + 1.0);
        if (h2 < 0.45) continue;                         // so alguns setores tem raio

        float perp = (fract(sa) - 0.5) * (TAU / n) * r;  // distancia lateral ate o raio
        float z    = fract(h + wt * (0.10 + 0.05 * fl)); // progresso 0..1 (centro -> borda)
        float head = 0.05 + 1.1 * z * z;                 // posicao radial da ponta (acelera)
        float len  = 0.02 + 0.30 * z * z;                // comprimento do rastro
        float tail = clamp(1.0 - (head - r) / len, 0.0, 1.0) * step(r, head);
        float line = smoothstep(0.0006 + 0.0012 * z, 0.0, abs(perp));
        float fade = smoothstep(0.0, 0.15, z) * (1.0 - smoothstep(0.75, 1.0, z));
        acc += palette(h + gPalT) * (line * tail * tail * fade) * (0.5 + h2);
    }
    return acc * energy * 0.9;
}

// ---- retangulos em volta da circunferencia ----------------------------------
// Cada retangulo e um "canal": sua altura vem de uma barra do Buffer A.
// Usa a SDF de retangulo arredondado no referencial de cada barra (eixo X = radial).
vec3 bars(vec2 p, float px)
{
    float cell = TAU / float(N_BARS);
    float a    = mod(atan(p.y, p.x) - gAng, TAU);        // gira junto com os graves
    int   i0   = int(floor(a / cell));

    vec3 acc = vec3(0.0);
    for (int k = -1; k <= 1; k++)                        // barra da celula + vizinhas (glow nao corta)
    {
        int   i     = (i0 + k + N_BARS) % N_BARS;
        float level = texelFetch(iChannel0, ivec2(i, 0), 0).r;
        float h     = hash11(float(i));
        float h2    = hash11(float(i) + 91.0);

        float th  = (float(i) + 0.5) * cell + gAng;       // angulo central da barra
        vec2  q   = rot(-th) * p;                         // coloca a barra no eixo X

        float len = BAR_MIN + level * BAR_MAX * mix(0.85, 1.0, h2);
        float w   = mix(0.30, 0.90, h) * R_RING * sin(cell * 0.5);   // espessura aleatoria por barra
        vec2  c   = vec2(R_RING + BAR_GAP + len * 0.5, 0.0);
        float d   = sdRoundBox(q - c, vec2(len * 0.5, w), w * 0.6);

        vec3 col = palette(float(i) / float(N_BARS) * 0.8 + gPalT + level * 0.25 + h * 0.10);
        acc += neon(d, col, px, 0.22 + 0.40 * level);
    }
    return acc;
}

vec3 scene(vec2 p)
{
    float px = 1.6 / iResolution.y;
    float r  = length(p);
    float th = atan(p.y, p.x);

    vec3 col = background(p) + warp(p);

    // circunferencia: pulsa com graves/batida e ondula com a forma de onda do audio
    float wf   = abs(th) / PI * 127.0;                       // espelhado em y: sem emenda
    float wave = mix(texelFetch(iChannel0, ivec2(int(wf), 2), 0).r,
                     texelFetch(iChannel0, ivec2(min(int(wf) + 1, 127), 2), 0).r, fract(wf)) - 0.5;
    float R    = R_RING + 0.012 * gBass + 0.018 * gPulse + 0.05 * wave * (0.4 + gVol)
               + 0.003 * sin(th * 8.0 + iTime * 2.0);
    float dRing = abs(r - R) - (0.0045 + 0.004 * gPulse);
    col += neon(dRing, palette(0.15 + gPalT + abs(th) / PI * 0.3), px, 0.55 + 0.9 * gPulse);

    // retangulos
    col += bars(p, px);

    // formas geometricas internas que reagem a musica (hexagono = medios, triangulo = agudos)
    float da = -gAng * 0.8;
    float hexa = abs(sdNgon(rot(da) * p, 0.115 + 0.05 * gMid, 6.0)) - 0.0025;
    col += neon(hexa, palette(0.55 + gPalT), px, 0.40 + 0.9 * gMid);

    float tri = abs(sdNgon(rot(-da * 1.3 + 1.0) * p, 0.07 + 0.06 * gTre, 3.0)) - 0.002;
    col += neon(tri, palette(0.85 + gPalT), px, 0.40 + 0.9 * gTre);

    // brilho central na batida
    col += palette(0.40 + gPalT) * gPulse * 0.35 * exp(-r * 9.0);
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    vec2 res = iResolution.xy;
    vec2 p   = (fragCoord - 0.5 * res) / res.y;

    // ---- dados do Buffer A ----
    vec4 s0 = texelFetch(iChannel0, ivec2(0, 1), 0);
    vec4 s1 = texelFetch(iChannel0, ivec2(1, 1), 0);
    vec4 s2 = texelFetch(iChannel0, ivec2(2, 1), 0);
    gBass = s0.r;  gPulse = s0.g;  gAng = s0.b;
    gMid  = s1.r;  gTre = s1.g;  gPalT = s1.b;  gBeats = s1.a;
    gVol  = s2.r;

    // ---- paleta: automatica (com transicao) ou controlada pelo mouse ----
    float cyc = iTime / PAL_TIME;
    gPalA   = int(mod(floor(cyc), float(N_PAL)));
    gPalB   = (gPalA + 1) % N_PAL;
    gPalMix = smoothstep(0.85, 1.0, fract(cyc));
    gHue    = 0.0;
    if (iMouse.z > 0.0)
    {
        gPalA = gPalB = int(clamp(iMouse.x / res.x * float(N_PAL), 0.0, float(N_PAL) - 0.01));
        gPalMix = 0.0;
        gHue    = iMouse.y / res.y;
    }

    // ---- camera shake + UV displacement (reagem a batida e aos graves) ----
    vec2 shake = (hash21(gBeats) - 0.5) * 2.0;                       // direcao nova a cada batida
    p += shake * 0.012 * gPulse * gPulse;                            // tremor
    p += 0.004 * gBass * vec2(sin(p.y * 14.0 + iTime * 3.0),         // ondulacao do UV
                              cos(p.x * 14.0 + iTime * 2.7));
    p *= 1.0 - 0.035 * gPulse;                                       // "soco" de zoom

    // ---- aberracao cromatica (canais RGB levemente deslocados) ----
    float ca = 0.005 * gPulse + 0.002 * gVol;
    vec3 col = vec3(scene(p * (1.0 + ca)).r,
                    scene(p).g,
                    scene(p * (1.0 - ca)).b);

    // ---- acabamento: vinheta, tone mapping, leve gama ----
    col *= 1.0 - 0.55 * dot(p, p);
    col  = 1.0 - exp(-col * 1.25);
    col  = pow(col, vec3(0.92));
    fragColor = vec4(col, 1.0);
}