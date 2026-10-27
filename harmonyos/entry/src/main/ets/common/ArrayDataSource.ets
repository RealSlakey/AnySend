// Generic array-backed IDataSource for LazyForEach lists.

export class ArrayDataSource<T> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  constructor(items: T[] = []) {
    this.items = items;
  }

  public totalCount(): number {
    return this.items.length;
  }

  public getData(index: number): T {
    return this.items[index];
  }

  public registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  public unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  /** Replace the whole dataset and notify listeners. */
  public setData(items: T[]): void {
    this.items = items;
    for (const l of this.listeners) {
      l.onDataReloaded();
    }
  }
}
