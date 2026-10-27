// App-wide Navigation stack. Index binds it to its Navigation root; every
// page pushes/pops through this singleton so pages stay decoupled from Index.

export class AppNav {
  static readonly stack: NavPathStack = new NavPathStack();

  static push(name: string, param: Object | null): void {
    AppNav.stack.pushPathByName(name, param);
  }
}
