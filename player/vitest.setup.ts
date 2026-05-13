// Node 25's jsdom is shipping a flaky localStorage shim. Replace it with a
// simple Map-backed Storage that has all the methods the tests need.
class MapStorage implements Storage {
  private map = new Map<string, string>();
  get length(): number { return this.map.size; }
  key(i: number): string | null { return Array.from(this.map.keys())[i] ?? null; }
  getItem(k: string): string | null { return this.map.has(k) ? this.map.get(k)! : null; }
  setItem(k: string, v: string): void { this.map.set(k, String(v)); }
  removeItem(k: string): void { this.map.delete(k); }
  clear(): void { this.map.clear(); }
}

Object.defineProperty(globalThis, 'localStorage', {
  configurable: true,
  value: new MapStorage()
});
Object.defineProperty(globalThis, 'sessionStorage', {
  configurable: true,
  value: new MapStorage()
});
