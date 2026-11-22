# Vista Dirección

Pantalla única para la Dirección de Turismo (P1 de la auditoría del 20/11/2026): **anticipar, verificar y actuar** sobre los tres ejes de la premisa. No se edita ni se aprueba nada desde aquí.

## Quién la ve

- **Todos** tienen la pestaña «Dirección» (la primera del menú).
- **Visor y administrador** entran por ella (decisión de Meysel, 22/11/2026). El analista sigue entrando por el Panorama.
- El visor no tiene el Panorama editable ni los tableros guardados; el administrador conserva los dos.

## Qué muestra

1. **Semáforo de Bolivia**: el peor estado de los tres ejes, con el motivo.
2. **Tres tarjetas, una por eje**, cada una Normal / Atención / Acción, con lo que la pone así, hasta 3 riesgos y el responsable sugerido.
3. **Decisiones de hoy**: las 3 más urgentes, cada una con su ficha fija
   **Acción recomendada · Responsable sugerido · Plazo · Cómo verificar**.
4. **Semáforo por departamento** (verde / amarillo / rojo) con el motivo en una frase y qué se recomienda. También en la vista Mapa (modo «Semáforo», el de entrada para visor y administrador).
5. **Lo que viene**: lo que ocurre en 24 h, 72 h o 7 días (se elige arriba), ordenado por la fecha en que pasa, no por cuándo lo detectó AVIA: marchas y paros anunciados, eventos, cierres de convocatorias y avisos con fecha.

La misma ficha sale **arriba del todo** al abrir cualquier señal, antes del resumen y de los detalles.

## Reglas

### De 10 categorías a 3 ejes

| Eje | Entra |
|---|---|
| Movilidad | vial, seguridad, clima (salvo que hable de agua, sequía o energía) y cualquier señal que hable de bloqueo, marcha, paro, huelga o protesta |
| Servicios esenciales | salud, y cualquier señal que hable de agua, sequía, energía, cortes de luz, combustible, internet o telefonía |
| Atención turística | eventos, conectividad (en AVIA es **aérea**: aeropuertos y vuelos), turismo y mercados; y lo que hable de hoteles, alojamiento, reservas o visitantes |
| Sin eje | financiación, normativa y economía que no hablen de nada de lo anterior (siguen en Oportunidades y Señales) |

### Normal / Atención / Acción

Solo cuentan riesgos y mixtas activos, con la misma acción que ya usa la lista de riesgos («Actuar hoy / Preparar / Seguir»):

- **Acción (rojo)**: «Actuar hoy» y certeza confirmado o convocado.
- **Atención (amarillo)**: «Actuar hoy» todavía sin confirmar (posible o rumor), o «Preparar».
- **Normal (verde)**: «Seguir», oportunidades o nada.

Un departamento toma el color de su señal que más pesa. Las señales de todo el país se listan aparte y no tiñen el mapa entero.

### Ficha

- **Acción recomendada**: la recomendación segura (25). Si da algo por bueno sin dato oficial de las últimas 24 h, la acción pasa a ser «Comprobar con … antes de avisar a nadie».
- **Responsable sugerido**: el del eje, de los parámetros del cliente. Mientras no se configuren sale un texto genérico (por ejemplo «Responsable de movilidad y seguridad del visitante»).
- **Plazo**: riesgo para actuar → «Hoy»; para preparar → antes de 72 h, o la víspera si empieza antes; para seguir → «Revisar en 7 días». Oportunidad → antes del cierre (con «fecha pendiente de verificar» si el plazo no lo dio una fuente primaria) o antes de que empiece.
- **Cómo verificar**: con quién comprobarlo y lo primero que falta saber.

## Dónde vive

- Base: `db/generico/49_vista_direccion.sql` (`vigilante.eje_de`, `accion_direccion`, `estado_direccion`, `ficha_direccion`, `direccion`). `vigilante_bd()` y `vigilante_json()` añaden `direccion` a cada señal y, arriba, `responsables` y `direccion`. Prueba: `99_prueba_vista_direccion.sql`.
- Web: `web/src/lib/direccion.ts` (mismas reglas, para los datos de ejemplo y bases sin el 49), `views/Direccion.tsx`, `components/FichaDireccion.tsx`, modo «Semáforo» en `views/Mapa.tsx`.
- Chat AVIA: `avia_api.py` recibe el bloque VISTA DIRECCIÓN cuando la pregunta habla de la Dirección, el semáforo, un eje, un departamento, decisiones o lo que viene (regla 17), y cada señal lleva su eje y su ficha.

## Poner los responsables reales

```sql
INSERT INTO vigilante.parametros (cliente_id, clave, valor, descripcion)
SELECT id, x.clave, to_jsonb(x.valor), 'Responsable sugerido (vista Dirección)'
  FROM vigilante.clientes, (VALUES
    ('responsable_movilidad', 'Nombre o unidad'),
    ('responsable_servicios', 'Nombre o unidad'),
    ('responsable_atencion',  'Nombre o unidad')) x(clave, valor)
 WHERE slug = 'orbita-bolivia'
ON CONFLICT (cliente_id, clave) DO UPDATE SET valor = EXCLUDED.valor, updated_at = now();
```

## Límites conocidos

- «Lo que viene» solo ve lo que tiene fecha de ocurrencia guardada (`fecha_evento_inicio`) o fecha de cierre. Un pronóstico del SENAMHI sin fecha de inicio no aparece ahí (sí en el semáforo).
- La base ubica cada señal por sus territorios; la web, además, por sus destinos conocidos (Uyuni → Potosí). Una señal que solo tenga destino puede pintar un departamento en la web y no en el resumen del chat.
