# babashka/cli — fails at let-go reader

Fetch and resolve work; let-go's reader chokes on the
`^Character`/`^String` metadata shorthand at
[`src/babashka/cli.cljc:57`](https://github.com/babashka/cli/blob/v0.8.67/src/babashka/cli.cljc#L57):

```clojure
(defn- first-char ^Character [^String arg] ...)
```

Error: `Syntax error reading source ... unsupported meta form`.

Tracked as gap #1 in
[../../../issues/clojure-lib-compat.md](../../../issues/clojure-lib-compat.md).
