// A minimal `vite-plus/test` for replaying a TypeScript test file outside the runner: it runs the
// bodies immediately and records every `expect(actual).toBe(expected)` with the last input the
// wrapped function saw, so the test tables can be reused as data (see commandLabelTests.ts).
export interface Recorded {
  readonly title: string;
  readonly input: unknown;
  readonly expected: unknown;
  readonly actual: unknown;
}

const recorded: Recorded[] = [];
let currentTitle = "";
const g = globalThis as { __lastInput?: unknown };

export const records = () => recorded;
export const describe = (_name: string, body: () => void) => body();
export const it = Object.assign(
  (name: string, body: () => void) => {
    currentTitle = name;
    body();
  },
  {
    each: (table: ReadonlyArray<unknown>) => (name: string, body: (...args: any[]) => void) => {
      for (const row of table) {
        currentTitle = name.replace("%s", String(Array.isArray(row) ? row[0] : row));
        if (Array.isArray(row)) body(...row);
        else body(row);
      }
    },
  },
);
export const expect = (actual: unknown) => ({
  toBe: (expected: unknown) =>
    void recorded.push({ title: currentTitle, input: g.__lastInput, expected, actual }),
  toBeNull: () =>
    void recorded.push({ title: currentTitle, input: g.__lastInput, expected: null, actual }),
});
