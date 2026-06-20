<script lang="ts">
  // Dual-thumb range slider for the OpenRouter price filters. Replaces four separate min/max number
  // inputs with one "min – max" control per price.
  //
  // The native <input type=range> works in a 0..RESOLUTION *position* space, not the price value
  // space, so a power `curve` can give the cheap end most of the track: useful model prices cluster
  // near $0 while the domain runs to tens of dollars, and a linear slider would jam both thumbs into
  // the leftmost sliver. A max thumb at the domain end reads as "∞" (no upper limit); the parent
  // treats that as unbounded when matching, so pricier outliers above the cap stay reachable.
  interface Props {
    label: string;
    prefix?: string;
    min: number;
    max: number;
    domainMax: number;
    domainMin?: number;
    step?: number;
    decimals?: number;
    curve?: number;
    onChange: (next: { min: number; max: number }) => void;
  }

  let {
    label,
    prefix = "",
    min,
    max,
    domainMax,
    domainMin = 0,
    step = 0.1,
    decimals = 2,
    curve = 1,
    onChange
  }: Props = $props();

  const RESOLUTION = 1000;

  // Local thumb values so dragging stays smooth without a backend write per pointer move.
  let lo = $state(0);
  let hi = $state(0);

  function clampToDomain(value: number) {
    if (!Number.isFinite(value)) return domainMin;
    return Math.min(domainMax, Math.max(domainMin, value));
  }

  function roundToStep(value: number) {
    return Number((Math.round(value / step) * step).toFixed(6));
  }

  function valueToPosition(value: number) {
    const span = domainMax - domainMin;
    const ratio = span > 0 ? (clampToDomain(value) - domainMin) / span : 0;
    return Math.round(Math.pow(Math.max(0, ratio), 1 / curve) * RESOLUTION);
  }

  function positionToValue(position: number) {
    // Keep the ends exact so "max = ∞" and "min = 0" stay reachable despite step snapping.
    if (position >= RESOLUTION) return domainMax;
    if (position <= 0) return domainMin;
    const raw = domainMin + Math.pow(position / RESOLUTION, curve) * (domainMax - domainMin);
    return clampToDomain(roundToStep(raw));
  }

  // Resync from the parent value (initial mount + Reset). Reads only the props, so the local drag
  // updates to lo/hi never retrigger it.
  $effect(() => {
    const a = clampToDomain(min);
    const b = clampToDomain(max);
    lo = Math.min(a, b);
    hi = Math.max(a, b);
  });

  function percent(value: number) {
    return (valueToPosition(value) / RESOLUTION) * 100;
  }

  function formatValue(value: number) {
    if (value >= domainMax) return "∞";
    return `${prefix}${Number(value.toFixed(decimals)).toString()}`;
  }

  function onMinInput(event: Event) {
    const position = Number((event.currentTarget as HTMLInputElement).value);
    lo = Math.min(positionToValue(position), hi); // never cross the max thumb
  }

  function onMaxInput(event: Event) {
    const position = Number((event.currentTarget as HTMLInputElement).value);
    hi = Math.max(positionToValue(position), lo); // never cross the min thumb
  }

  function commit() {
    onChange({ min: lo, max: hi });
  }

  // Near the top of the track the two thumbs overlap; lift the min thumb so it stays grabbable.
  const minThumbRaised = $derived(valueToPosition(lo) > RESOLUTION * 0.94);
</script>

<div class="range-field">
  <span class="range-label">{label}</span>
  <div class="cc-slider" style={`--lo:${percent(lo)}%; --hi:${percent(hi)}%`}>
    <div class="cc-slider-track" aria-hidden="true"></div>
    <div class="cc-slider-fill" aria-hidden="true"></div>
    <input
      class="cc-range"
      type="range"
      min="0"
      max={RESOLUTION}
      step="1"
      value={valueToPosition(lo)}
      aria-label={`${label} minimum`}
      style={`z-index:${minThumbRaised ? 5 : 3}`}
      oninput={onMinInput}
      onchange={commit}
    />
    <input
      class="cc-range"
      type="range"
      min="0"
      max={RESOLUTION}
      step="1"
      value={valueToPosition(hi)}
      aria-label={`${label} maximum`}
      style="z-index:4"
      oninput={onMaxInput}
      onchange={commit}
    />
    <!-- Values sit under their own thumb (following the track position), not in a corner. -->
    <span class="range-bubble range-bubble-lo">{formatValue(lo)}</span>
    <span class="range-bubble range-bubble-hi">{formatValue(hi)}</span>
  </div>
</div>
