import './harness.test.js';
import { fit } from './views/map.js';
import { assertEquals } from '@std/assert';

const chip = { rows: 8, columns: 18 };

Deno.test('auto shows registers only where every node fits', () => {
  assertEquals(fit('auto', 18 * 12, 8 * 5, chip), { width: 10, height: 4, gapX: 2, gapY: 1 });
  assertEquals(fit('auto', 18 * 9, 8 * 3, chip), null);
});

Deno.test('tiles of registers grow no larger than the largest', () => {
  assertEquals(fit('auto', 18 * 40, 8 * 20, chip), { width: 16, height: 6, gapX: 2, gapY: 1 });
});

Deno.test('numbers are numbers, however much room', () => {
  assertEquals(fit('numbers', 18 * 40, 8 * 20, chip), null);
});

Deno.test('registers scroll through comfortable tiles where they do not fit', () => {
  assertEquals(fit('registers', 18 * 6, 8 * 3, chip), { width: 11, height: 4, gapX: 2, gapY: 1 });
  // and fit, from comfortable ones up, where they do
  assertEquals(fit('registers', 18 * 14, 8 * 6, chip), { width: 12, height: 5, gapX: 2, gapY: 1 });
});
