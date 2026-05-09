# medley — fails at let-go runtime

Fetch, resolve, read, and most of the compile all work; let-go fails
when compiling
[`src/medley/core.cljc:41`](https://github.com/weavejester/medley/blob/1.10.0/src/medley/core.cljc#L41-L43):

```clojure
(defn- editable? [coll]
  #?(:cljs    (satisfies? cljs.core/IEditableCollection coll)
     :default (instance? clojure.lang.IEditableCollection coll)))
```

let-go matches the `:default` branch and tries to resolve the JVM-only
class.

Error: `CompileError: Can't resolve clojure.lang.IEditableCollection in
this context`.

Tracked as gap #3 in
[../../../issues/clojure-lib-compat.md](../../../issues/clojure-lib-compat.md).
