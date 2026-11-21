# Skills de los AVIA de Carlos en Hermes

Los GPT de AVIA caducan el **11 de diciembre**. Estos son los AVIA que Carlos pidió conservar y dónde quedan en Hermes. Las seis skills nuevas son de chat: no usan el MCP del Vigilante ni la base, así que no gastan nada mientras nadie las llame.

| AVIA | Skill en Hermes | Estado | De dónde sale |
| --- | --- | --- | --- |
| AVIA Radar | `avia-radar-decision` | ya instalada | GPT «Radar AVIA Siesta» |
| AVIA Auditor | `avia-auditor` | ya instalada | GPT «AVIA-Auditor» |
| AVIA Proyecto | `avia-proyecto-hermes` | ya instalada | GPT/Poe AVIA-Proyecto |
| AVIA Studio | `avia-studio-tooc` | **nueva** | Poe «AVIASTUDIOTOOCv7.0» + GPT «AVIA Studio» |
| AVIA Siesta OTT | `avia-siesta-ott` | **nueva** | Poe «PromtSiestaOTTv2» (Prompt Maestro v4.0, AMS) |
| AVIA Clon de Carlos | `avia-clon-carlos` | **nueva** | Poe «AVIA-Clon-Carlos» + GPT «AVIA Clon de Carlos» (modos v1/v2) |
| AVIA Certificado | `avia-certificado` | **nueva** | GPT «CertiAVIA» + GPT «AVIA-Studio Certifica EU» |
| AVIAOntologia y libros de marca | `avia-canon` | **nueva** | Ontología, Libro Blanco, Libro Azul, Libro Blanco AVIA-Siesta (`D:\Work\AVIA\revisar`) |
| AVIA Senior (Beta 2.3.1) | `avia-senior-cientifico` | **nueva** | «OKOKOK-AVIA» + Libro Blanco Vivo Parte 0 |

## Qué hace cada una

- **avia-studio-tooc**: diseña, audita o pasa a HTML un TOOC o un bot con una constelación de 3 a 7 agentes que llegan a un consenso. Ficha Router, fuente única de verdad, pipeline de 10 fases, WCAG 2.2 AA y dictamen GO / REVIEW / NO-GO.
- **avia-siesta-ott**: audita una app o Canvas con la metodología AMS (7 pasos), la escala de Inteligencia Viva, LEID y los 6 pilares SiestaOTTOS; da nota ponderada, brechas y plan por sprints, con dos puntos de aprobación.
- **avia-clon-carlos**: responde con el criterio de Carlos. Modo v1.0 técnico y modo v2.0 ético-afectivo (escucha, inspiración, acción, cierre). Deriva a las otras skills.
- **avia-canon**: vocabulario oficial, ontología en 6 capas, principios, reglas éticas, Edge-First y SIMPLIT. Las demás skills AVIA la usan de referencia.
- **avia-senior-cientifico**: mantiene el Libro Blanco Vivo con rigor científico; ninguna evidencia entra sin pasar por verificación y consejo humano.
- **avia-certificado**: acompaña a reconocer saberes no formales o conquistas de un TOOC y deja un borrador de credencial Open Badges 3.0 que firma un emisor humano.

## Qué se quitó al pasarlas a Hermes

- Sellos criptográficos inventados (hash SHA-256, firma, NFT, blockchain): Hermes no los genera, así que se quedan en un registro de trabajo sin valor de prueba.
- Tonos, colores y pantallas de los Canvas de Poe: Hermes responde en texto.
- Lo que no se puede verificar («certificado oficial», «producción», «interoperabilidad probada») queda prohibido sin pruebas, como en el Radar.

## Instalar en el VPS

```bash
cd /root/avia-repo && git fetch origin claude/project-thread-7miava && git checkout claude/project-thread-7miava
for s in avia-canon avia-senior-cientifico avia-studio-tooc avia-siesta-ott avia-clon-carlos avia-certificado; do
  cp -r hermes/skills/$s /root/.hermes/skills/
done
chown -R 10000:10000 /root/.hermes/skills
docker restart hermes
docker exec hermes ls /opt/data/skills | grep -E 'canon|senior-cientifico|studio-tooc|siesta-ott|clon-carlos|certificado'
```

## Probar (en el chat de Hermes)

- «Activa modo AVIA v1.0 — revisión técnica del panel del Vigilante»
- «Diseña un TOOC de 3 unidades sobre turismo accesible en el lago Titicaca, modo breve»
- «Audita este Canvas: <pega el HTML o la descripción>»
- «Quiero certificar que sé cuidar personas mayores»
- «¿Qué diferencia hay entre agente y bot en AVIA? Dámelo en YAML»
- «Revisa este párrafo del Libro Blanco: <pega el texto>»

Los documentos de marca y dónde quedó cada uno: [docs/avia/README.md](avia/README.md).
