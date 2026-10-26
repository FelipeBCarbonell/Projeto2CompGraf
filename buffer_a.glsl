// ============================================================================
//  BUFFER A  -  Tratamento do audio (suavizacao, filtro e deteccao de batida)
//
//  Canais:  iChannel0 = Music / Soundcloud / Mic
//           iChannel1 = Buffer A   (realimentacao: guarda o quadro anterior)
//
//  O que sai daqui (lido pela aba Image com texelFetch):
//    linha y = 0, x = 0..N_BARS-1 : nivel suavizado de cada barra (1 barra = 1 "canal" de FFT)
//    pixel (0,1): r = graves   g = pulso de batida   b = angulo acumulado   a = media lenta dos graves
//    pixel (1,1): r = medios   g = agudos            b = fase da paleta      a = contador de batidas
//    pixel (2,1): r = volume global
//    linha y = 2, x = 0..127      : forma de onda do audio (r), para ondular a circunferencia
// ============================================================================

#define N_BARS    64      // precisa ser igual ao da aba Image
#define IDLE_DEMO 1       // 1 = se nao houver audio, anima um espectro de mentira (0 desliga)

#define ATTACK    30.0    // velocidade de subida das barras  (1/s) -> quanto maior, mais rapido sobe
#define RELEASE    5.5    // velocidade de queda das barras   (1/s) -> quanto menor, mais suave desce

bool gIdle = false;       // true quando o audio esta mudo

float hash11(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }

// FFT cru: linha 0 da textura de audio (u em [0,1] = 0 Hz ... ~22 kHz)
float fftRaw(float u) { return texture(iChannel0, vec2(u, 0.25)).x; }

float fft(float u)
{
    float v = fftRaw(u);
#if IDLE_DEMO
    if (gIdle)
    {
        float beat = pow(0.5 + 0.5 * sin(iTime * 11.9), 6.0);
        v = (0.30 + 0.55 * beat) * exp(-u * 6.0)
          + 0.30 * (0.5 + 0.5 * sin(u * 90.0 - iTime * 3.0)) * (1.0 - u)
          + 0.10 * hash11(floor(u * 300.0) + floor(iTime * 10.0));
    }
#endif
    return v;
}

// Media do FFT em uma faixa [u0,u1] (filtro passa-baixa espacial: 6 amostras)
float band(float u0, float u1)
{
    float s = 0.0;
    for (int k = 0; k < 6; k++) s += fft(mix(u0, u1, (float(k) + 0.5) / 6.0));
    return s / 6.0;
}

// Nivel instantaneo da barra i (cada barra escuta uma faixa de frequencia)
float barRaw(int i)
{
    float t0 = float(i)     / float(N_BARS);
    float t1 = float(i + 1) / float(N_BARS);
    // escala nao linear: mais barras para os graves, onde ha mais informacao
    float s = band(0.003 + 0.45 * pow(t0, 1.8), 0.003 + 0.45 * pow(t1, 1.8));
    // resposta em frequencia alterada: realca agudos + ganho aleatorio fixo por barra
    s *= (1.0 + 0.9 * t0) * mix(0.85, 1.15, hash11(float(i)));
    // piso e teto: tira o "ruido de fundo" e usa toda a faixa dinamica
    return smoothstep(0.22, 0.95, s);
}

// Estado dos graves: suavizacao, deteccao de batida e angulo acumulado
vec4 bassState(float dt)
{
    vec4 prev = texelFetch(iChannel1, ivec2(0, 1), 0);
    float raw = band(0.004, 0.028);

    float bass = mix(prev.r, raw, 1.0 - exp(-dt * (raw > prev.r ? 30.0 : 6.0)));
    float avg  = mix(prev.a, raw, 1.0 - exp(-dt * 0.8));            // media lenta (limiar adaptativo)

    // batida = graves acima da media lenta e acima de um minimo; nao dispara de novo logo em seguida
    float beat  = (raw > avg * 1.10 + 0.04 && raw > 0.40 && prev.g < 0.55) ? 1.0 : 0.0;
    float pulse = max(prev.g * exp(-dt * 7.0), beat);

    // a rotacao acumula mais rapido quando os graves estao fortes
    float ang = prev.b + dt * (0.12 + 0.9 * bass * bass);
    return vec4(bass, pulse, ang, avg);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord)
{
    ivec2 p  = ivec2(fragCoord);
    float dt = clamp(iTimeDelta, 0.0001, 0.1);
    fragColor = vec4(0.0);

    // audio mudo? (usa so o sinal real, para decidir se mostra o espectro de mentira)
    gIdle = (fftRaw(0.01) + fftRaw(0.03) + fftRaw(0.07) + fftRaw(0.15) + fftRaw(0.30)) < 0.02;

    if (p.y == 0 && p.x < N_BARS)
    {
        // filtro: media ponderada com as barras vizinhas (0.25 / 0.5 / 0.25)
        int i = p.x;
        float v = 0.25 * barRaw(max(i - 1, 0)) + 0.50 * barRaw(i) + 0.25 * barRaw(min(i + 1, N_BARS - 1));

        // suavizacao temporal com ataque rapido e queda lenta (independente do framerate)
        float prev = texelFetch(iChannel1, p, 0).r;
        float k = (v > prev) ? ATTACK : RELEASE;
        fragColor = vec4(mix(prev, v, 1.0 - exp(-dt * k)), 0.0, 0.0, 1.0);
    }
    else if (p == ivec2(0, 1))
    {
        fragColor = bassState(dt);
    }
    else if (p == ivec2(1, 1))
    {
        vec4 prev = texelFetch(iChannel1, p, 0);
        vec4 bs   = bassState(dt);
        float mid = band(0.030, 0.120);
        float tre = band(0.120, 0.350);
        fragColor = vec4(
            mix(prev.r, mid, 1.0 - exp(-dt * 10.0)),
            mix(prev.g, tre, 1.0 - exp(-dt * 12.0)),
            prev.b + dt * (0.015 + 0.10 * prev.r),                 // fase da paleta
            prev.a + (bs.g > 0.999 ? 1.0 : 0.0));                  // conta batidas
    }
    else if (p == ivec2(2, 1))
    {
        float vol = band(0.020, 0.300);
        float prev = texelFetch(iChannel1, p, 0).r;
        fragColor = vec4(mix(prev, vol, 1.0 - exp(-dt * 8.0)), 0.0, 0.0, 1.0);
    }
    else if (p.y == 2 && p.x < 128)
    {
        // forma de onda (linha 1 da textura de audio) reamostrada em 128 pontos
        float x = (float(p.x) + 0.5) / 128.0;
        float w = texture(iChannel0, vec2(x, 0.75)).x;
#if IDLE_DEMO
        if (gIdle) w = 0.5 + 0.10 * sin(x * 40.0 + iTime * 3.0) * (0.5 + 0.5 * sin(iTime * 1.7));
#endif
        fragColor = vec4(w, 0.0, 0.0, 1.0);
    }
}