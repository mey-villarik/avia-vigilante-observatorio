# vigilante-turismo-bolivia: leer del Vigilante en vez de buscar en la web

La skill instalada en el VPS (`/root/.hermes/skills/vigilante-turismo-bolivia/SKILL.md`) busca noticias en la web por su cuenta. Eso duplica el trabajo del recolector y del analizador, y puede dar un parte distinto del que ve el panel. El cambio: el parte diario sale de las señales que ya están en Supabase, a través del MCP `avia-vigilante`.

Este archivo guarda el cambio mientras la skill completa no esté en el repo. Cuando lo esté, se aplica en el `SKILL.md` y este archivo se borra.

## 1. Sustituir la sección «### Dónde buscas» entera por esta

```markdown
### De dónde sale la información
No buscas en la web ni abres fuentes. El recolector lee las fuentes oficiales y los medios del catálogo, el analizador crea las señales y tú trabajas sobre ellas con el MCP **avia-vigilante**:
- `contadores`: totales del panel con su hora (cítalos tal cual).
- `buscar_senales` con `dias: 2`: las señales de las últimas 48 h (una llamada por naturaleza si hace falta: riesgo, oportunidad, mixta).
- `alertas_tempranas`: lo que una regla marca para mirar ya.
- `eventos_abiertos`: señales que coinciden en lugar y fecha, con la interpretación de AVIA.
- `metricas_oportunidades`: plazos, eventos próximos e impulso por territorio (para la sección Oportunidades).
Si echas en falta una fuente o un tema, deja una búsqueda con `pedir_busqueda` (via `script`) y dilo en el parte. No la sustituyas buscando tú.
```

## 2. En «### Cómo trabajas», sustituir los pasos 1, 2 y 3 por estos

```markdown
1. **Reunir.** Llama a `contadores`, `buscar_senales` (dias 2), `alertas_tempranas` y `eventos_abiertos`. Quédate con lo nuevo o lo que cambió en 48 h.
2. **Localizar.** Cada señal ya trae fuente, enlace, territorio y fechas (los pone la base desde las noticias). Usa esos datos; no los cambies ni añadas enlaces que no estén en la señal.
3. **Verificar.** Usa el grado de certeza de cada señal, sin subirlo nunca:
   - ✅ **Confirmado** = certeza «confirmado».
   - 🔄 **En verificación** = «convocado» o «posible» con una fuente fiable.
   - 🔍 **Potencial** = «posible» de una sola fuente poco fiable, o «rumor». Nunca se presenta como hecho.
   Si el titular de la señal exagera lo que dicen sus noticias, dilo en los matices.
```

Lo demás (cinco misiones, exclusiones, oportunidades, formato del parte) se queda igual.

## 3. Aplicarlo en el VPS

```bash
cp /root/.hermes/skills/vigilante-turismo-bolivia/SKILL.md /root/.hermes/skills/vigilante-turismo-bolivia/SKILL.md.antes
nano /root/.hermes/skills/vigilante-turismo-bolivia/SKILL.md    # pegar los dos bloques de arriba
docker restart hermes
```

Comprobar: pedir a Hermes «dame el parte de turismo de Bolivia». En su registro de herramientas deben aparecer llamadas a `buscar_senales` y `contadores`, y ninguna búsqueda web. Los totales deben ser los mismos que los del panel.
